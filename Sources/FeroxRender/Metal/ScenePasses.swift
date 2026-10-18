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

/// The frame's GPU-side scene data, uploaded once and shared by every pass.
struct SceneFrameState {
    var uniforms: FrameUniforms
    var instances: BufferSlice?
    /// CPU-built `instanceIndices` (shadow casters, transparents, non-cullable batches).
    var staticIndices: BufferSlice?
    /// Indices compacted by `cullInstances` (nil when GPU culling is off).
    var culledIndices: BufferSlice?
    /// One `MTLDrawIndexedPrimitivesIndirectArguments` per opaque batch.
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
    case prepass, forward, transparent, shadow
}

final class ScenePasses {
    /// Cluster grid (must match `FrameUniforms.clusterDims` defaults and Clusters.metal).
    static let clusterDims = SIMD4<UInt32>(16, 9, 24, 64)
    static var clusterCount: Int { Int(clusterDims.x * clusterDims.y * clusterDims.z) }
    /// Bytes of `MTLDrawIndexedPrimitivesIndirectArguments` (5 × UInt32).
    static let drawArgsStride = 20

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
    func meshPipeline(_ kind: MeshPassKind, variant: ShaderVariant, samples: Int) throws -> any MTLRenderPipelineState {
        let s = kind == .shadow ? 1 : max(samples, 1)
        let key = "\(kind.rawValue)-\(variant.key)-s\(s)"
        return try shaders.renderPipeline(key) { d in
            d.vertexDescriptor = Self.vertexDescriptor(skinned: variant.skinning)
            d.rasterSampleCount = s
            switch kind {
            case .shadow:
                d.vertexFunction = try shaders.function("shadowVertex", variant: variant)
                // Opaque casters need no fragment stage at all (depth-only fast path).
                d.fragmentFunction = variant.alphaTest
                    ? try shaders.function("shadowAlphaTestFragment", variant: variant) : nil
                d.depthAttachmentPixelFormat = .depth32Float
            case .prepass:
                d.vertexFunction = try shaders.function("meshVertex", variant: variant)
                d.fragmentFunction = try shaders.function("prepassFragment", variant: variant)
                d.colorAttachments[0].pixelFormat = TargetFormat.normal
                d.colorAttachments[1].pixelFormat = TargetFormat.motion
                d.depthAttachmentPixelFormat = TargetFormat.depth
                d.stencilAttachmentPixelFormat = TargetFormat.depth
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
        ShaderVariant(skinning: skinned, alphaTest: alphaTest ?? b.alphaTest, vertexColor: true, clusters: clusters,
                      unlit: b.unlit)
    }

    // MARK: - Frame preparation

    /// Uploads instances, indices, lights, joints and probes, computes cascades, and fills
    /// the lighting-related fields of `uniforms`.
    func prepare(_ frame: RenderFrameData, uniforms: FrameUniforms, graphics: ResolvedGraphics, probes: [ProbeData],
                 targets: RenderTargets, resources r: SceneResources) -> SceneFrameState {
        var u = uniforms
        var state = SceneFrameState(uniforms: u)
        let a = r.allocator
        cullBatchIds = nil
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
        state.localMatrices = a.upload(state.localSlices.isEmpty ? [Mat4.identity] : state.localSlices.map(\.viewProjection))
        state.probes = a.upload(probes.isEmpty ? [ProbeData()] : probes)

        // Lights and probes.
        var flags = FrameFlags.reverseZ
        if state.useClusters { flags |= FrameFlags.clustered }
        if shadows.softness == .pcss { flags |= FrameFlags.pcss }
        if shadows.softness == .hard { flags |= FrameFlags.hardShadows }
        u.clusterDims = Self.clusterDims
        if let cam = frame.camera {
            u.clusterParams = RenderMath.clusterParams(near: cam.camera.near, far: cam.camera.far,
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
        state.cascadeMatrices = cascades(frame, settings: graphics.settings.shadows,
                                         rayTraced: graphics.rayTracedShadows, uniforms: &u)
        if !state.cascadeMatrices.isEmpty { flags |= FrameFlags.shadows }
        u.lightCounts = SIMD4(UInt32(frame.punctualCount), UInt32(frame.directionalCount), UInt32(probes.count), flags)

        if state.useClusters {
            state.clusterCounts = a.allocate(length: Self.clusterCount * MemoryLayout<UInt32>.stride)
            state.clusterIndices = a.allocate(length: Self.clusterCount * Int(Self.clusterDims.w) * MemoryLayout<UInt16>.stride)
            if state.clusterCounts == nil || state.clusterIndices == nil { state.useClusters = false }
        }

        prepareCulling(frame, graphics: graphics, targets: targets, uniforms: u, state: &state, allocator: a)
        state.uniforms = u
        return state
    }

    /// Computes cascade matrices and the shadow uniforms. Returns an empty array when the
    /// shadow-map path is inactive (no sun, sun casts no shadows, disabled, or replaced by
    /// ray-traced shadows).
    private func cascades(_ frame: RenderFrameData, settings: ShadowSettings, rayTraced: Bool,
                          uniforms u: inout FrameUniforms) -> [Mat4] {
        u.shadowParams = .zero
        guard settings.enabled, !rayTraced, let sun = frame.sun, sun.castsShadows, let cam = frame.camera,
              !frame.shadowCasters.isEmpty else { return [] }
        let count = min(max(settings.cascades, 1), 4)
        let resolution = min(max(settings.resolution, 256), 8192)
        let near = cam.camera.near
        let far = min(cam.camera.far, max(settings.maxDistance, near + 1))
        let splits = RenderMath.cascadeSplits(near: near, far: far, count: count)
        // Unjittered: cascades must not wobble with TAA jitter.
        let inverse = cam.viewProjection.inverse
        var matrices: [Mat4] = []
        for c in 0..<count {
            let corners = RenderMath.frustumSliceCorners(inverseViewProjection: inverse, near: near,
                                                         far: cam.camera.far, from: splits[c], to: splits[c + 1])
            matrices.append(RenderMath.stableCascadeMatrix(corners: corners, towardsLight: sun.towardsLight,
                                                           resolution: resolution))
        }
        let m = matrices
        u.shadowMatrices = (m[0], m[min(1, count - 1)], m[min(2, count - 1)], m[min(3, count - 1)])
        // Split ends for cascades 0…3; unused entries repeat the far distance.
        u.cascadeSplits = Vec4(splits[min(1, count)], splits[min(2, count)], splits[min(3, count)], splits[count])
        u.shadowParams = Vec4(settings.depthBias, settings.normalBias, 1 / Float(resolution), Float(count))
        return matrices
    }

    /// Decides which opaque batches the GPU culls and uploads the culling inputs.
    ///
    /// A batch is GPU-cullable only when every instance it draws maps back to it through
    /// `instanceBatch` (an instance with several submeshes belongs to several batches, but
    /// `cullInstances` can append it to only one). Other batches draw directly from the
    /// static index list, unculled on the GPU (they were already frustum-culled on the CPU).
    private func prepareCulling(_ frame: RenderFrameData, graphics: ResolvedGraphics, targets: RenderTargets,
                                uniforms u: FrameUniforms, state: inout SceneFrameState, allocator a: FrameAllocator) {
        let batches = frame.opaque
        guard graphics.settings.gpuDrivenCulling, !batches.isEmpty, !frame.instances.isEmpty else { return }
        var cullable = [Bool](repeating: false, count: batches.count)
        for (bi, b) in batches.enumerated() {
            var ok = b.instanceCount > 0
            for k in b.firstInstance..<(b.firstInstance + b.instanceCount) where ok {
                let inst = Int(frame.instanceIndices[k])
                ok = inst < frame.instanceBatch.count && frame.instanceBatch[inst] == UInt32(bi)
            }
            cullable[bi] = ok
        }
        guard cullable.contains(true) else { return }

        // Instances whose batch is not cullable are skipped by the kernel (out-of-range id).
        let batchIds = frame.instanceBatch.map { $0 != .max && cullable[Int($0)] ? $0 : UInt32.max }
        // Draw arguments: instanceCount is zeroed by `resetDrawArgs` and rebuilt by the cull.
        var args: [UInt32] = []
        args.reserveCapacity(batches.count * 5)
        for b in batches {
            args += [0, UInt32(b.instanceCount), 0, 0, UInt32(b.firstInstance)]
        }
        guard let ids = a.upload(batchIds), let argSlice = a.upload(args),
              let culled = a.allocate(length: max(frame.instanceIndices.count, 1) * MemoryLayout<UInt32>.stride)
        else { return }
        state.drawArgs = argSlice
        state.culledIndices = culled
        state.cullable = cullable
        cullBatchIds = ids

        var cu = CullUniforms()
        cu.planes = RenderMath.packedPlanes(Frustum(viewProjection: u.unjitteredViewProjection))
        let occlusion = graphics.settings.occlusionCulling && hizValid && targets.hiz != nil
        if occlusion, let hiz = targets.hiz {
            cu.previousViewProjection = hizViewProjection
            cu.hizSize = Vec4(Float(hiz.width), Float(hiz.height), Float(hiz.mipmapLevelCount), 0)
        }
        cu.counts = SIMD4(UInt32(frame.instances.count), occlusion ? 1 : 0, UInt32(batches.count), 0)
        state.cullUniforms = cu
    }

    /// Batch ids uploaded by `prepareCulling` for the current frame.
    private var cullBatchIds: BufferSlice?

    /// Patches index ranges into the draw arguments once meshes are resident. Batches whose
    /// mesh is not resident yet keep indexCount 0 and draw nothing.
    private func patchDrawArgs(_ frame: RenderFrameData, state: SceneFrameState, resources r: SceneResources) {
        guard let args = state.drawArgs else { return }
        let p = (args.buffer.contents() + args.offset).bindMemory(to: UInt32.self, capacity: frame.opaque.count * 5)
        for (i, b) in frame.opaque.enumerated() where state.cullable[i] {
            guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
            let range = mesh.range(ofSubmesh: b.submesh)
            p[i * 5 + 0] = UInt32(range.count)
            p[i * 5 + 2] = UInt32(range.offset)
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
    func encodeShadows(_ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
                       settings: ShadowSettings, resources r: SceneResources) -> any MTLTexture {
        guard !state.cascadeMatrices.isEmpty,
              let map = ensureShadowMap(resolution: min(max(settings.resolution, 256), 8192),
                                        cascades: state.cascadeMatrices.count)
        else { return r.fallback.shadowArray }

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
            encodeCasters(enc, frame: frame, state: state, resources: r, include: nil)
            enc.endEncoding()
            Profiler.shared.updateRenderCounters { $0.renderPasses += 1 }
        }
        return map
    }

    /// Draws the shadow casters into the bound depth target. `include` filters batches
    /// (local lights draw only casters that reach them); nil draws every caster.
    private func encodeCasters(_ enc: any MTLRenderCommandEncoder, frame: RenderFrameData, state: SceneFrameState,
                               resources r: SceneResources, include: ((DrawBatch) -> Bool)?) {
        for b in frame.shadowCasters where include?(b) ?? true {
            guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
            let skinned = b.skinned && mesh.skinBuffer != nil
            let variant = Self.variant(for: b, skinned: skinned, clusters: false)
            guard let pso = try? meshPipeline(.shadow, variant: variant, samples: 1) else { continue }
            enc.setRenderPipelineState(pso)
            enc.setCullMode(b.doubleSided ? .none : .back)
            if b.alphaTest {
                let m = r.materials.material(b.material, assets: r.assets, textures: r.textures,
                                             fallback: r.fallback, frame: r.frameIndex)
                enc.setFragmentValue(m.uniforms, index: BufferIndex.material, allocator: r.allocator)
                enc.setFragmentTexture(m.textures[0], index: 0)
            }
            draw(enc, batch: b, mesh: mesh, skinned: skinned, indirect: nil)
        }
    }

    /// Ensures the point/spot shadow array matches the settings. Its capacity is the whole
    /// budget, so it is not reallocated as lights come and go.
    private func ensureLocalShadowMap(resolution: Int, slices: Int) -> (any MTLTexture)? {
        if let k = localShadowKey, k.resolution == resolution, k.slices == slices, let t = localShadowMap { return t }
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
            Log.error("Render", "Could not allocate a \(resolution)² × \(slices) local shadow map; local shadows disabled")
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
    func encodeLocalShadows(_ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
                            settings: ShadowSettings, resources r: SceneResources) -> any MTLTexture {
        let budget = min(max(settings.localShadowSlices, 1), LocalShadowPlanner.maxSlices)
        guard !state.localSlices.isEmpty,
              let map = ensureLocalShadowMap(resolution: min(max(settings.localResolution, 64), 4096), slices: budget)
        else { return r.fallback.shadowArray }

        // Instance bounds per caster batch, for culling batches against each light's sphere.
        func reaches(_ b: DrawBatch, _ slice: LocalShadowSlice) -> Bool {
            for k in b.firstInstance..<(b.firstInstance + b.instanceCount) where k < frame.instanceIndices.count {
                let i = Int(frame.instanceIndices[k])
                guard i < frame.instances.count else { continue }
                let bounds = frame.instances[i].bounds
                let reach = slice.range + bounds.w
                if (bounds.xyz - slice.position).lengthSquared <= reach * reach { return true }
            }
            return false
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
            encodeCasters(enc, frame: frame, state: state, resources: r, include: { reaches($0, slice) })
            enc.endEncoding()
            Profiler.shared.updateRenderCounters { $0.renderPasses += 1 }
        }
        return map
    }

    // MARK: - Compute: clusters and culling

    /// Assigns punctual lights to clusters and runs GPU culling. Both are independent of
    /// the prepass and share one compute encoder.
    func encodeCompute(_ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
                       targets: RenderTargets, resources r: SceneResources) {
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
                enc.setSlice(state.drawArgs, index: 0)
                enc.setValue(state.cullUniforms, index: 1, allocator: r.allocator)
                // The encoder's default serial dispatch type runs the reset before the cull.
                enc.dispatch1D(reset, count: frame.opaque.count)
                enc.setValue(state.cullUniforms, index: 0, allocator: r.allocator)
                enc.setSlice(state.instances, index: 1)
                enc.setSlice(cullBatchIds, index: 2)
                enc.setSlice(state.drawArgs, index: 3)
                enc.setSlice(state.culledIndices, index: 4)
                enc.setTexture(targets.hiz ?? r.fallback.white, index: 0)
                enc.dispatch1D(cull, count: frame.instances.count)
                Profiler.shared.updateRenderCounters { $0.computeDispatches += 2 }
            } catch {
                Log.error("Render", "GPU culling unavailable: \(error)")
            }
        }
    }

    // MARK: - Prepass

    /// Depth + normal/roughness + motion for opaque geometry. With MSAA, the attachments
    /// resolve into the single-sample targets that SSAO, TAA and ray tracing sample, while
    /// the multisampled depth is kept for the main pass.
    func encodePrepass(_ cb: any MTLCommandBuffer, frame: RenderFrameData, state: SceneFrameState,
                       targets: RenderTargets, resources r: SceneResources) {
        guard let depth = targets.depth, let normal = targets.normal, let motion = targets.motion else { return }
        let msaa = targets.depthMSAA != nil
        let pass = MTLRenderPassDescriptor()
        let c0 = pass.colorAttachments[0]!, c1 = pass.colorAttachments[1]!
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

        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Ferox.Prepass"
        defer {
            enc.endEncoding()
            Profiler.shared.updateRenderCounters { $0.renderPasses += 1 }
        }
        guard !frame.opaque.isEmpty else { return }
        enc.setDepthStencilState(depthState(.greater, write: true))
        enc.setFrontFacing(frontFacing)
        bindCommon(enc, state: state, resources: r)
        encodeOpaqueDraws(enc, kind: .prepass, frame: frame, state: state, resources: r, lighting: nil)
    }

    /// Builds the Hi-Z pyramid from this frame's resolved depth for next frame's culling.
    func encodeHiZ(_ cb: any MTLCommandBuffer, state: SceneFrameState, targets: RenderTargets) {
        guard state.gpuCulling, let depth = targets.depth, !targets.hizMips.isEmpty,
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Ferox.HiZ"
        defer { enc.endEncoding() }
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
    func encodeOpaque(_ enc: any MTLRenderCommandEncoder, frame: RenderFrameData, state: SceneFrameState,
                      lighting: LightingTextures, resources r: SceneResources) {
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
    func encodeSky(_ enc: any MTLRenderCommandEncoder, environment: any MTLTexture, state: SceneFrameState,
                   resources r: SceneResources) {
        guard let pso = try? skyPipeline(samples: state.samples) else { return }
        enc.pushDebugGroup("Ferox.Sky")
        defer { enc.popDebugGroup() }
        enc.setRenderPipelineState(pso)
        enc.setDepthStencilState(depthState(.greaterEqual, write: false))
        enc.setCullMode(.none)
        enc.setFragmentValue(state.uniforms, index: BufferIndex.frame, allocator: r.allocator)
        enc.setFragmentTexture(environment, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        Profiler.shared.updateRenderCounters { $0.drawCalls += 1; $0.pipelineStateChanges += 1 }
    }

    /// Transparent geometry, back to front, premultiplied blending, depth-tested only.
    func encodeTransparent(_ enc: any MTLRenderCommandEncoder, frame: RenderFrameData, state: SceneFrameState,
                           lighting: LightingTextures, resources r: SceneResources) {
        guard !frame.transparent.isEmpty else { return }
        enc.pushDebugGroup("Ferox.Transparent")
        defer { enc.popDebugGroup() }
        enc.setDepthStencilState(depthState(.greaterEqual, write: false))
        enc.setFrontFacing(frontFacing)
        bindCommon(enc, state: state, resources: r)
        bindLighting(enc, state: state, lighting: lighting, resources: r)
        var last: (any MTLRenderPipelineState)?
        var lastMaterial: AssetID??
        for b in frame.transparent {
            guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
            let skinned = b.skinned && mesh.skinBuffer != nil
            let variant = Self.variant(for: b, skinned: skinned, clusters: state.useClusters, alphaTest: false)
            guard let pso = try? meshPipeline(.transparent, variant: variant, samples: state.samples) else { continue }
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
            draw(enc, batch: b, mesh: mesh, skinned: skinned, indirect: nil)
        }
    }

    // MARK: - Draw helpers

    /// Buffers shared by every mesh draw in a pass.
    private func bindCommon(_ enc: any MTLRenderCommandEncoder, state: SceneFrameState, resources r: SceneResources) {
        enc.setVertexValue(state.uniforms, index: BufferIndex.frame, allocator: r.allocator)
        enc.setFragmentValue(state.uniforms, index: BufferIndex.frame, allocator: r.allocator)
        enc.setVertexSlice(state.instances, index: BufferIndex.instances)
        enc.setFragmentSlice(state.instances, index: BufferIndex.instances)
        enc.setVertexSlice(state.joints, index: BufferIndex.joints)
        enc.setFragmentSamplerState(r.samplers.anisotropicRepeat, index: 0)
    }

    /// Lights, clusters, probes and the IBL / shadow / RT / AO textures for forward shading.
    private func bindLighting(_ enc: any MTLRenderCommandEncoder, state: SceneFrameState, lighting l: LightingTextures,
                              resources r: SceneResources) {
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
        let m = r.materials.material(id, assets: r.assets, textures: r.textures, fallback: r.fallback,
                                     frame: r.frameIndex)
        enc.setFragmentValue(m.uniforms, index: BufferIndex.material, allocator: r.allocator)
        for (i, t) in m.textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        Profiler.shared.updateRenderCounters { $0.textureBinds += m.textures.count }
    }

    /// Opaque batches for the prepass or forward pass. Batches are already sorted by
    /// material and mesh, so state changes happen only at group boundaries.
    private func encodeOpaqueDraws(_ enc: any MTLRenderCommandEncoder, kind: MeshPassKind, frame: RenderFrameData,
                                   state: SceneFrameState, resources r: SceneResources, lighting: LightingTextures?) {
        var last: (any MTLRenderPipelineState)?
        var lastMaterial: AssetID??
        var boundIndices: Bool?  // true = culled list bound
        for (i, b) in frame.opaque.enumerated() {
            guard let mesh = r.meshes.mesh(b.mesh, assets: r.assets, frame: r.frameIndex) else { continue }
            let skinned = b.skinned && mesh.skinBuffer != nil
            let variant = Self.variant(for: b, skinned: skinned, clusters: state.useClusters)
            guard let pso = try? meshPipeline(kind, variant: variant, samples: state.samples) else { continue }
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
            let gpu = state.gpuCulling && state.cullable[i]
            if boundIndices != gpu {
                enc.setVertexSlice(gpu ? state.culledIndices : state.staticIndices, index: BufferIndex.instanceIndices)
                boundIndices = gpu
            }
            draw(enc, batch: b, mesh: mesh, skinned: skinned,
                 indirect: gpu ? state.drawArgs.map { ($0, i) } : nil)
        }
    }

    /// Issues one batch, directly or from GPU-written indirect arguments.
    private func draw(_ enc: any MTLRenderCommandEncoder, batch b: DrawBatch, mesh: GPUMesh, skinned: Bool,
                      indirect: (BufferSlice, Int)?) {
        enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: BufferIndex.vertices)
        if skinned, let skin = mesh.skinBuffer { enc.setVertexBuffer(skin, offset: 0, index: BufferIndex.skin) }
        let range = mesh.range(ofSubmesh: b.submesh)
        guard range.count > 0 else { return }
        if let (args, i) = indirect {
            // indexStart in the arguments is in indices, so the buffer offset stays 0.
            enc.drawIndexedPrimitives(type: .triangle, indexType: .uint32, indexBuffer: mesh.indexBuffer,
                                      indexBufferOffset: 0, indirectBuffer: args.buffer,
                                      indirectBufferOffset: args.offset + i * Self.drawArgsStride)
        } else {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: range.count, indexType: .uint32,
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
