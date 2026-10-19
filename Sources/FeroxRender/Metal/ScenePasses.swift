#if canImport(Metal)
    import FeroxAssets
    import FeroxCore
    import FeroxMath
    import FeroxScene
    import Foundation
    import Metal

    // The 3D scene passes, in submission order:
    //
    //   1. Shadows      — one depth-only render pass per cascade slice (standard Z, `less`).
    //   2. Compute      — clustered light assignment and GPU instance culling (frustum + the
    //                     previous frame's Hi-Z), writing indirect draw arguments.
    //   3. Prepass      — depth (reverse Z) + normal/roughness + motion vectors, MSAA-resolved.
    //   4. Hi-Z build   — min-reduction pyramid of this frame's depth, consumed next frame.
    //   5. Main pass    — forward opaque (depth `greaterEqual`, no writes), sky, transparents.
    //                     The renderer appends particles, sprites and debug lines to the same
    //                     encoder before it ends, so MSAA colour never has to be stored.
    //
    // `ScenePasses` owns only what is specific to these passes (shadow map, Hi-Z validity,
    // depth states). Per-frame buffers come from the frame allocator and are described by
    // `SceneFrameState`, built once per frame by `prepare`.

    /// Shared caches and per-frame services every scene pass needs.
    struct SceneResources {
        let assets: AssetManager
        let meshes: MeshCache
        let textures: TextureCache
        let materials: MaterialBinder
        let samplers: SamplerSet
        let fallback: FallbackTextures
        let allocator: FrameAllocator
        /// Monotonic frame counter (cache residency bookkeeping).
        let frameIndex: UInt64
    }

    /// Textures read by the forward lighting shader (slots 5…13).
    struct LightingTextures {
        var prefiltered: any MTLTexture
        var brdfLUT: any MTLTexture
        var shadowMap: any MTLTexture
        var rtShadow: any MTLTexture
        var rtReflection: any MTLTexture
        var ambientOcclusion: any MTLTexture
        var irradiance: any MTLTexture
        var probes: any MTLTexture
        /// Point/spot shadow slices (`ScenePasses.encodeLocalShadows`).
        var localShadows: any MTLTexture
    }

    /// Tier-2 material table for one opaque pass. `ids` is parallel to the instance-index buffer.
    struct MaterialArgumentBind {
        var table: any MTLBuffer
        var ids: BufferSlice
        var textures: [any MTLTexture] = []
    }

    /// The frame's GPU-side scene data, uploaded once and shared by every pass.
    struct SceneFrameState {
        var uniforms: FrameUniforms
        var instances: BufferSlice?
        /// CPU-built `instanceIndices` (shadow casters, transparents, non-cullable batches).
        var staticIndices: BufferSlice?
        /// Indices compacted by `expandVisibleDraws` (nil when GPU culling is off).
        var culledIndices: BufferSlice?
        /// One visibility flag per instance, written by `cullInstances`.
        var visibility: BufferSlice?
        /// `(instance, batch)` pairs consumed by `expandVisibleDraws`.
        var memberships: BufferSlice?
        /// One indirect draw record per opaque batch (`IndirectDrawLayout` stride).
        var drawArgs: BufferSlice?
        /// Per opaque batch: drawn indirectly from the GPU-culled list.
        var cullable: [Bool] = []
        var cullUniforms = CullUniforms()
        var joints: BufferSlice?
        var lights: BufferSlice?
        var probes: BufferSlice?
        var clusterCounts: BufferSlice?
        var clusterIndices: BufferSlice?
        /// Light view-projection per active cascade (empty when shadows are off).
        var cascadeMatrices: [Mat4] = []
        /// Point/spot shadow slices planned this frame (empty when none are shadowed).
        var localSlices: [LocalShadowSlice] = []
        /// One view-projection per local slice (identity when there are none).
        var localMatrices: BufferSlice?
        var useClusters = true
        var gpuCulling: Bool { culledIndices != nil }
        /// MSAA sample count of the main targets.
        var samples = 1
    }

    /// Mesh pipeline flavours. The raw value is part of the pipeline cache key.
    enum MeshPassKind: String {
        case prepass, forward, transparent, shadow, pick
    }

    final class ScenePasses {
        /// Cluster grid (must match `FrameUniforms.clusterDims` defaults and Clusters.metal).
        static let clusterDims = SIMD4<UInt32>(16, 9, 24, 64)
        static var clusterCount: Int { Int(clusterDims.x * clusterDims.y * clusterDims.z) }
        /// Bytes of one indirect draw record. See `IndirectDrawLayout` (32, not 20).
        static let drawArgsStride = IndirectDrawLayout.strideBytes

        let device: any MTLDevice
        let shaders: ShaderLibrary
        let capabilities: DeviceCapabilities

        /// Cascaded shadow map (depth32Float 2D array, one slice per cascade).
        private(set) var shadowMap: (any MTLTexture)?
        private var shadowMapKey: (resolution: Int, cascades: Int)?
        private var shadowBytes = 0

        /// Point/spot shadow slices (depth32Float 2D array, `ShadowSettings.localShadowSlices`).
        private(set) var localShadowMap: (any MTLTexture)?
        private var localShadowKey: (resolution: Int, slices: Int)?
        private var localShadowBytes = 0

        /// True once the Hi-Z pyramid holds a depth buffer of the current size.
        private(set) var hizValid = false
        /// The unjittered view-projection that produced the Hi-Z pyramid.
        private var hizViewProjection = Mat4.identity

        private var depthStates: [String: any MTLDepthStencilState] = [:]

        /// Winding of front faces. Counter-clockwise for every normal view; reflection-probe
        /// capture sets clockwise while it encodes, because cube-face cameras are mirrored.
        var frontFacing: MTLWinding = .counterClockwise

        /// Set when this frame's cull kernels were encoded. A compile failure clears it so
        /// draws use `staticIndices` instead of an indirect buffer the GPU never filled.
        private(set) var indirectCullingActive = false
        /// Indirect command buffers still referenced by in-flight frames.
        private var liveIndirectBuffers: [any MTLIndirectCommandBuffer] = []
        /// GPU-encoded commands for the pass that is about to open. Nil when that pass stays immediate.
        private struct CulledCommands {
            var kind: MeshPassKind
            var commands: any MTLIndirectCommandBuffer
            var count: Int
            var buffers: [any MTLBuffer]
            var textures: [any MTLTexture]
        }
        private var culledCommands: CulledCommands?

        init(device: any MTLDevice, shaders: ShaderLibrary, capabilities: DeviceCapabilities) {
            self.device = device
            self.shaders = shaders
            self.capabilities = capabilities
        }

        deinit {
            MemoryTracker.shared.free("GPU.ShadowMap", bytes: shadowBytes)
            MemoryTracker.shared.free("GPU.LocalShadowMap", bytes: localShadowBytes)
        }

        /// Discards the Hi-Z pyramid (resize, camera cut, scene load). The next frame culls by
        /// frustum only.
        func invalidateHiZ() { hizValid = false }

        // MARK: - Pipelines

        /// The 72-byte interleaved vertex layout (buffer 0) plus, for skinned pipelines, the
        /// joints/weights stream (buffer 1). See `MeshVertexLayout` and `MeshCache.interleave`.
        static func vertexDescriptor(skinned: Bool) -> MTLVertexDescriptor {
            let d = MTLVertexDescriptor()
            let attributes: [(MTLVertexFormat, Int)] = [
                (.float3, MeshVertexLayout.positionOffset),
                (.float3, MeshVertexLayout.normalOffset),
                (.float4, MeshVertexLayout.tangentOffset),
                (.float2, MeshVertexLayout.uv0Offset),
                (.float2, MeshVertexLayout.uv1Offset),
                (.float4, MeshVertexLayout.colorOffset),
            ]
            for (i, a) in attributes.enumerated() {
                d.attributes[i].format = a.0
                d.attributes[i].offset = a.1
                d.attributes[i].bufferIndex = BufferIndex.vertices
            }
            d.layouts[BufferIndex.vertices].stride = MeshVertexLayout.stride
            if skinned {
                d.attributes[6].format = .ushort4
                d.attributes[6].offset = 0
                d.attributes[6].bufferIndex = BufferIndex.skin
                d.attributes[7].format = .float4
                d.attributes[7].offset = 8
                d.attributes[7].bufferIndex = BufferIndex.skin
                d.layouts[BufferIndex.skin].stride = MeshVertexLayout.skinStride
            }
            return d
        }

        /// A cached mesh pipeline for `kind` and `variant` at `samples` MSAA samples.
        func meshPipeline(_ kind: MeshPassKind, variant: ShaderVariant, samples: Int) throws
            -> any MTLRenderPipelineState
        {
            let s = kind == .shadow ? 1 : max(samples, 1)
            let key = "\(kind.rawValue)-\(variant.key)-s\(s)"
            return try shaders.renderPipeline(key) { d in
                d.vertexDescriptor = Self.vertexDescriptor(skinned: variant.skinning)
                d.rasterSampleCount = s
                if capabilities.supportsMetal3 { d.supportIndirectCommandBuffers = true }
                switch kind {
                case .shadow:
                    d.vertexFunction = try shaders.function("shadowVertex", variant: variant)
                    // Opaque casters need no fragment stage at all (depth-only fast path).
                    d.fragmentFunction =
                        variant.alphaTest
                        ? try shaders.function("shadowAlphaTestFragment", variant: variant) : nil
                    d.depthAttachmentPixelFormat = .depth32Float
                case .prepass:
                    d.vertexFunction = try shaders.function("meshVertex", variant: variant)
                    d.fragmentFunction = try shaders.function("prepassFragment", variant: variant)
                    d.colorAttachments[0].pixelFormat = TargetFormat.normal
                    d.colorAttachments[1].pixelFormat = TargetFormat.motion
                    d.depthAttachmentPixelFormat = TargetFormat.depth
                    d.stencilAttachmentPixelFormat = TargetFormat.depth
                case .pick:
                    d.vertexFunction = try shaders.function("meshVertex", variant: variant)
                    d.fragmentFunction = try shaders.function("prepassPickFragment")
                    d.colorAttachments[0].pixelFormat = .r32Uint
                    d.depthAttachmentPixelFormat = .depth32Float
                case .forward, .transparent:
                    d.vertexFunction = try shaders.function("meshVertex", variant: variant)
                    d.fragmentFunction = try shaders.function("forwardFragment", variant: variant)
                    d.colorAttachments[0].pixelFormat = TargetFormat.hdr
                    d.depthAttachmentPixelFormat = TargetFormat.depth
                    d.stencilAttachmentPixelFormat = TargetFormat.depth
                    if kind == .transparent {
                        // The forward shader outputs premultiplied colour.
                        let c = d.colorAttachments[0]!
                        c.isBlendingEnabled = true
                        c.rgbBlendOperation = .add
                        c.alphaBlendOperation = .add
                        c.sourceRGBBlendFactor = .one
                        c.sourceAlphaBlendFactor = .one
                        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    }
                }
            }
        }

        /// The sky pipeline: fullscreen triangle at reverse-Z depth 0 into the HDR target.
        func skyPipeline(samples: Int) throws -> any MTLRenderPipelineState {
            try shaders.renderPipeline("sky-s\(samples)") { d in
                d.vertexFunction = try shaders.function("skyVertex")
                d.fragmentFunction = try shaders.function("skyFragment")
                d.colorAttachments[0].pixelFormat = TargetFormat.hdr
                d.depthAttachmentPixelFormat = TargetFormat.depth
                d.stencilAttachmentPixelFormat = TargetFormat.depth
                d.rasterSampleCount = max(samples, 1)
            }
        }

        /// A cached depth-stencil state.
        func depthState(_ compare: MTLCompareFunction, write: Bool) -> any MTLDepthStencilState {
            let key = "\(compare.rawValue)-\(write)"
            if let s = depthStates[key] { return s }
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            d.label = "Ferox.Depth.\(key)"
            // A nil state would only arise on device loss; Metal then fails the whole frame anyway.
            let s = device.makeDepthStencilState(descriptor: d)!
            depthStates[key] = s
            return s
        }

        /// Variant for a batch. Vertex colour is always on: `MeshCache.interleave` writes white
        /// when a mesh has no colours, so the multiply is harmless and saves variants.
        static func variant(for b: DrawBatch, skinned: Bool, clusters: Bool, alphaTest: Bool? = nil) -> ShaderVariant {
            ShaderVariant(
                skinning: skinned, alphaTest: alphaTest ?? b.alphaTest, vertexColor: true, clusters: clusters,
                unlit: b.unlit)
        }

        // MARK: - Frame preparation

        /// Uploads instances, indices, lights, joints and probes, computes cascades, and fills
        /// the lighting-related fields of `uniforms`.
        func prepare(
            _ frame: RenderFrameData, uniforms: FrameUniforms, graphics: ResolvedGraphics, probes: [ProbeData],
            targets: RenderTargets, resources r: SceneResources
        ) -> SceneFrameState {
            var u = uniforms
            var state = SceneFrameState(uniforms: u)
            let a = r.allocator
            state.samples = targets.config?.msaaSamples ?? 1
            state.useClusters = graphics.settings.renderPath == .clusteredForward

            // Every buffer slot gets something bound, even when empty: Metal requires bound
            // buffers for every argument the shader declares.
            state.instances = a.upload(frame.instances.isEmpty ? [InstanceData()] : frame.instances)
            state.staticIndices = a.upload(frame.instanceIndices.isEmpty ? [UInt32(0)] : frame.instanceIndices)
            state.joints = a.upload(frame.joints.isEmpty ? [Mat4.identity] : frame.joints)
            // Point/spot shadows write their slice indices into the lights, so plan them first.
            var lights = frame.lights
            let shadows = graphics.settings.shadows
            if shadows.enabled, !frame.shadowCasters.isEmpty, !frame.shadowedLights.isEmpty {
                state.localSlices = LocalShadowPlanner.plan(
                    lights: &lights, candidates: frame.shadowedLights, budget: shadows.localShadowSlices,
                    resolution: shadows.localResolution, normalBias: shadows.normalBias)
            }
            state.lights = a.upload(lights.isEmpty ? [LightData()] : lights)
            state.localMatrices = a.upload(
                state.localSlices.isEmpty ? [Mat4.identity] : state.localSlices.map(\.viewProjection))
            state.probes = a.upload(probes.isEmpty ? [ProbeData()] : probes)

            // Lights and probes.
            var flags = FrameFlags.reverseZ
            if state.useClusters { flags |= FrameFlags.clustered }
            if shadows.softness == .pcss { flags |= FrameFlags.pcss }
            if shadows.softness == .hard { flags |= FrameFlags.hardShadows }
            u.clusterDims = Self.clusterDims
            if let cam = frame.camera {
                u.clusterParams = RenderMath.clusterParams(
                    near: cam.camera.near, far: cam.camera.far,
                    slices: Int(Self.clusterDims.z))
            }
            if let sun = frame.sun {
                u.sunDirection = Vec4(sun.towardsLight.normalized, sun.intensity)
                u.sunColor = Vec4(sun.color, sun.castsShadows ? 1 : 0)
            } else {
                u.sunDirection = .zero
                u.sunColor = .zero
            }

            // Cascaded shadows.
            state.cascadeMatrices = cascades(
                frame, settings: graphics.settings.shadows,
                rayTraced: graphics.rayTracedShadows, uniforms: &u)
            if !state.cascadeMatrices.isEmpty { flags |= FrameFlags.shadows }
            u.lightCounts = SIMD4(
                UInt32(frame.punctualCount), UInt32(frame.directionalCount), UInt32(probes.count), flags)

            if state.useClusters {
                state.clusterCounts = a.allocate(length: Self.clusterCount * MemoryLayout<UInt32>.stride)
                state.clusterIndices = a.allocate(
                    length: Self.clusterCount * Int(Self.clusterDims.w) * MemoryLayout<UInt16>.stride)
                if state.clusterCounts == nil || state.clusterIndices == nil { state.useClusters = false }
            }

            prepareCulling(frame, graphics: graphics, targets: targets, uniforms: u, state: &state, allocator: a)
            state.uniforms = u
            return state
        }

        /// Computes cascade matrices and the shadow uniforms. Returns an empty array when the
        /// shadow-map path is inactive (no sun, sun casts no shadows, disabled, or replaced by
        /// ray-traced shadows).
        private func cascades(
            _ frame: RenderFrameData, settings: ShadowSettings, rayTraced: Bool,
            uniforms u: inout FrameUniforms
        ) -> [Mat4] {
            u.shadowParams = .zero
            guard settings.enabled, !rayTraced, let sun = frame.sun, sun.castsShadows, let cam = frame.camera,
                !frame.shadowCasters.isEmpty
            else { return [] }
            let count = min(max(settings.cascades, 1), 4)
            let resolution = min(max(settings.resolution, 256), 8192)
            let near = cam.camera.near
            let far = min(cam.camera.far, max(settings.maxDistance, near + 1))
            let splits = RenderMath.cascadeSplits(near: near, far: far, count: count)
            // Unjittered: cascades must not wobble with TAA jitter.
            let inverse = cam.viewProjection.inverse
            var matrices: [Mat4] = []
            for c in 0..<count {
                let corners = RenderMath.frustumSliceCorners(
                    inverseViewProjection: inverse, near: near,
                    far: cam.camera.far, from: splits[c], to: splits[c + 1])
                matrices.append(
                    RenderMath.stableCascadeMatrix(
                        corners: corners, towardsLight: sun.towardsLight,
                        resolution: resolution))
            }
            let m = matrices
            u.shadowMatrices = (m[0], m[min(1, count - 1)], m[min(2, count - 1)], m[min(3, count - 1)])
            // Split ends for cascades 0…3; unused entries repeat the far distance.
            u.cascadeSplits = Vec4(splits[min(1, count)], splits[min(2, count)], splits[min(3, count)], splits[count])
            u.shadowParams = Vec4(settings.depthBias, settings.normalBias, 1 / Float(resolution), Float(count))
            return matrices
        }

        /// Uploads culling inputs. Every opaque batch is cullable, including later submeshes of
        /// the same instance. Instances are tested once; `expandVisibleDraws` fills each batch.
        private func prepareCulling(
            _ frame: RenderFrameData, graphics: ResolvedGraphics, targets: RenderTargets,
            uniforms u: FrameUniforms, state: inout SceneFrameState, allocator a: FrameAllocator
        ) {
            let batches = frame.opaque
            guard graphics.settings.gpuDrivenCulling, !batches.isEmpty, !frame.instances.isEmpty else { return }
            let plan = CullingPlan.make(batches: batches, instanceIndices: frame.instanceIndices)
            guard plan.cullable.contains(true) else { return }
            let pairs = plan.memberships.map { SIMD2<UInt32>($0.instance, $0.batch) }
            guard let memberships = a.upload(pairs), let argSlice = a.upload(plan.drawArgs),
                let visibility = a.allocate(length: max(frame.instances.count, 1) * MemoryLayout<UInt32>.stride),
                let culled = a.allocate(length: max(frame.instanceIndices.count, 1) * MemoryLayout<UInt32>.stride)
            else { return }
            state.drawArgs = argSlice
            state.culledIndices = culled
            state.visibility = visibility
            state.memberships = memberships
            state.cullable = plan.cullable

            var cu = CullUniforms()
            cu.planes = RenderMath.packedPlanes(Frustum(viewProjection: u.unjitteredViewProjection))
            let occlusion = graphics.settings.occlusionCulling && hizValid && targets.hiz != nil
            if occlusion, let hiz = targets.hiz {
                cu.previousViewProjection = hizViewProjection
                cu.hizSize = Vec4(Float(hiz.width), Float(hiz.height), Float(hiz.mipmapLevelCount), 0)
            }
            cu.counts = SIMD4(
                UInt32(frame.instances.count), occlusion ? 1 : 0, UInt32(batches.count),
                UInt32(plan.memberships.count))
            state.cullUniforms = cu
        }

        /// Patches index ranges into the draw arguments once meshes are resident. Batches whose
        /// mesh is not resident yet keep indexCount 0 and draw nothing.
        private func patchDrawArgs(_ frame: RenderFrameData, state: SceneFrameState, resources r: SceneResources) {
            guard let args = state.drawArgs else { return }
            let words = IndirectDrawLayout.words
            let p = (args.buffer.contents() + args.offset).bindMemory(
                to: UInt32.self, capacity: frame.opaque.count * words)
            for (i, b) in frame.opaque.enumerated() where i < state.cullable.count && state.cullable[i] {
                guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
                let range = mesh.range(ofSubmesh: b.submesh)
                p[i * words + IndirectDrawLayout.indexCount] = UInt32(range.count)
                p[i * words + IndirectDrawLayout.indexStart] = UInt32(range.offset)
            }
        }

        // MARK: - Shadows

        /// Ensures the shadow map matches the settings.
        private func ensureShadowMap(resolution: Int, cascades: Int) -> (any MTLTexture)? {
            if let k = shadowMapKey, k.resolution == resolution, k.cascades == cascades, let t = shadowMap { return t }
            MemoryTracker.shared.free("GPU.ShadowMap", bytes: shadowBytes)
            shadowBytes = 0
            shadowMap = nil
            shadowMapKey = nil
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = .depth32Float
            d.width = resolution
            d.height = resolution
            d.arrayLength = cascades
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else {
                Log.error("Render", "Could not allocate a \(resolution)² × \(cascades) shadow map; shadows disabled")
                return nil
            }
            t.label = "Ferox.ShadowMap"
            shadowMap = t
            shadowMapKey = (resolution, cascades)
            shadowBytes = t.allocatedSize
            MemoryTracker.shared.allocate("GPU.ShadowMap", bytes: shadowBytes)
            return t
        }

        /// Renders every cascade. Returns the shadow texture to bind (the 1-slice fallback when
        /// shadows are inactive, so the forward shader always has a valid array).
        func encodeShadows(
            _ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
            settings: ShadowSettings, resources r: SceneResources
        ) -> any MTLTexture {
            guard !state.cascadeMatrices.isEmpty,
                let map = ensureShadowMap(
                    resolution: min(max(settings.resolution, 256), 8192),
                    cascades: state.cascadeMatrices.count)
            else { return r.fallback.shadowArray }

            var sphereCache: [Int: Vec4] = [:]
            func batchSphere(_ b: DrawBatch) -> Vec4? {
                if let s = sphereCache[b.firstInstance] { return s }
                guard
                    let s = BatchCulling.sphere(
                        batch: b, instanceIndices: frame.instanceIndices, instances: frame.instances)
                else { return nil }
                sphereCache[b.firstInstance] = s
                return s
            }
            for (c, matrix) in state.cascadeMatrices.enumerated() {
                let pass = MTLRenderPassDescriptor()
                pass.depthAttachment.texture = map
                pass.depthAttachment.slice = c
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 1  // standard Z
                guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
                enc.label = "Ferox.Shadow.Cascade\(c)"
                enc.setDepthStencilState(depthState(.less, write: true))
                enc.setFrontFacing(frontFacing)
                // Slope-scaled hardware bias complements the shader's constant/normal bias.
                enc.setDepthBias(0, slopeScale: 1.5, clamp: 0.01)
                enc.setVertexValue(matrix, index: BufferIndex.cascade, allocator: r.allocator)
                enc.setVertexSlice(state.instances, index: BufferIndex.instances)
                enc.setVertexSlice(state.staticIndices, index: BufferIndex.instanceIndices)
                enc.setVertexSlice(state.joints, index: BufferIndex.joints)
                enc.setFragmentSamplerState(r.samplers.anisotropicRepeat, index: 0)
                let frustum = Frustum(viewProjection: matrix)
                encodeCasters(enc, frame: frame, state: state, resources: r) { batch in
                    guard let sphere = batchSphere(batch) else { return false }
                    return frustum.contains(Sphere(center: sphere.xyz, radius: sphere.w))
                }
                enc.endEncoding()
                Profiler.shared.updateRenderCounters { $0.renderPasses += 1 }
            }
            return map
        }

        /// Draws the shadow casters into the bound depth target. `include` filters batches
        /// (local lights draw only casters that reach them); nil draws every caster.
        private func encodeCasters(
            _ enc: any MTLRenderCommandEncoder, frame: RenderFrameData, state: SceneFrameState,
            resources r: SceneResources, include: ((DrawBatch) -> Bool)?
        ) {
            var boundVertex: ObjectIdentifier?
            var boundSkin: ObjectIdentifier?
            for b in frame.shadowCasters where include?(b) ?? true {
                guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
                let skinned = b.skinned && mesh.skinBuffer != nil
                let variant = Self.variant(for: b, skinned: skinned, clusters: false)
                guard let pso = try? meshPipeline(.shadow, variant: variant, samples: 1) else { continue }
                enc.setRenderPipelineState(pso)
                enc.setCullMode(b.doubleSided ? .none : .back)
                if b.alphaTest {
                    let m = r.materials.material(
                        b.material, assets: r.assets, textures: r.textures,
                        fallback: r.fallback, frame: r.frameIndex)
                    enc.setFragmentValue(m.uniforms, index: BufferIndex.material, allocator: r.allocator)
                    enc.setFragmentTexture(m.textures[0], index: 0)
                }
                draw(
                    enc, batch: b, mesh: mesh, skinned: skinned, indirect: nil, boundVertex: &boundVertex,
                    boundSkin: &boundSkin)
            }
        }

        /// Ensures the point/spot shadow array matches the settings. Its capacity is the whole
        /// budget, so it is not reallocated as lights come and go.
        private func ensureLocalShadowMap(resolution: Int, slices: Int) -> (any MTLTexture)? {
            if let k = localShadowKey, k.resolution == resolution, k.slices == slices, let t = localShadowMap {
                return t
            }
            MemoryTracker.shared.free("GPU.LocalShadowMap", bytes: localShadowBytes)
            localShadowBytes = 0
            localShadowMap = nil
            localShadowKey = nil
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = .depth32Float
            d.width = resolution
            d.height = resolution
            d.arrayLength = slices
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else {
                Log.error(
                    "Render", "Could not allocate a \(resolution)² × \(slices) local shadow map; local shadows disabled"
                )
                return nil
            }
            t.label = "Ferox.LocalShadowMap"
            localShadowMap = t
            localShadowKey = (resolution, slices)
            localShadowBytes = t.allocatedSize
            MemoryTracker.shared.allocate("GPU.LocalShadowMap", bytes: localShadowBytes)
            return t
        }

        /// Renders every planned point/spot slice. Returns the texture to bind at
        /// `TextureIndex.localShadows`: the 1-slice fallback when no light is shadowed (the
        /// shader then never samples it, because every light's `extra.y` is negative).
        func encodeLocalShadows(
            _ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
            settings: ShadowSettings, resources r: SceneResources
        ) -> any MTLTexture {
            let budget = min(max(settings.localShadowSlices, 1), LocalShadowPlanner.maxSlices)
            guard !state.localSlices.isEmpty,
                let map = ensureLocalShadowMap(resolution: min(max(settings.localResolution, 64), 4096), slices: budget)
            else { return r.fallback.shadowArray }

            var sphereCache: [Int: Vec4] = [:]
            func batchSphere(_ b: DrawBatch) -> Vec4? {
                if let s = sphereCache[b.firstInstance] { return s }
                guard
                    let s = BatchCulling.sphere(
                        batch: b, instanceIndices: frame.instanceIndices, instances: frame.instances)
                else { return nil }
                sphereCache[b.firstInstance] = s
                return s
            }

            cb.pushDebugGroup("Ferox.LocalShadows")
            defer { cb.popDebugGroup() }
            for (index, slice) in state.localSlices.enumerated() where index < budget {
                let pass = MTLRenderPassDescriptor()
                pass.depthAttachment.texture = map
                pass.depthAttachment.slice = index
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 1  // standard Z
                guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
                enc.label = "Ferox.Shadow.Light\(slice.light).Face\(slice.face)"
                enc.setDepthStencilState(depthState(.less, write: true))
                enc.setFrontFacing(frontFacing)
                enc.setDepthBias(0, slopeScale: 1.5, clamp: 0.01)
                enc.setVertexValue(slice.viewProjection, index: BufferIndex.cascade, allocator: r.allocator)
                enc.setVertexSlice(state.instances, index: BufferIndex.instances)
                enc.setVertexSlice(state.staticIndices, index: BufferIndex.instanceIndices)
                enc.setVertexSlice(state.joints, index: BufferIndex.joints)
                enc.setFragmentSamplerState(r.samplers.anisotropicRepeat, index: 0)
                encodeCasters(enc, frame: frame, state: state, resources: r) { batch in
                    guard let sphere = batchSphere(batch) else { return false }
                    return BatchCulling.reaches(sphere: sphere, lightPosition: slice.position, lightRange: slice.range)
                }
                enc.endEncoding()
                Profiler.shared.updateRenderCounters { $0.renderPasses += 1 }
            }
            return map
        }

        // MARK: - Compute: clusters and culling

        /// Assigns punctual lights to clusters and runs GPU culling. Both are independent of
        /// the prepass and share one compute encoder.
        func encodeCompute(
            _ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
            targets: RenderTargets, resources r: SceneResources
        ) {
            indirectCullingActive = false
            let culling = state.gpuCulling
            guard state.useClusters || culling else { return }
            patchDrawArgs(frame, state: state, resources: r)
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.label = "Ferox.ClustersAndCulling"
            defer { enc.endEncoding() }

            if state.useClusters {
                do {
                    let pso = try shaders.computePipeline("assignLights")
                    enc.setValue(state.uniforms, index: BufferIndex.frame, allocator: r.allocator)
                    enc.setSlice(state.lights, index: BufferIndex.lights)
                    enc.setSlice(state.clusterCounts, index: BufferIndex.clusterCounts)
                    enc.setSlice(state.clusterIndices, index: BufferIndex.clusterIndices)
                    enc.dispatch1D(pso, count: Self.clusterCount, groupSize: 64)
                    Profiler.shared.updateRenderCounters { $0.computeDispatches += 1 }
                } catch {
                    Log.error("Render", "Light clustering unavailable: \(error)")
                }
            }

            if culling {
                do {
                    let reset = try shaders.computePipeline("resetDrawArgs")
                    let cull = try shaders.computePipeline("cullInstances")
                    let expand = try shaders.computePipeline("expandVisibleDraws")
                    enc.setSlice(state.drawArgs, index: 0)
                    enc.setValue(state.cullUniforms, index: 1, allocator: r.allocator)
                    // Serial dispatch: reset, then visibility, then per-batch expansion.
                    enc.dispatch1D(reset, count: frame.opaque.count)
                    enc.setValue(state.cullUniforms, index: 0, allocator: r.allocator)
                    enc.setSlice(state.instances, index: 1)
                    enc.setSlice(state.visibility, index: 2)
                    // Frustum-only culling still binds a depth texture. `fallback.hiz` is r32Float;
                    // the white RGBA8 placeholder is not a legal argument for `texture2d<float>`.
                    enc.setTexture(targets.hiz ?? r.fallback.hiz, index: 0)
                    enc.dispatch1D(cull, count: frame.instances.count)
                    enc.setValue(state.cullUniforms, index: 0, allocator: r.allocator)
                    enc.setSlice(state.visibility, index: 1)
                    enc.setSlice(state.memberships, index: 2)
                    enc.setSlice(state.drawArgs, index: 3)
                    enc.setSlice(state.culledIndices, index: 4)
                    enc.dispatch1D(expand, count: max(Int(state.cullUniforms.counts.w), 1))
                    indirectCullingActive = true
                    Profiler.shared.updateRenderCounters { $0.computeDispatches += 3 }
                } catch {
                    indirectCullingActive = false
                    Log.error("Render", "GPU culling unavailable: \(error)")
                }
            }
        }

        // MARK: - Prepass

        /// Depth + normal/roughness + motion for opaque geometry. With MSAA, the attachments
        /// resolve into the single-sample targets that SSAO, TAA and ray tracing sample, while
        /// the multisampled depth is kept for the main pass.
        func encodePrepass(
            _ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
            targets: RenderTargets, resources r: SceneResources
        ) {
            guard let depth = targets.depth, let normal = targets.normal, let motion = targets.motion else { return }
            let msaa = targets.depthMSAA != nil
            let pass = MTLRenderPassDescriptor()
            let c0 = pass.colorAttachments[0]!
            let c1 = pass.colorAttachments[1]!
            c0.loadAction = .clear
            c0.clearColor = MTLClearColor(red: 0.5, green: 1, blue: 0.5, alpha: 1)  // +Y normal, rough
            c1.loadAction = .clear
            c1.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if msaa {
                c0.texture = targets.normalMSAA
                c0.resolveTexture = normal
                c0.storeAction = .multisampleResolve
                c1.texture = targets.motionMSAA
                c1.resolveTexture = motion
                c1.storeAction = .multisampleResolve
                pass.depthAttachment.texture = targets.depthMSAA
                pass.depthAttachment.resolveTexture = depth
                pass.depthAttachment.storeAction = .storeAndMultisampleResolve
                // The nearest sample (reverse Z: max) keeps thin geometry in SSAO and Hi-Z.
                pass.depthAttachment.depthResolveFilter = capabilities.supportsDepthResolveMinMax ? .max : .sample0
            } else {
                c0.texture = normal
                c0.storeAction = .store
                c1.texture = motion
                c1.storeAction = .store
                pass.depthAttachment.texture = depth
                pass.depthAttachment.storeAction = .store
            }
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0  // reverse Z far plane
            pass.stencilAttachment.texture = pass.depthAttachment.texture
            // The prepass does not use stencil; the main pass clears it for 2D masks.
            pass.stencilAttachment.loadAction = .dontCare
            pass.stencilAttachment.storeAction = .dontCare

            prepareCulledIndirectCommands(cb, kind: .prepass, frame: frame, state: state, resources: r)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.label = "Ferox.Prepass"
            targets.aliasSync?.begin(enc)
            defer {
                targets.aliasSync?.end(enc)
                enc.endEncoding()
                Profiler.shared.updateRenderCounters { $0.renderPasses += 1 }
            }
            guard !frame.opaque.isEmpty else { return }
            enc.setDepthStencilState(depthState(.greater, write: true))
            enc.setFrontFacing(frontFacing)
            bindCommon(enc, state: state, resources: r)
            encodeOpaqueDraws(enc, kind: .prepass, frame: frame, state: state, resources: r, lighting: nil)
        }

        /// Opaque instance ids into an `r32Uint` target, then one pixel into `staging`.
        /// CPU instance counts: GPU culling must not drop the clicked object. The textures
        /// are not on the alias heap. Returns false when the pass cannot be built.
        func encodeInstancePick(
            _ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
            resources r: SceneResources, width: Int, height: Int, pixelX: Int, pixelY: Int,
            staging: any MTLBuffer
        ) -> Bool {
            let w = max(width, 1)
            let h = max(height, 1)
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Uint, width: w, height: h, mipmapped: false)
            colorDesc.usage = [.renderTarget, .shaderRead]
            colorDesc.storageMode = .private
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            depthDesc.usage = .renderTarget
            depthDesc.storageMode = .private
            guard let color = device.makeTexture(descriptor: colorDesc),
                let depth = device.makeTexture(descriptor: depthDesc)
            else { return false }
            color.label = "Ferox.InstancePick"
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(InstancePickMap.miss), green: 0, blue: 0, alpha: 0)
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .dontCare
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
            enc.label = "Ferox.InstancePick"
            enc.setDepthStencilState(depthState(.greater, write: true))
            enc.setFrontFacing(frontFacing)
            bindCommon(enc, state: state, resources: r)
            enc.setVertexSlice(state.staticIndices, index: BufferIndex.instanceIndices)
            var last: (any MTLRenderPipelineState)?
            var boundVertex: ObjectIdentifier?
            var boundSkin: ObjectIdentifier?
            for b in frame.opaque {
                guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
                let skinned = b.skinned && mesh.skinBuffer != nil
                var variant = Self.variant(for: b, skinned: skinned, clusters: state.useClusters)
                variant.materialArguments = false
                guard let pso = try? meshPipeline(.pick, variant: variant, samples: 1) else { continue }
                if pso !== last {
                    enc.setRenderPipelineState(pso)
                    last = pso
                }
                enc.setCullMode(b.doubleSided ? .none : .back)
                draw(
                    enc, batch: b, mesh: mesh, skinned: skinned, indirect: nil, boundVertex: &boundVertex,
                    boundSkin: &boundSkin)
            }
            enc.endEncoding()
            let pixel = InstancePickStaging.pixel(x: pixelX, y: pixelY, width: w, height: h)
            guard let blit = cb.makeBlitCommandEncoder() else { return false }
            blit.label = "Ferox.InstancePickReadback"
            blit.copy(
                from: color, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: pixel.x, y: pixel.y, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: staging,
                destinationOffset: InstancePickStaging.wordOffset,
                destinationBytesPerRow: InstancePickStaging.byteCount,
                destinationBytesPerImage: InstancePickStaging.byteCount)
            blit.endEncoding()
            return true
        }

        /// Builds the Hi-Z pyramid from this frame's resolved depth for next frame's culling.
        func encodeHiZ(_ cb: any MTLCommandBuffer, state: SceneFrameState, targets: RenderTargets) {
            guard state.gpuCulling, let depth = targets.depth, !targets.hizMips.isEmpty,
                let enc = cb.makeComputeCommandEncoder()
            else { return }
            enc.label = "Ferox.HiZ"
            targets.aliasSync?.begin(enc)
            defer {
                targets.aliasSync?.end(enc)
                enc.endEncoding()
            }
            do {
                let copy = try shaders.computePipeline("hizCopy")
                let down = try shaders.computePipeline("hizDownsample")
                enc.setTexture(depth, index: 0)
                enc.setTexture(targets.hizMips[0], index: 1)
                enc.dispatch2D(copy, width: targets.hizMips[0].width, height: targets.hizMips[0].height)
                for level in 1..<targets.hizMips.count {
                    // Each level reads the previous one; texture hazard tracking orders them.
                    enc.setTexture(targets.hizMips[level - 1], index: 0)
                    enc.setTexture(targets.hizMips[level], index: 1)
                    enc.dispatch2D(down, width: targets.hizMips[level].width, height: targets.hizMips[level].height)
                }
                Profiler.shared.updateRenderCounters { $0.computeDispatches += targets.hizMips.count }
                hizValid = true
                hizViewProjection = state.uniforms.unjitteredViewProjection
            } catch {
                Log.error("Render", "Hi-Z build unavailable: \(error)")
                hizValid = false
            }
        }

        // MARK: - Main pass

        /// The main HDR pass: loads the prepass depth, clears the 2D-mask stencil, and clears colour to
        /// `clearColor` (linear, not pre-exposed, so 2D scenes see their clear colour as-is).
        /// With MSAA the colour resolves into `targets.hdr` when the encoder ends.
        func mainPassDescriptor(targets: RenderTargets, clearColor: Color) -> MTLRenderPassDescriptor? {
            guard let hdr = targets.hdr, let depthAttachment = targets.depthAttachment else { return nil }
            let pass = MTLRenderPassDescriptor()
            let c = pass.colorAttachments[0]!
            c.loadAction = .clear
            let cc = clearColor.rgb
            c.clearColor = MTLClearColor(red: Double(cc.x), green: Double(cc.y), blue: Double(cc.z), alpha: 1)
            if let msaa = targets.hdrMSAA {
                c.texture = msaa
                c.resolveTexture = hdr
                c.storeAction = .multisampleResolve
            } else {
                c.texture = hdr
                c.storeAction = .store
            }
            pass.depthAttachment.texture = depthAttachment
            pass.depthAttachment.loadAction = .load
            // Post-processing reads the resolved prepass depth, so nothing needs storing here.
            pass.depthAttachment.storeAction = .dontCare
            pass.stencilAttachment.texture = depthAttachment
            pass.stencilAttachment.loadAction = .clear
            pass.stencilAttachment.clearStencil = 0
            pass.stencilAttachment.storeAction = .dontCare
            return pass
        }

        /// Forward-shaded opaque geometry. Depth is already final, so the test is
        /// `greaterEqual` without writes: every visible pixel is shaded exactly once.
        func encodeOpaque(
            _ enc: any MTLRenderCommandEncoder, frame: RenderFrameData, state: SceneFrameState,
            lighting: LightingTextures, resources r: SceneResources
        ) {
            guard !frame.opaque.isEmpty else { return }
            enc.pushDebugGroup("Ferox.ForwardOpaque")
            defer { enc.popDebugGroup() }
            enc.setDepthStencilState(depthState(.greaterEqual, write: false))
            enc.setFrontFacing(frontFacing)
            bindCommon(enc, state: state, resources: r)
            bindLighting(enc, state: state, lighting: lighting, resources: r)
            encodeOpaqueDraws(enc, kind: .forward, frame: frame, state: state, resources: r, lighting: lighting)
        }

        /// Draws the sky where no geometry was rendered (depth still at the far plane, 0).
        func encodeSky(
            _ enc: any MTLRenderCommandEncoder, environment: any MTLTexture, state: SceneFrameState,
            resources r: SceneResources
        ) {
            guard let pso = try? skyPipeline(samples: state.samples) else { return }
            enc.pushDebugGroup("Ferox.Sky")
            defer { enc.popDebugGroup() }
            enc.setRenderPipelineState(pso)
            enc.setDepthStencilState(depthState(.greaterEqual, write: false))
            enc.setCullMode(.none)
            enc.setFragmentValue(state.uniforms, index: BufferIndex.frame, allocator: r.allocator)
            enc.setFragmentTexture(environment, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            Profiler.shared.updateRenderCounters {
                $0.drawCalls += 1
                $0.pipelineStateChanges += 1
            }
        }

        /// Transparent geometry, back to front, premultiplied blending, depth-tested only.
        func encodeTransparent(
            _ enc: any MTLRenderCommandEncoder, frame: RenderFrameData, state: SceneFrameState,
            lighting: LightingTextures, resources r: SceneResources
        ) {
            guard !frame.transparent.isEmpty else { return }
            enc.pushDebugGroup("Ferox.Transparent")
            defer { enc.popDebugGroup() }
            enc.setDepthStencilState(depthState(.greaterEqual, write: false))
            enc.setFrontFacing(frontFacing)
            bindCommon(enc, state: state, resources: r)
            bindLighting(enc, state: state, lighting: lighting, resources: r)
            var last: (any MTLRenderPipelineState)?
            var lastMaterial: AssetID??
            var boundVertex: ObjectIdentifier?
            var boundSkin: ObjectIdentifier?
            for b in frame.transparent {
                guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
                let skinned = b.skinned && mesh.skinBuffer != nil
                let variant = Self.variant(for: b, skinned: skinned, clusters: state.useClusters, alphaTest: false)
                guard let pso = try? meshPipeline(.transparent, variant: variant, samples: state.samples) else {
                    continue
                }
                if pso !== last {
                    enc.setRenderPipelineState(pso)
                    last = pso
                    Profiler.shared.updateRenderCounters { $0.pipelineStateChanges += 1 }
                }
                if lastMaterial != .some(b.material) {
                    bindMaterial(enc, b.material, resources: r)
                    lastMaterial = .some(b.material)
                }
                enc.setCullMode(b.doubleSided ? .none : .back)
                draw(
                    enc, batch: b, mesh: mesh, skinned: skinned, indirect: nil, boundVertex: &boundVertex,
                    boundSkin: &boundSkin)
            }
        }

        // MARK: - Draw helpers

        /// Buffers shared by every mesh draw in a pass.
        private func bindCommon(_ enc: any MTLRenderCommandEncoder, state: SceneFrameState, resources r: SceneResources)
        {
            enc.setVertexValue(state.uniforms, index: BufferIndex.frame, allocator: r.allocator)
            enc.setFragmentValue(state.uniforms, index: BufferIndex.frame, allocator: r.allocator)
            enc.setVertexSlice(state.instances, index: BufferIndex.instances)
            enc.setFragmentSlice(state.instances, index: BufferIndex.instances)
            enc.setVertexSlice(state.joints, index: BufferIndex.joints)
            enc.setFragmentSamplerState(r.samplers.anisotropicRepeat, index: 0)
        }

        /// Lights, clusters, probes and the IBL / shadow / RT / AO textures for forward shading.
        private func bindLighting(
            _ enc: any MTLRenderCommandEncoder, state: SceneFrameState, lighting l: LightingTextures,
            resources r: SceneResources
        ) {
            enc.setFragmentSlice(state.lights, index: BufferIndex.lights)
            // The brute-force variant never reads the cluster buffers, but they must be bound.
            enc.setFragmentSlice(state.clusterCounts ?? state.staticIndices, index: BufferIndex.clusterCounts)
            enc.setFragmentSlice(state.clusterIndices ?? state.staticIndices, index: BufferIndex.clusterIndices)
            enc.setFragmentSlice(state.probes, index: BufferIndex.probes)
            enc.setFragmentTexture(l.prefiltered, index: TextureIndex.prefiltered)
            enc.setFragmentTexture(l.brdfLUT, index: TextureIndex.brdfLUT)
            enc.setFragmentTexture(l.shadowMap, index: TextureIndex.shadowMap)
            enc.setFragmentTexture(l.rtShadow, index: TextureIndex.rtShadow)
            enc.setFragmentTexture(l.rtReflection, index: TextureIndex.reflection)
            enc.setFragmentTexture(l.ambientOcclusion, index: TextureIndex.ambientOcclusion)
            enc.setFragmentTexture(l.irradiance, index: TextureIndex.irradiance)
            enc.setFragmentTexture(l.probes, index: TextureIndex.probes)
            enc.setFragmentTexture(l.localShadows, index: TextureIndex.localShadows)
            enc.setFragmentSlice(state.localMatrices, index: BufferIndex.localShadowMatrices)
            enc.setFragmentSamplerState(r.samplers.shadowCompare, index: 1)
        }

        private func bindMaterial(_ enc: any MTLRenderCommandEncoder, _ id: AssetID?, resources r: SceneResources) {
            let m = r.materials.material(
                id, assets: r.assets, textures: r.textures, fallback: r.fallback,
                frame: r.frameIndex)
            enc.setFragmentValue(m.uniforms, index: BufferIndex.material, allocator: r.allocator)
            for (i, t) in m.textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            Profiler.shared.updateRenderCounters { $0.textureBinds += m.textures.count }
        }

        /// Opaque batches for the prepass or forward pass. Batches are already sorted by
        /// material and mesh, so state changes happen only at group boundaries.
        private func encodeOpaqueDraws(
            _ enc: any MTLRenderCommandEncoder, kind: MeshPassKind, frame: RenderFrameData,
            state: SceneFrameState, resources r: SceneResources, lighting: LightingTextures?
        ) {
            if executeCulledCommands(enc, kind: kind, frame: frame) { return }
            let materials = bindMaterialArguments(enc, frame: frame, kind: kind, state: state, resources: r)
            let arguments = materials != nil
            let mixedCull = frame.opaque.contains { $0.doubleSided } && frame.opaque.contains { !$0.doubleSided }
            // Indirect commands do not inherit textures. The argument-buffer path keeps every
            // material texture in one buffer, so that is the path that can submit an ICB.
            // Mixed double-sided state stays immediate because cull mode is encoder state.
            let gpuIndirectDraws = frame.opaque.indices.contains { i in
                indirectCullingActive && state.gpuCulling && i < state.cullable.count && state.cullable[i]
            }
            if let materials, !mixedCull,
                DrawPolicy.submission(
                    indirectCommandBuffers: capabilities.supportsMetal3, gpuIndirectDraws: gpuIndirectDraws)
                    == .indirectCommandBuffer,
                encodeIndirectCommands(
                    enc, kind: kind, frame: frame, state: state, resources: r, materials: materials)
            {
                return
            }
            var last: (any MTLRenderPipelineState)?
            var lastMaterial: AssetID??
            var boundIndices: Bool?  // true = culled list bound
            var boundVertex: ObjectIdentifier?
            var boundSkin: ObjectIdentifier?
            for (i, b) in frame.opaque.enumerated() {
                guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
                let skinned = b.skinned && mesh.skinBuffer != nil
                var variant = Self.variant(for: b, skinned: skinned, clusters: state.useClusters)
                variant.materialArguments = arguments
                guard let pso = try? meshPipeline(kind, variant: variant, samples: state.samples) else { continue }
                if pso !== last {
                    enc.setRenderPipelineState(pso)
                    last = pso
                    Profiler.shared.updateRenderCounters { $0.pipelineStateChanges += 1 }
                }
                if !arguments, lastMaterial != .some(b.material) {
                    bindMaterial(enc, b.material, resources: r)
                    lastMaterial = .some(b.material)
                }
                enc.setCullMode(b.doubleSided ? .none : .back)
                let gpu = indirectCullingActive && state.gpuCulling && i < state.cullable.count && state.cullable[i]
                if boundIndices != gpu {
                    enc.setVertexSlice(
                        gpu ? state.culledIndices : state.staticIndices, index: BufferIndex.instanceIndices)
                    boundIndices = gpu
                }
                draw(
                    enc, batch: b, mesh: mesh, skinned: skinned,
                    indirect: gpu ? state.drawArgs.map { ($0, i) } : nil,
                    boundVertex: &boundVertex, boundSkin: &boundSkin)
            }
        }

        /// Encodes the opaque pass into an indirect command buffer. Buffers are stored on each
        /// command (`inheritBuffers` is false) because each mesh has its own vertex buffer.
        /// Textures stay on the encoder; materials therefore come from `materials`.
        /// Draws use the direct indexed form. The macOS 15 SDK's `MTLIndirectRenderCommand`
        /// has no `indirectBuffer` overload, so GPU-culled batches never reach this function.
        private func encodeIndirectCommands(
            _ enc: any MTLRenderCommandEncoder, kind: MeshPassKind, frame: RenderFrameData,
            state: SceneFrameState, resources r: SceneResources, materials: MaterialArgumentBind
        ) -> Bool {
            guard capabilities.supportsMetal3, !frame.opaque.isEmpty,
                let instances = state.instances, let staticIndices = state.staticIndices,
                let frameSlice = r.allocator.upload(value: state.uniforms)
            else { return false }
            let desc = MTLIndirectCommandBufferDescriptor()
            desc.commandTypes = [.drawIndexed]
            desc.inheritBuffers = false
            desc.inheritPipelineState = false
            desc.maxVertexBufferBindCount = BufferIndex.instanceIndices + 1
            desc.maxFragmentBufferBindCount = BufferIndex.materialIds + 1
            guard
                let icb = device.makeIndirectCommandBuffer(
                    descriptor: desc, maxCommandCount: frame.opaque.count, options: [])
            else { return false }
            var encoded = 0
            let cullBack = frame.opaque.allSatisfy { !$0.doubleSided }
            enc.setCullMode(cullBack ? .back : .none)
            for b in frame.opaque {
                guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
                let skinned = b.skinned && mesh.skinBuffer != nil
                var variant = Self.variant(for: b, skinned: skinned, clusters: state.useClusters)
                variant.materialArguments = true
                guard let pso = try? meshPipeline(kind, variant: variant, samples: state.samples) else { continue }
                let range = mesh.range(ofSubmesh: b.submesh)
                guard range.count > 0 else { continue }
                let command = icb.indirectRenderCommandAt(encoded)
                command.setRenderPipelineState(pso)
                command.setVertexBuffer(mesh.vertexBuffer, offset: 0, at: BufferIndex.vertices)
                if skinned, let skin = mesh.skinBuffer {
                    command.setVertexBuffer(skin, offset: 0, at: BufferIndex.skin)
                }
                command.setVertexBuffer(frameSlice.buffer, offset: frameSlice.offset, at: BufferIndex.frame)
                command.setFragmentBuffer(frameSlice.buffer, offset: frameSlice.offset, at: BufferIndex.frame)
                command.setVertexBuffer(instances.buffer, offset: instances.offset, at: BufferIndex.instances)
                command.setFragmentBuffer(instances.buffer, offset: instances.offset, at: BufferIndex.instances)
                if let joints = state.joints {
                    command.setVertexBuffer(joints.buffer, offset: joints.offset, at: BufferIndex.joints)
                }
                command.setVertexBuffer(
                    staticIndices.buffer, offset: staticIndices.offset, at: BufferIndex.instanceIndices)
                if kind == .forward {
                    bindIndirectFragment(command, state.lights ?? staticIndices, index: BufferIndex.lights)
                    bindIndirectFragment(
                        command, state.clusterCounts ?? staticIndices, index: BufferIndex.clusterCounts)
                    bindIndirectFragment(
                        command, state.clusterIndices ?? staticIndices, index: BufferIndex.clusterIndices)
                    bindIndirectFragment(command, state.probes ?? staticIndices, index: BufferIndex.probes)
                    bindIndirectFragment(
                        command, state.localMatrices ?? staticIndices, index: BufferIndex.localShadowMatrices)
                }
                command.setFragmentBuffer(materials.table, offset: 0, at: BufferIndex.materialTable)
                command.setFragmentBuffer(
                    materials.ids.buffer, offset: materials.ids.offset, at: BufferIndex.materialIds)
                command.drawIndexedPrimitives(
                    .triangle, indexCount: range.count, indexType: .uint32,
                    indexBuffer: mesh.indexBuffer, indexBufferOffset: range.offset * MemoryLayout<UInt32>.stride,
                    instanceCount: b.instanceCount, baseVertex: 0, baseInstance: b.firstInstance)
                encoded += 1
            }
            guard encoded > 0 else { return false }
            if liveIndirectBuffers.count >= 3 { liveIndirectBuffers.removeFirst() }
            liveIndirectBuffers.append(icb)
            enc.executeCommandsInBuffer(icb, range: 0..<encoded)
            Profiler.shared.updateRenderCounters { $0.drawCalls += encoded }
            return true
        }

        private func bindIndirectFragment(
            _ command: any MTLIndirectRenderCommand, _ slice: BufferSlice, index: Int
        ) {
            command.setFragmentBuffer(slice.buffer, offset: slice.offset, at: index)
        }

        /// Binds one argument buffer for every material in the opaque pass. Returns nil when
        /// the device is tier 1 or the encoder cannot be built, and the caller keeps per-draw binds.
        private func bindMaterialArguments(
            _ enc: any MTLRenderCommandEncoder, frame: RenderFrameData, kind: MeshPassKind,
            state: SceneFrameState, resources r: SceneResources
        ) -> MaterialArgumentBind? {
            guard let made = makeMaterialArguments(frame: frame, kind: kind, state: state, resources: r) else {
                return nil
            }
            enc.setFragmentBuffer(made.table, offset: 0, index: BufferIndex.materialTable)
            enc.setFragmentSlice(made.ids, index: BufferIndex.materialIds)
            for texture in made.textures { enc.useResource(texture, usage: .sample) }
            return made
        }

        private func makeMaterialArguments(
            frame: RenderFrameData, kind: MeshPassKind, state: SceneFrameState, resources r: SceneResources
        ) -> MaterialArgumentBind? {
            guard kind != .shadow, kind != .pick,
                DrawPolicy.useMaterialArgumentBuffers(argumentBuffersTier: capabilities.argumentBuffersTier)
            else { return nil }
            let batches = frame.opaque.map {
                (key: $0.material?.rawValue ?? "", first: $0.firstInstance, count: $0.instanceCount)
            }
            let plan = MaterialTablePlan.make(batches: batches, indexCount: frame.instanceIndices.count)
            guard let ids = r.allocator.upload(plan.slots.isEmpty ? [UInt32(0)] : plan.slots) else { return nil }
            let variant = ShaderVariant(clusters: state.useClusters, materialArguments: true)
            let functionName = kind == .prepass ? "prepassFragment" : "forwardFragment"
            guard let function = try? shaders.function(functionName, variant: variant) else { return nil }
            let encoder = function.makeArgumentEncoder(bufferIndex: BufferIndex.materialTable)
            let alignment = max(encoder.alignment, 1)
            let stride = (encoder.encodedLength + alignment - 1) / alignment * alignment
            guard let table = device.makeBuffer(length: stride * max(plan.keys.count, 1), options: .storageModeShared)
            else { return nil }
            table.label = "Ferox.MaterialArguments"
            var textures: [any MTLTexture] = []
            for (index, key) in plan.keys.enumerated() {
                let id = key.isEmpty ? nil : AssetID(key)
                let material = r.materials.material(
                    id, assets: r.assets, textures: r.textures, fallback: r.fallback, frame: r.frameIndex)
                guard let uniforms = r.allocator.upload([material.uniforms]) else { return nil }
                encoder.setArgumentBuffer(table, startOffset: 0, arrayElement: index)
                for (slot, texture) in material.textures.enumerated() where slot < 5 {
                    encoder.setTexture(texture, index: slot)
                    textures.append(texture)
                }
                encoder.setBuffer(uniforms.buffer, offset: uniforms.offset, index: 5)
            }
            return MaterialArgumentBind(table: table, ids: ids, textures: textures)
        }

        /// After culling, encodes one indirect command per opaque batch on the GPU. The instance
        /// count is the value in the draw-args buffer. Failure leaves the pass on immediate draws.
        func prepareCulledIndirectCommands(
            _ cb: any MTLCommandBuffer, kind: MeshPassKind, frame: RenderFrameData,
            state: SceneFrameState, resources r: SceneResources
        ) {
            culledCommands = nil
            let count = frame.opaque.count
            guard kind == .prepass || kind == .forward, capabilities.supportsMetal3, indirectCullingActive,
                state.gpuCulling, shaders.isAvailable("IndirectEncode"), count > 0,
                count <= DrawPolicy.maxGPUEncodedDraws,
                DrawPolicy.submission(indirectCommandBuffers: true, gpuIndirectDraws: true, encodesOnGPU: true)
                    == .gpuEncodedIndirectCommandBuffer
            else { return }
            let mixed = frame.opaque.contains { $0.doubleSided } && frame.opaque.contains { !$0.doubleSided }
            guard !mixed, frame.opaque.indices.allSatisfy({ i in i < state.cullable.count && state.cullable[i] })
            else { return }
            guard let drawArgs = state.drawArgs, let culled = state.culledIndices, let instances = state.instances,
                let joints = state.joints,
                let materials = makeMaterialArguments(
                    frame: frame, kind: kind, state: state, resources: r),
                let frameSlice = r.allocator.upload(value: state.uniforms)
            else { return }
            let words = IndirectDrawLayout.words
            let args = (drawArgs.buffer.contents() + drawArgs.offset).bindMemory(
                to: UInt32.self, capacity: count * words)
            var pipelines: [any MTLRenderPipelineState] = []
            var vertexBuffers: [any MTLBuffer] = []
            var indexBuffers: [any MTLBuffer] = []
            var skinBuffers: [any MTLBuffer] = []
            pipelines.reserveCapacity(count)
            for (i, b) in frame.opaque.enumerated() {
                guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { return }
                let skinned = b.skinned && mesh.skinBuffer != nil
                var variant = Self.variant(for: b, skinned: skinned, clusters: state.useClusters)
                variant.materialArguments = true
                guard let pso = try? meshPipeline(kind, variant: variant, samples: state.samples) else { return }
                pipelines.append(pso)
                vertexBuffers.append(mesh.vertexBuffer)
                indexBuffers.append(mesh.indexBuffer)
                skinBuffers.append(mesh.skinBuffer ?? mesh.vertexBuffer)
                args[i * words + IndirectDrawLayout.skinned] = skinned ? 1 : 0
            }
            guard let function = try? shaders.function("encodeCulledDraws"),
                let encode = try? shaders.computePipeline("encodeCulledDraws")
            else { return }
            let drawsEncoder = function.makeArgumentEncoder(bufferIndex: 1)
            let drawAlign = max(drawsEncoder.alignment, 1)
            let drawStride = (drawsEncoder.encodedLength + drawAlign - 1) / drawAlign * drawAlign
            let icbEncoder = function.makeArgumentEncoder(bufferIndex: 0)
            guard let drawTable = device.makeBuffer(length: drawStride * count, options: .storageModeShared),
                let icbArgs = device.makeBuffer(length: max(icbEncoder.encodedLength, 1), options: .storageModeShared)
            else { return }
            drawTable.label = "Ferox.GPUDraws"
            for i in 0..<count {
                drawsEncoder.setArgumentBuffer(drawTable, startOffset: 0, arrayElement: i)
                drawsEncoder.setRenderPipelineState(pipelines[i], index: 0)
                drawsEncoder.setBuffer(vertexBuffers[i], offset: 0, index: 1)
                drawsEncoder.setBuffer(indexBuffers[i], offset: 0, index: 2)
                drawsEncoder.setBuffer(skinBuffers[i], offset: 0, index: 3)
            }
            let desc = MTLIndirectCommandBufferDescriptor()
            desc.commandTypes = [.drawIndexed]
            desc.inheritBuffers = false
            desc.inheritPipelineState = false
            desc.maxVertexBufferBindCount = BufferIndex.instanceIndices + 1
            desc.maxFragmentBufferBindCount = BufferIndex.materialIds + 1
            guard let icb = device.makeIndirectCommandBuffer(descriptor: desc, maxCommandCount: count, options: [])
            else { return }
            icb.label = "Ferox.CulledCommands"
            icb.reset(0..<count)
            icbEncoder.setArgumentBuffer(icbArgs, offset: 0)
            icbEncoder.setIndirectCommandBuffer(icb, index: 0)
            let fallback = state.staticIndices ?? culled
            let lights = state.lights ?? fallback
            let clusterCounts = state.clusterCounts ?? fallback
            let clusterIndices = state.clusterIndices ?? fallback
            let probes = state.probes ?? fallback
            let localMatrices = state.localMatrices ?? fallback
            let limits = SIMD2<UInt32>(UInt32(count), kind == .forward ? 1 : 0)
            guard let limitSlice = r.allocator.upload(value: limits),
                let enc = cb.makeComputeCommandEncoder()
            else { return }
            enc.label = "Ferox.EncodeCulledCommands"
            enc.setBuffer(icbArgs, offset: 0, index: 0)
            enc.setBuffer(drawTable, offset: 0, index: 1)
            enc.setBuffer(drawArgs.buffer, offset: drawArgs.offset, index: 2)
            enc.setBuffer(frameSlice.buffer, offset: frameSlice.offset, index: 3)
            enc.setBuffer(instances.buffer, offset: instances.offset, index: 4)
            enc.setBuffer(culled.buffer, offset: culled.offset, index: 5)
            enc.setBuffer(joints.buffer, offset: joints.offset, index: 6)
            enc.setBuffer(materials.table, offset: 0, index: 7)
            enc.setBuffer(materials.ids.buffer, offset: materials.ids.offset, index: 8)
            enc.setBuffer(lights.buffer, offset: lights.offset, index: 9)
            enc.setBuffer(clusterCounts.buffer, offset: clusterCounts.offset, index: 10)
            enc.setBuffer(clusterIndices.buffer, offset: clusterIndices.offset, index: 11)
            enc.setBuffer(probes.buffer, offset: probes.offset, index: 12)
            enc.setBuffer(localMatrices.buffer, offset: localMatrices.offset, index: 13)
            enc.setBuffer(limitSlice.buffer, offset: limitSlice.offset, index: 14)
            enc.useResource(icb, usage: .write)
            for buffer in vertexBuffers + indexBuffers + skinBuffers { enc.useResource(buffer, usage: .read) }
            enc.dispatch1D(encode, count: count)
            enc.endEncoding()
            if liveIndirectBuffers.count >= 3 { liveIndirectBuffers.removeFirst() }
            liveIndirectBuffers.append(icb)
            var buffers = vertexBuffers + indexBuffers + skinBuffers
            buffers.append(contentsOf: [
                drawTable, icbArgs, materials.table, frameSlice.buffer, instances.buffer, culled.buffer,
                joints.buffer, materials.ids.buffer,
            ])
            culledCommands = CulledCommands(
                kind: kind, commands: icb, count: count, buffers: buffers, textures: materials.textures)
            Profiler.shared.updateRenderCounters { $0.computeDispatches += 1 }
        }

        /// Executes commands prepared by `prepareCulledIndirectCommands` for this pass.
        private func executeCulledCommands(
            _ enc: any MTLRenderCommandEncoder, kind: MeshPassKind, frame: RenderFrameData
        ) -> Bool {
            guard let prepared = culledCommands, prepared.kind == kind else { return false }
            culledCommands = nil
            enc.setCullMode(frame.opaque.allSatisfy { !$0.doubleSided } ? .back : .none)
            for buffer in prepared.buffers { enc.useResource(buffer, usage: .read) }
            for texture in prepared.textures { enc.useResource(texture, usage: .sample) }
            enc.executeCommandsInBuffer(prepared.commands, range: 0..<prepared.count)
            Profiler.shared.updateRenderCounters { $0.drawCalls += prepared.count }
            return true
        }

        /// Issues one batch, directly or from GPU-written indirect arguments.
        private func draw(
            _ enc: any MTLRenderCommandEncoder, batch b: DrawBatch, mesh: GPUMesh, skinned: Bool,
            indirect: (BufferSlice, Int)?, boundVertex: inout ObjectIdentifier?, boundSkin: inout ObjectIdentifier?
        ) {
            let vertexID = ObjectIdentifier(mesh.vertexBuffer as AnyObject)
            if DrawPolicy.shouldBindVertexBuffer(previous: boundVertex, next: vertexID) {
                enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: BufferIndex.vertices)
                boundVertex = vertexID
            }
            if skinned, let skin = mesh.skinBuffer {
                let skinID = ObjectIdentifier(skin as AnyObject)
                if DrawPolicy.shouldBindVertexBuffer(previous: boundSkin, next: skinID) {
                    enc.setVertexBuffer(skin, offset: 0, index: BufferIndex.skin)
                    boundSkin = skinID
                }
            }
            let range = mesh.range(ofSubmesh: b.submesh)
            guard range.count > 0 else { return }
            if let (args, i) = indirect {
                // indexStart in the arguments is in indices, so the buffer offset stays 0.
                enc.drawIndexedPrimitives(
                    type: .triangle, indexType: .uint32, indexBuffer: mesh.indexBuffer,
                    indexBufferOffset: 0, indirectBuffer: args.buffer,
                    indirectBufferOffset: args.offset + i * Self.drawArgsStride)
            } else {
                enc.drawIndexedPrimitives(
                    type: .triangle, indexCount: range.count, indexType: .uint32,
                    indexBuffer: mesh.indexBuffer,
                    indexBufferOffset: range.offset * MemoryLayout<UInt32>.stride,
                    instanceCount: b.instanceCount, baseVertex: 0, baseInstance: b.firstInstance)
            }
            // Indirect counts are known only on the GPU; the CPU counters report the upper bound.
            Profiler.shared.updateRenderCounters {
                $0.drawCalls += 1
                $0.instances += b.instanceCount
                $0.triangles += range.count / 3 * b.instanceCount
            }
        }
    }
#endif
