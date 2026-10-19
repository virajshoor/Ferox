#if canImport(Metal)
    import FeroxCore
    import Foundation
    import Metal

    /// Pixel formats of the persistent targets. Kept in one place so pipelines and attachments
    /// cannot disagree.
    enum TargetFormat {
        /// Scene colour before tone mapping (pre-exposed linear radiance).
        static let hdr: MTLPixelFormat = .rgba16Float
        /// Reverse-Z depth plus the 2D mask stencil.
        static let depth: MTLPixelFormat = .depth32Float_stencil8
        /// World normal (xyz · 0.5 + 0.5) and roughness.
        static let normal: MTLPixelFormat = .rgba16Float
        /// Screen-space motion in UV units (current − previous).
        static let motion: MTLPixelFormat = .rg16Float
        /// Ambient occlusion (1 = unoccluded).
        static let ao: MTLPixelFormat = .r8Unorm
        /// Tone-mapped, sRGB-encoded colour stored in a unorm texture. Viewed as
        /// `rgba8Unorm_srgb` when presented so the drawable receives correct values.
        static let ldr: MTLPixelFormat = .rgba8Unorm
        static let ldrSRGBView: MTLPixelFormat = .rgba8Unorm_srgb
        /// The drawable format the presenter expects (`CAMetalLayer.pixelFormat`).
        static let drawable: MTLPixelFormat = .bgra8Unorm_srgb
        /// Hierarchical-Z pyramid (farthest reverse-Z depth per texel).
        static let hiz: MTLPixelFormat = .r32Float
    }

    /// The persistent, size-dependent textures of one view: the prepass G-buffer, the HDR scene
    /// colour, temporal history and the LDR ping-pong pair.
    ///
    /// Targets are reallocated only when `Config` changes (resize, MSAA or feature toggle). Each
    /// allocation is reported to `MemoryTracker` under "GPU.RenderTargets" and released on
    /// reallocation and in `deinit`, so the memory overlay stays exact.
    final class RenderTargets {
        struct Config: Equatable {
            var renderWidth: Int
            var renderHeight: Int
            var outputWidth: Int
            var outputHeight: Int
            var msaaSamples: Int
            /// Allocates the two output-resolution history buffers (TAA / temporal upscaling).
            var temporalHistory: Bool
            /// Allocates the Hi-Z pyramid (GPU occlusion culling).
            var hiz: Bool
            /// Allocates normal and motion. False for a frame that skips the geometry prepass.
            var geometryPrepass: Bool = true
            /// Which post scratches exist, so the heap can alias them with earlier targets.
            var features = HeapFeatures()
        }

        /// Signals between encoders that reuse one heap allocation. The same fence also
        /// orders the next frame: the first encoder of frame N+1 waits for the last
        /// encoder of frame N, so one untracked heap is not written while a previous
        /// frame still reads it. Nil when nothing aliases.
        final class AliasSync {
            let fence: any MTLFence
            private var signaled = false
            init(fence: any MTLFence) { self.fence = fence }
            func begin(_ encoder: any MTLCommandEncoder) {
                if signaled {
                    encoder.waitForFence(fence)
                    signaled = false
                }
            }
            func end(_ encoder: any MTLCommandEncoder) {
                encoder.updateFence(fence)
                signaled = true
            }
        }

        let device: any MTLDevice
        private(set) var config: Config?
        private var trackedBytes = 0

        // MARK: Render resolution

        /// Single-sample depth (the MSAA resolve target when multisampling). Sampled by SSAO,
        /// TAA, DOF, ray tracing and the Hi-Z builder.
        private(set) var depth: (any MTLTexture)?
        /// Multisampled depth shared by the prepass and the main pass (nil without MSAA).
        private(set) var depthMSAA: (any MTLTexture)?
        private(set) var hdr: (any MTLTexture)?
        private(set) var hdrMSAA: (any MTLTexture)?
        private(set) var normal: (any MTLTexture)?
        private(set) var normalMSAA: (any MTLTexture)?
        private(set) var motion: (any MTLTexture)?
        private(set) var motionMSAA: (any MTLTexture)?
        /// Screen-space or ray-traced ambient occlusion at render resolution.
        private(set) var ao: (any MTLTexture)?
        private(set) var hiz: (any MTLTexture)?
        /// Per-mip views of `hiz` (compute kernels write one level at a time).
        private(set) var hizMips: [any MTLTexture] = []

        // MARK: Output resolution

        /// TAA / temporal-upscaler history ping-pong (rgba16Float, output size).
        private(set) var history: [any MTLTexture] = []
        /// Index of the history texture written this frame; the other one is read.
        private(set) var historyIndex = 0
        /// False after any reallocation or camera cut, so the resolve ignores stale history.
        var historyValid = false
        /// LDR ping-pong (tone-mapped, sRGB-encoded) at output size.
        private(set) var ldr: [any MTLTexture] = []
        /// Placed scratches (bloom, depth of field, SSAO raw, SMAA). Empty when the heap
        /// could not be built and the pool allocated them instead.
        private var placed: [TransientResource: any MTLTexture] = [:]
        private(set) var heapLayout = HeapLayout(placements: [], barriers: [], byteSize: 0)
        var aliasSync: AliasSync?

        init(device: any MTLDevice) { self.device = device }

        func scratch(_ resource: TransientResource) -> (any MTLTexture)? { placed[resource] }

        deinit { MemoryTracker.shared.free("GPU.RenderTargets", bytes: trackedBytes) }

        /// The depth texture the passes render into (MSAA when enabled).
        var depthAttachment: (any MTLTexture)? { depthMSAA ?? depth }

        /// Ensures every target matches `config`. Returns true when textures were reallocated
        /// (history and anything derived from the old targets must be discarded).
        @discardableResult
        func ensure(_ newConfig: Config) throws -> Bool {
            if newConfig == config { return false }
            release()
            let c = newConfig
            let rw = max(c.renderWidth, 1)
            let rh = max(c.renderHeight, 1)
            let ow = max(c.outputWidth, 1)
            let oh = max(c.outputHeight, 1)
            let msaa = c.msaaSamples > 1 ? c.msaaSamples : 1
            let rt: MTLTextureUsage = [.renderTarget, .shaderRead]
            do {
                try placeTransients(c)
            } catch {
                // A placement heap can fail on a device that rejects the size. Standalone
                // textures keep the frame rendering; nothing aliases, so no fence is needed.
                Log.warning("Render", "Transient heap unavailable (\(error)); allocating targets separately")
                release()
                depth = try make("Ferox.Depth", TargetFormat.depth, rw, rh, rt)
                hdr = try make("Ferox.HDR", TargetFormat.hdr, rw, rh, [.renderTarget, .shaderRead, .shaderWrite])
                if c.geometryPrepass {
                    normal = try make("Ferox.Normal", TargetFormat.normal, rw, rh, rt)
                    motion = try make("Ferox.Motion", TargetFormat.motion, rw, rh, rt)
                }
                if msaa > 1 {
                    depthMSAA = try make("Ferox.DepthMSAA", TargetFormat.depth, rw, rh, .renderTarget, samples: msaa)
                    hdrMSAA = try make("Ferox.HDRMSAA", TargetFormat.hdr, rw, rh, .renderTarget, samples: msaa)
                    if c.geometryPrepass {
                        normalMSAA = try make(
                            "Ferox.NormalMSAA", TargetFormat.normal, rw, rh, .renderTarget, samples: msaa)
                        motionMSAA = try make(
                            "Ferox.MotionMSAA", TargetFormat.motion, rw, rh, .renderTarget, samples: msaa)
                    }
                }
                ao = try make("Ferox.AO", TargetFormat.ao, rw, rh, [.renderTarget, .shaderRead, .shaderWrite])
                ldr = try (0..<2).map { i in
                    try make(
                        "Ferox.LDR\(i)", TargetFormat.ldr, ow, oh,
                        [.renderTarget, .shaderRead, .shaderWrite, .pixelFormatView])
                }
            }

            if c.hiz {
                let mips = RenderMath.mipCount(rw, rh)
                let h = try make("Ferox.HiZ", TargetFormat.hiz, rw, rh, [.shaderRead, .shaderWrite], mips: mips)
                hiz = h
                hizMips = (0..<mips).compactMap { level in
                    h.makeTextureView(
                        pixelFormat: TargetFormat.hiz, textureType: .type2D,
                        levels: level..<(level + 1), slices: 0..<1)
                }
            }
            if c.temporalHistory {
                history = try (0..<2).map { i in
                    try make("Ferox.History\(i)", TargetFormat.hdr, ow, oh, [.renderTarget, .shaderRead, .shaderWrite])
                }
            }
            config = c
            historyValid = false
            historyIndex = 0
            return true
        }

        /// Advances the history ping-pong. Call once per frame before the temporal resolve.
        func swapHistory() { historyIndex ^= 1 }

        /// History written this frame (nil when temporal history is disabled).
        var currentHistory: (any MTLTexture)? { history.isEmpty ? nil : history[historyIndex] }
        /// History written last frame.
        var previousHistory: (any MTLTexture)? { history.isEmpty ? nil : history[historyIndex ^ 1] }

        /// Frees every target (used on resize and by `Renderer.purgeCaches`).
        func release() {
            MemoryTracker.shared.free("GPU.RenderTargets", bytes: trackedBytes)
            trackedBytes = 0
            depth = nil
            depthMSAA = nil
            hdr = nil
            hdrMSAA = nil
            normal = nil
            normalMSAA = nil
            motion = nil
            motionMSAA = nil
            ao = nil
            hiz = nil
            hizMips = []
            history = []
            ldr = []
            placed = [:]
            heap = nil
            heapLayout = HeapLayout(placements: [], barriers: [], byteSize: 0)
            aliasSync = nil
            config = nil
            historyValid = false
        }

        private var heap: (any MTLHeap)?

        /// One placement heap. Offsets come from `TransientHeapPlan`. Aliased textures are
        /// untracked; `aliasSync` is the fence between a resource and whatever reuses its bytes.
        private func placeTransients(_ newConfig: Config) throws {
            var features = newConfig.features
            features.geometryPrepass = newConfig.geometryPrepass
            features.msaa = newConfig.msaaSamples > 1
            let requests = TransientHeapPlan.requests(
                renderWidth: newConfig.renderWidth, renderHeight: newConfig.renderHeight,
                outputWidth: newConfig.outputWidth, outputHeight: newConfig.outputHeight,
                features: features, msaaSamples: newConfig.msaaSamples)
            var footprints: [TransientFootprint] = []
            var descriptors: [TransientResource: MTLTextureDescriptor] = [:]
            for request in requests {
                let descriptor = self.descriptor(request)
                let aligned = device.heapTextureSizeAndAlign(descriptor: descriptor)
                guard aligned.size > 0 else { throw RenderError.allocation(request.resource.rawValue) }
                footprints.append(
                    TransientFootprint(
                        resource: request.resource, byteSize: aligned.size, alignment: max(aligned.align, 1)))
                descriptors[request.resource] = descriptor
            }
            let layout = TransientHeapPlan.layout(footprints: footprints, features: features)
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.type = .placement
            heapDescriptor.storageMode = .private
            heapDescriptor.size = max(layout.byteSize, 1)
            let aliasing = !layout.barriers.isEmpty
            if aliasing { heapDescriptor.hazardTrackingMode = .untracked }
            guard let heap = device.makeHeap(descriptor: heapDescriptor) else {
                throw RenderError.allocation("Ferox.RenderTargetHeap")
            }
            heap.label = "Ferox.RenderTargetHeap"
            self.heap = heap
            var made: [TransientResource: any MTLTexture] = [:]
            for request in requests {
                guard let descriptor = descriptors[request.resource],
                    let placement = layout.placement(of: request.resource)
                else { throw RenderError.allocation(request.resource.rawValue) }
                descriptor.heapOffset = placement.offset
                if aliasing { descriptor.hazardTrackingMode = .untracked }
                guard let texture = heap.makeTexture(descriptor: descriptor) else {
                    throw RenderError.allocation(request.resource.rawValue)
                }
                texture.label = TransientHeapPlan.label(request.resource) ?? "Ferox.\(request.resource.rawValue)"
                made[request.resource] = texture
            }
            assign(made)
            heapLayout = layout
            trackedBytes += layout.byteSize
            MemoryTracker.shared.allocate("GPU.RenderTargets", bytes: layout.byteSize)
            if aliasing, let fence = device.makeFence() {
                fence.label = "Ferox.AliasFence"
                aliasSync = AliasSync(fence: fence)
            }
        }

        private func assign(_ made: [TransientResource: any MTLTexture]) {
            depth = made[.depth]
            hdr = made[.hdr]
            normal = made[.normal]
            motion = made[.motion]
            depthMSAA = made[.depthMSAA]
            hdrMSAA = made[.hdrMSAA]
            normalMSAA = made[.normalMSAA]
            motionMSAA = made[.motionMSAA]
            ao = made[.ambientOcclusion]
            if let a = made[.ldrA], let b = made[.ldrB] { ldr = [a, b] }
            placed = made
        }

        private func descriptor(_ request: TransientHeapPlan.TransientRequest) -> MTLTextureDescriptor {
            let d = MTLTextureDescriptor()
            d.textureType = request.sampleCount > 1 ? .type2DMultisample : .type2D
            d.pixelFormat = format(request.resource)
            d.width = request.width
            d.height = request.height
            d.sampleCount = request.sampleCount
            d.mipmapLevelCount = request.sampleCount > 1 ? 1 : max(request.mipLevels, 1)
            d.usage = usage(request.resource)
            d.storageMode = .private
            return d
        }

        private func format(_ resource: TransientResource) -> MTLPixelFormat {
            switch resource {
            case .hdr, .hdrMSAA, .depthOfField, .motionBlur, .bloom: return TargetFormat.hdr
            case .depth, .depthMSAA: return TargetFormat.depth
            case .normal, .normalMSAA: return TargetFormat.normal
            case .motion, .motionMSAA: return TargetFormat.motion
            case .ambientOcclusion, .ssaoRaw: return TargetFormat.ao
            case .smaaEdges, .smaaWeights: return .rgba8Unorm
            case .ldrA, .ldrB: return TargetFormat.ldr
            }
        }

        private func usage(_ resource: TransientResource) -> MTLTextureUsage {
            switch resource {
            case .hdr, .ambientOcclusion:
                return [.renderTarget, .shaderRead, .shaderWrite]
            case .ldrA, .ldrB:
                return [.renderTarget, .shaderRead, .shaderWrite, .pixelFormatView]
            default:
                return [.renderTarget, .shaderRead]
            }
        }

        private func make(
            _ label: String, _ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage,
            samples: Int = 1, mips: Int = 1
        ) throws -> any MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.pixelFormat = format
            d.width = w
            d.height = h
            d.sampleCount = samples
            d.mipmapLevelCount = samples > 1 ? 1 : max(mips, 1)
            d.usage = usage
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.allocation(label) }
            t.label = label
            trackedBytes += t.allocatedSize
            MemoryTracker.shared.allocate("GPU.RenderTargets", bytes: t.allocatedSize)
            return t
        }
    }
#endif
