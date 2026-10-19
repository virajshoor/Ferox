#if canImport(Metal)
    import FeroxCore
    import Foundation
    import Metal
    #if canImport(MetalFX)
        import MetalFX
    #endif

    /// Inputs of the post-processing chain for one view and frame.
    struct PostInputs {
        var uniforms: FrameUniforms
        var post: PostUniforms
        var graphics: ResolvedGraphics
        /// Ambient occlusion to visualise in `RenderDebugView.ambientOcclusion` (SSAO, ray
        /// traced, or the white fallback when neither runs).
        var ambientOcclusion: any MTLTexture
        var debugView: RenderDebugView
        /// When set, the HDR chain is skipped and this texture is presented as-is.
        var directLDR: (any MTLTexture)?
    }

    /// The HDR → LDR chain: SSAO, temporal anti-aliasing / upscaling, depth of field, motion
    /// blur, auto exposure, bloom, tone mapping, FXAA / SMAA, spatial upscaling, sharpening,
    /// debug views and presentation.
    ///
    /// Order (each stage is skipped when disabled):
    ///
    /// 1. `encodeSSAO` — after the prepass, before the main pass (the forward shader reads it).
    /// 2. Temporal: MetalFX temporal scaler, or Ferox TAA / temporal upscale into the history
    ///    ping-pong. From here on the working resolution may be the output resolution.
    /// 3. Depth of field, then motion blur (HDR, working resolution).
    /// 4. Luminance histogram + exposure adaptation (persistent 1-float buffer on the GPU,
    ///    never read back, so auto exposure costs no CPU/GPU synchronisation).
    /// 5. Bloom: 13-tap downsample chain and tent upsample with additive blending, in the
    ///    mips of one pooled half-resolution texture.
    /// 6. Tone mapping + grading into an sRGB-encoded `rgba8Unorm` target.
    /// 7. FXAA or SMAA on the LDR image.
    /// 8. Spatial upscale (MetalFX or Ferox) when the working resolution is below the output.
    /// 9. Contrast-adaptive sharpening after temporal or upscaling passes.
    /// 10. Optional debug view, replacing the final image.
    ///
    /// `encodePresent` then copies the result into the drawable (or an offscreen texture)
    /// through an sRGB view and lets the caller draw the UI on top in the same pass.
    ///
    /// Intermediate textures come from the `TexturePool`; the only persistent allocations
    /// are the 1-float exposure buffer, the 128-bin histogram, MetalFX scalers (cached per
    /// size) and a small cache of sRGB views of the LDR targets.
    final class PostProcessor {
        let device: any MTLDevice
        let shaders: ShaderLibrary
        let pool: TexturePool

        /// Adapted exposure multiplier written by `adaptExposure` (0 = not yet adapted).
        let exposureBuffer: any MTLBuffer
        /// 128 luminance bins, cleared by `adaptExposure` after each use.
        let histogramBuffer: any MTLBuffer

        /// Set when a MetalFX scaler cannot be created for the current formats, so the
        /// renderer stays on the Ferox implementation instead of retrying every frame.
        private(set) var metalFXTemporalFailed = false
        /// Hardware probe from init: whether `makeTemporalScaler` accepted `depth32Float_stencil8`.
        private(set) var metalFXProbe = MetalFXProbeResult.notAttempted(reason: "Not probed yet")
        private(set) var metalFXSpatialFailed = false

        #if canImport(MetalFX)
            private struct ScalerKey: Equatable {
                var inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int
            }
            private var temporalScaler: (any MTLFXTemporalScaler)?
            private var temporalKey: ScalerKey?
            private var spatialScaler: (any MTLFXSpatialScaler)?
            private var spatialKey: ScalerKey?
        #endif

        /// `rgba8Unorm_srgb` views of the LDR targets, keyed by the base texture.
        private var srgbViews: [(base: ObjectIdentifier, view: any MTLTexture)] = []

        static let histogramBins = 128

        init(device: any MTLDevice, shaders: ShaderLibrary, pool: TexturePool) throws {
            self.device = device
            self.shaders = shaders
            self.pool = pool
            // Zero-initialised so the first adaptation snaps straight to its target.
            var zero: Float = 0
            guard
                let e = device.makeBuffer(bytes: &zero, length: MemoryLayout<Float>.stride, options: .storageModeShared)
            else { throw RenderError.allocation("exposure buffer") }
            e.label = "Ferox.Exposure"
            let bins = [UInt32](repeating: 0, count: Self.histogramBins)
            guard
                let h = bins.withUnsafeBytes({
                    device.makeBuffer(
                        bytes: $0.baseAddress!, length: $0.count,
                        options: .storageModePrivate)
                })
            else { throw RenderError.allocation("luminance histogram") }
            h.label = "Ferox.LuminanceHistogram"
            exposureBuffer = e
            histogramBuffer = h
            MemoryTracker.shared.allocate("GPU.Post", bytes: e.length + h.length)
        }

        deinit { MemoryTracker.shared.free("GPU.Post", bytes: exposureBuffer.length + histogramBuffer.length) }

        /// Releases cached scalers and views (resize, memory warning, purge).
        func releaseCaches() {
            #if canImport(MetalFX)
                temporalScaler = nil
                temporalKey = nil
                spatialScaler = nil
                spatialKey = nil
            #endif
            srgbViews.removeAll()
        }

        /// Restarts exposure adaptation (scene change): the next adaptation snaps to its target.
        func resetExposure() {
            exposureBuffer.contents().storeBytes(of: Float(0), as: Float.self)
        }

        // MARK: - Pipelines

        private func pipeline(_ fragment: String, format: MTLPixelFormat, additive: Bool = false) throws
            -> any MTLRenderPipelineState
        {
            try shaders.renderPipeline("post.\(fragment).\(format.rawValue)\(additive ? ".add" : "")") { d in
                // Every module defines its own `fullscreenVertex`; take the one from Post.
                d.vertexFunction = try shaders.function("fullscreenVertex", module: "Post")
                d.fragmentFunction = try shaders.function(fragment, module: "Post")
                d.colorAttachments[0].pixelFormat = format
                if additive {
                    let a = d.colorAttachments[0]!
                    a.isBlendingEnabled = true
                    a.rgbBlendOperation = .add
                    a.alphaBlendOperation = .add
                    a.sourceRGBBlendFactor = .one
                    a.destinationRGBBlendFactor = .one
                    a.sourceAlphaBlendFactor = .one
                    a.destinationAlphaBlendFactor = .one
                }
            }
        }

        /// Encodes one full-screen triangle into `target`. `bind` sets the pass's textures and
        /// buffers; `PostUniforms` and `FrameUniforms` are bound by the caller through it.
        private func fullscreen(
            _ cb: any MTLCommandBuffer, _ label: String, target: any MTLTexture,
            fragment: String, additive: Bool = false,
            bind: (any MTLRenderCommandEncoder) -> Void
        ) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            // Additive passes accumulate onto the existing contents; others cover every pixel.
            pass.colorAttachments[0].loadAction = additive ? .load : .dontCare
            pass.colorAttachments[0].storeAction = .store
            do {
                let pso = try pipeline(fragment, format: target.pixelFormat, additive: additive)
                guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
                enc.label = label
                enc.setRenderPipelineState(pso)
                bind(enc)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            } catch {
                Log.error("Render", "Post pass \(label) unavailable: \(error)")
            }
        }

        /// `post` with the per-pass size fields filled in.
        private static func sized(_ post: PostUniforms, src: (Int, Int), dst: (Int, Int), mode: Float? = nil)
            -> PostUniforms
        {
            var p = post
            let sw = Float(max(src.0, 1))
            let sh = Float(max(src.1, 1))
            let dw = Float(max(dst.0, 1))
            let dh = Float(max(dst.1, 1))
            p.sizes = Vec4(sw, sh, dw, dh)
            p.texel = Vec4(1 / sw, 1 / sh, 1 / dw, 1 / dh)
            if let mode { p.misc.w = mode }
            return p
        }

        private func transient(
            _ w: Int, _ h: Int, _ format: MTLPixelFormat, _ label: String,
            usage: MTLTextureUsage = [.renderTarget, .shaderRead], mips: Int = 1
        ) -> (any MTLTexture)? {
            pool.texture(TextureKey(width: w, height: h, format: format, usage: usage, mipLevels: mips), label: label)
        }

        // MARK: - SSAO

        /// Screen-space ambient occlusion into `targets.ao`: a normal-oriented hemisphere pass
        /// followed by a depth-aware blur. Encode after the prepass and before the main pass.
        func encodeSSAO(
            _ cb: any MTLCommandBuffer, targets: RenderTargets, uniforms: FrameUniforms,
            post: PostUniforms, allocator: FrameAllocator
        ) {
            guard let c = targets.config, let depth = targets.depth, let normal = targets.normal,
                let ao = targets.ao
            else { return }
            let size = (c.renderWidth, c.renderHeight)
            guard let raw = transient(size.0, size.1, TargetFormat.ao, "Ferox.SSAORaw") else { return }
            let p = Self.sized(post, src: size, dst: size)
            cb.pushDebugGroup("Ferox.SSAO")
            defer { cb.popDebugGroup() }
            fullscreen(cb, "Ferox.SSAO", target: raw, fragment: "ssaoFragment") { enc in
                enc.setFragmentValue(p, index: 0, allocator: allocator)
                enc.setFragmentValue(uniforms, index: BufferIndex.frame, allocator: allocator)
                enc.setFragmentTexture(depth, index: 0)
                enc.setFragmentTexture(normal, index: 1)
            }
            fullscreen(cb, "Ferox.SSAOBlur", target: ao, fragment: "ssaoBlurFragment") { enc in
                enc.setFragmentValue(p, index: 0, allocator: allocator)
                enc.setFragmentValue(uniforms, index: BufferIndex.frame, allocator: allocator)
                enc.setFragmentTexture(raw, index: 0)
                enc.setFragmentTexture(depth, index: 1)
            }
        }

        // MARK: - Main chain

        /// Runs stages 2–10 on `targets.hdr` and returns the final, sRGB-encoded `rgba8Unorm`
        /// image at output resolution (always one of `targets.ldr`), or nil when the targets
        /// are not allocated.
        func encode(
            _ cb: any MTLCommandBuffer, targets: RenderTargets, inputs: PostInputs, fallback: FallbackTextures,
            allocator: FrameAllocator
        ) -> (any MTLTexture)? {
            if let direct = inputs.directLDR { return direct }
            guard let c = targets.config, let hdr = targets.hdr, let depth = targets.depth,
                targets.ldr.count == 2
            else { return nil }
            let g = inputs.graphics
            let s = g.settings.post
            let frame = inputs.uniforms
            let render = (c.renderWidth, c.renderHeight)
            let output = (c.outputWidth, c.outputHeight)
            var working = render
            var color: any MTLTexture = hdr
            cb.pushDebugGroup("Ferox.Post")
            defer { cb.popDebugGroup() }

            // 2. Temporal anti-aliasing / upscaling.
            var temporalDone = false
            if g.upscaler == .metalFXTemporal, !metalFXTemporalFailed,
                let out = encodeMetalFXTemporal(
                    cb, targets: targets, color: hdr, render: render, output: output,
                    jitter: Vec2(frame.jitter.x, frame.jitter.y))
            {
                color = out
                working = output
                temporalDone = true
                targets.historyValid = true
            }
            if !temporalDone, g.antiAliasing == .taa || g.upscaler.isTemporal, let motion = targets.motion {
                targets.swapHistory()
                if let current = targets.currentHistory, let previous = targets.previousHistory {
                    var p = Self.sized(inputs.post, src: render, dst: output)
                    p.taa.w = targets.historyValid ? 0 : 1
                    fullscreen(cb, "Ferox.TAA", target: current, fragment: "taaResolveFragment") { enc in
                        enc.setFragmentValue(p, index: 0, allocator: allocator)
                        enc.setFragmentValue(frame, index: BufferIndex.frame, allocator: allocator)
                        enc.setFragmentTexture(hdr, index: 0)
                        enc.setFragmentTexture(previous, index: 1)
                        enc.setFragmentTexture(motion, index: 2)
                        enc.setFragmentTexture(depth, index: 3)
                    }
                    targets.historyValid = true
                    color = current
                    working = output
                }
            }

            // 3. Depth of field and motion blur.
            if s.depthOfField.enabled, let out = transient(working.0, working.1, TargetFormat.hdr, "Ferox.DOF") {
                let p = Self.sized(inputs.post, src: working, dst: working)
                let src = color
                fullscreen(cb, "Ferox.DOF", target: out, fragment: "dofFragment") { enc in
                    enc.setFragmentValue(p, index: 0, allocator: allocator)
                    enc.setFragmentValue(frame, index: BufferIndex.frame, allocator: allocator)
                    enc.setFragmentTexture(src, index: 0)
                    enc.setFragmentTexture(depth, index: 1)
                }
                color = out
            }
            if s.motionBlur.enabled, let motion = targets.motion,
                let out = transient(working.0, working.1, TargetFormat.hdr, "Ferox.MotionBlur")
            {
                let p = Self.sized(inputs.post, src: working, dst: working)
                let src = color
                fullscreen(cb, "Ferox.MotionBlur", target: out, fragment: "motionBlurFragment") { enc in
                    enc.setFragmentValue(p, index: 0, allocator: allocator)
                    enc.setFragmentValue(frame, index: BufferIndex.frame, allocator: allocator)
                    enc.setFragmentTexture(src, index: 0)
                    enc.setFragmentTexture(motion, index: 1)
                    enc.setFragmentTexture(depth, index: 2)
                }
                color = out
            }

            // 4. Auto exposure (GPU only; the tone mapper reads the buffer directly).
            if s.autoExposure { encodeAutoExposure(cb, color: color, post: inputs.post, allocator: allocator) }

            // 5. Bloom.
            var bloom: any MTLTexture = fallback.clear
            if inputs.post.bloom.z > 0,
                let b = encodeBloom(
                    cb, color: color, size: working, post: inputs.post,
                    allocator: allocator)
            {
                bloom = b
            }

            // 6. Tone mapping. Straight into an LDR target when no spatial upscale follows.
            let needsSpatial = working != output
            // Starts at 1 so the first output-size request returns `ldr[0]`.
            var ldrIndex = 1
            func nextLDR(_ size: (Int, Int), _ label: String) -> (any MTLTexture)? {
                if size == output {
                    ldrIndex ^= 1
                    return targets.ldr[ldrIndex]
                }
                return transient(size.0, size.1, TargetFormat.ldr, label)
            }
            guard var ldr = nextLDR(working, "Ferox.ToneMapped") else { return nil }
            do {
                let p = Self.sized(inputs.post, src: working, dst: working)
                let src = color
                let bloomTex = bloom
                fullscreen(cb, "Ferox.ToneMap", target: ldr, fragment: "tonemapFragment") { enc in
                    enc.setFragmentValue(p, index: 0, allocator: allocator)
                    enc.setFragmentTexture(src, index: 0)
                    enc.setFragmentTexture(bloomTex, index: 1)
                    enc.setFragmentBuffer(exposureBuffer, offset: 0, index: 2)
                }
            }

            // 7. Post-tonemap anti-aliasing (on sRGB-encoded values, as FXAA/SMAA expect).
            switch g.antiAliasing {
            case .fxaa:
                if let out = nextLDR(working, "Ferox.FXAA") {
                    let p = Self.sized(inputs.post, src: working, dst: working)
                    let src = ldr
                    fullscreen(cb, "Ferox.FXAA", target: out, fragment: "fxaaFragment") { enc in
                        enc.setFragmentValue(p, index: 0, allocator: allocator)
                        enc.setFragmentTexture(src, index: 0)
                    }
                    ldr = out
                }
            case .smaa:
                if let out = encodeSMAA(
                    cb, source: ldr, size: working, post: inputs.post, allocator: allocator,
                    destination: nextLDR(working, "Ferox.SMAA"))
                {
                    ldr = out
                }
            case .none, .msaa, .taa:
                break
            }

            // 8. Spatial upscale to output resolution.
            if needsSpatial {
                let dst = targets.ldr[ldrIndex ^ 1]
                ldrIndex ^= 1
                var done = false
                if g.upscaler == .metalFXSpatial, !metalFXSpatialFailed {
                    done = encodeMetalFXSpatial(cb, source: ldr, destination: dst, input: working, output: output)
                }
                if !done {
                    let p = Self.sized(inputs.post, src: working, dst: output)
                    let src = ldr
                    fullscreen(cb, "Ferox.SpatialUpscale", target: dst, fragment: "spatialUpscaleFragment") { enc in
                        enc.setFragmentValue(p, index: 0, allocator: allocator)
                        enc.setFragmentTexture(src, index: 0)
                    }
                }
                ldr = dst
                working = output
            }

            // 9. Sharpening recovers detail softened by temporal accumulation and upscaling.
            let sharpen = inputs.post.sharpen.x
            if sharpen > 0, g.jitter || g.upscaler != .none || needsSpatial, let out = nextLDR(output, "Ferox.Sharpen")
            {
                let p = Self.sized(inputs.post, src: output, dst: output)
                let src = ldr
                fullscreen(cb, "Ferox.Sharpen", target: out, fragment: "sharpenFragment") { enc in
                    enc.setFragmentValue(p, index: 0, allocator: allocator)
                    enc.setFragmentTexture(src, index: 0)
                }
                ldr = out
            }

            // 10. Debug view replaces the final image.
            if inputs.debugView != .none, let out = nextLDR(output, "Ferox.DebugView") {
                let source: any MTLTexture
                switch inputs.debugView {
                case .normals: source = targets.normal ?? hdr
                case .motion: source = targets.motion ?? fallback.clear
                case .ambientOcclusion: source = inputs.ambientOcclusion
                case .none, .hdrColor, .depth: source = color
                }
                let p = Self.sized(inputs.post, src: output, dst: output, mode: Float(inputs.debugView.rawValue))
                fullscreen(cb, "Ferox.DebugView", target: out, fragment: "debugViewFragment") { enc in
                    enc.setFragmentValue(p, index: 0, allocator: allocator)
                    enc.setFragmentValue(frame, index: BufferIndex.frame, allocator: allocator)
                    enc.setFragmentTexture(source, index: 0)
                    enc.setFragmentTexture(depth, index: 1)
                }
                ldr = out
            }
            return ldr
        }

        // MARK: - Stages

        private func encodeAutoExposure(
            _ cb: any MTLCommandBuffer, color: any MTLTexture, post: PostUniforms,
            allocator: FrameAllocator
        ) {
            do {
                let histogram = try shaders.computePipeline("luminanceHistogram")
                let adapt = try shaders.computePipeline("adaptExposure")
                // Both kernels initialise / reduce one bin per thread: they need ≥ 128 threads.
                let bins = Self.histogramBins
                guard histogram.maxTotalThreadsPerThreadgroup >= bins, adapt.maxTotalThreadsPerThreadgroup >= bins,
                    let enc = cb.makeComputeCommandEncoder()
                else { return }
                enc.label = "Ferox.AutoExposure"
                defer { enc.endEncoding() }
                let group =
                    histogram.maxTotalThreadsPerThreadgroup >= 256
                    ? MTLSize(width: 16, height: 16, depth: 1) : MTLSize(width: 16, height: 8, depth: 1)
                enc.setComputePipelineState(histogram)
                enc.setTexture(color, index: 0)
                enc.setBuffer(histogramBuffer, offset: 0, index: 1)
                enc.dispatchThreadgroups(
                    MTLSize(
                        width: RenderMath.groups(color.width, group.width),
                        height: RenderMath.groups(color.height, group.height), depth: 1),
                    threadsPerThreadgroup: group)
                enc.setComputePipelineState(adapt)
                enc.setValue(post, index: 0, allocator: allocator)
                enc.setBuffer(histogramBuffer, offset: 0, index: 1)
                enc.setBuffer(exposureBuffer, offset: 0, index: 2)
                enc.dispatchThreadgroups(
                    MTLSize(width: 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: bins, height: 1, depth: 1))
            } catch {
                Log.error("Render", "Auto exposure unavailable: \(error)")
            }
        }

        /// Returns the bloom texture (mip 0 view, half working resolution) or nil.
        private func encodeBloom(
            _ cb: any MTLCommandBuffer, color: any MTLTexture, size: (Int, Int), post: PostUniforms,
            allocator: FrameAllocator
        ) -> (any MTLTexture)? {
            let w = max(size.0 / 2, 1)
            let h = max(size.1 / 2, 1)
            let mips = PostUniformsBuilder.bloomMipCount(width: size.0, height: size.1)
            guard let chain = transient(w, h, TargetFormat.hdr, "Ferox.Bloom", mips: mips) else { return nil }
            let views: [any MTLTexture] = (0..<mips).compactMap { level in
                chain.makeTextureView(
                    pixelFormat: TargetFormat.hdr, textureType: .type2D, levels: level..<(level + 1),
                    slices: 0..<1)
            }
            guard views.count == mips else { return nil }
            func mipSize(_ level: Int) -> (Int, Int) { (max(w >> level, 1), max(h >> level, 1)) }
            cb.pushDebugGroup("Ferox.Bloom")
            defer { cb.popDebugGroup() }
            // Downsample: mip i reads the full-resolution colour (i = 0, thresholded) or mip i − 1.
            for level in 0..<mips {
                let src = level == 0 ? color : views[level - 1]
                let srcSize = level == 0 ? size : mipSize(level - 1)
                let p = Self.sized(post, src: srcSize, dst: mipSize(level), mode: level == 0 ? 0 : 1)
                fullscreen(cb, "Ferox.BloomDown\(level)", target: views[level], fragment: "bloomDownsampleFragment") {
                    enc in
                    enc.setFragmentValue(p, index: 0, allocator: allocator)
                    enc.setFragmentTexture(src, index: 0)
                }
            }
            // Upsample: accumulate each smaller mip into the next larger one.
            for level in stride(from: mips - 1, to: 0, by: -1) {
                let p = Self.sized(post, src: mipSize(level), dst: mipSize(level - 1))
                let src = views[level]
                fullscreen(
                    cb, "Ferox.BloomUp\(level)", target: views[level - 1], fragment: "bloomUpsampleFragment",
                    additive: true
                ) { enc in
                    enc.setFragmentValue(p, index: 0, allocator: allocator)
                    enc.setFragmentTexture(src, index: 0)
                }
            }
            return views[0]
        }

        private func encodeSMAA(
            _ cb: any MTLCommandBuffer, source: any MTLTexture, size: (Int, Int), post: PostUniforms,
            allocator: FrameAllocator, destination: (any MTLTexture)?
        ) -> (any MTLTexture)? {
            guard let destination,
                let edges = transient(size.0, size.1, .rgba8Unorm, "Ferox.SMAAEdges"),
                let weights = transient(size.0, size.1, .rgba8Unorm, "Ferox.SMAAWeights")
            else { return nil }
            let p = Self.sized(post, src: size, dst: size)
            cb.pushDebugGroup("Ferox.SMAA")
            defer { cb.popDebugGroup() }
            fullscreen(cb, "Ferox.SMAAEdges", target: edges, fragment: "smaaEdgeFragment") { enc in
                enc.setFragmentValue(p, index: 0, allocator: allocator)
                enc.setFragmentTexture(source, index: 0)
            }
            fullscreen(cb, "Ferox.SMAAWeights", target: weights, fragment: "smaaWeightsFragment") { enc in
                enc.setFragmentValue(p, index: 0, allocator: allocator)
                enc.setFragmentTexture(edges, index: 0)
            }
            fullscreen(cb, "Ferox.SMAABlend", target: destination, fragment: "smaaBlendFragment") { enc in
                enc.setFragmentValue(p, index: 0, allocator: allocator)
                enc.setFragmentTexture(source, index: 0)
                enc.setFragmentTexture(weights, index: 1)
            }
            return destination
        }

        // MARK: - MetalFX

        /// Asks MetalFX for a temporal scaler using the depth format the prepass actually writes.
        /// A nil scaler is recorded; the frame then uses Ferox's own temporal resolve.
        func probeMetalFX() {
            #if canImport(MetalFX)
                let mapping = MetalFXTemporalMapping.make(
                    renderWidth: 16, renderHeight: 16, jitterNDC: Vec2(0.25, -0.5))
                guard MTLFXTemporalScalerDescriptor.supportsDevice(device) else {
                    metalFXProbe = MetalFXProbeResult(
                        attempted: true, scalerCreated: false, depthFormatAccepted: false,
                        depthFormat: "depth32Float_stencil8",
                        unavailableReason: "MetalFX temporal is not supported on this device", mapping: mapping)
                    return
                }
                let d = MTLFXTemporalScalerDescriptor()
                d.colorTextureFormat = TargetFormat.hdr
                d.depthTextureFormat = TargetFormat.depth
                d.motionTextureFormat = TargetFormat.motion
                d.outputTextureFormat = TargetFormat.hdr
                d.inputWidth = 16
                d.inputHeight = 16
                d.outputWidth = 32
                d.outputHeight = 32
                let scaler = d.makeTemporalScaler(device: device)
                metalFXProbe = MetalFXProbeResult(
                    attempted: true, scalerCreated: scaler != nil, depthFormatAccepted: scaler != nil,
                    depthFormat: "depth32Float_stencil8",
                    unavailableReason: scaler == nil
                        ? "makeTemporalScaler returned nil for depth32Float_stencil8" : nil,
                    mapping: mapping)
            #else
                metalFXProbe = .notAttempted(reason: "MetalFX is not available in this build")
            #endif
        }

        /// Runs the MetalFX temporal scaler and returns its output-resolution HDR image, or nil
        /// (after logging once) when MetalFX is unavailable for these formats.
        ///
        /// Conventions (to validate on hardware): Ferox motion vectors are current − previous
        /// in UV units, so the scale is (−width, −height); jitter is converted from NDC to
        /// input pixels with y flipped; depth is reverse-Z.
        private func encodeMetalFXTemporal(
            _ cb: any MTLCommandBuffer, targets: RenderTargets, color: any MTLTexture,
            render: (Int, Int), output: (Int, Int), jitter: Vec2
        ) -> (any MTLTexture)? {
            #if canImport(MetalFX)
                guard let depth = targets.depth, let motion = targets.motion else { return nil }
                let key = ScalerKey(
                    inputWidth: render.0, inputHeight: render.1, outputWidth: output.0, outputHeight: output.1)
                if temporalKey != key || temporalScaler == nil {
                    let d = MTLFXTemporalScalerDescriptor()
                    d.colorTextureFormat = color.pixelFormat
                    d.depthTextureFormat = depth.pixelFormat
                    d.motionTextureFormat = motion.pixelFormat
                    d.outputTextureFormat = TargetFormat.hdr
                    d.inputWidth = render.0
                    d.inputHeight = render.1
                    d.outputWidth = output.0
                    d.outputHeight = output.1
                    guard let scaler = d.makeTemporalScaler(device: device) else {
                        metalFXTemporalFailed = true
                        Log.warning(
                            "Render", "MetalFX temporal scaler unavailable for these formats; using Ferox temporal")
                        return nil
                    }
                    guard color.usage.contains(scaler.colorTextureUsage),
                        depth.usage.contains(scaler.depthTextureUsage),
                        motion.usage.contains(scaler.motionTextureUsage)
                    else {
                        metalFXTemporalFailed = true
                        Log.warning("Render", "MetalFX temporal scaler needs other texture usage; using Ferox temporal")
                        return nil
                    }
                    temporalScaler = scaler
                    temporalKey = key
                    targets.historyValid = false
                }
                guard let scaler = temporalScaler,
                    let out = transient(
                        output.0, output.1, TargetFormat.hdr, "Ferox.MetalFXTemporal",
                        usage: scaler.outputTextureUsage.union([.renderTarget, .shaderRead]))
                else { return nil }
                scaler.colorTexture = color
                scaler.depthTexture = depth
                scaler.motionTexture = motion
                scaler.outputTexture = out
                scaler.inputContentWidth = render.0
                scaler.inputContentHeight = render.1
                let mapping = MetalFXTemporalMapping.make(
                    renderWidth: render.0, renderHeight: render.1, jitterNDC: jitter)
                scaler.jitterOffsetX = mapping.jitterOffsetX
                scaler.jitterOffsetY = mapping.jitterOffsetY
                scaler.motionVectorScaleX = mapping.motionScaleX
                scaler.motionVectorScaleY = mapping.motionScaleY
                scaler.isDepthReversed = true
                scaler.reset = !targets.historyValid
                scaler.encode(commandBuffer: cb)
                return out
            #else
                metalFXTemporalFailed = true
                return nil
            #endif
        }

        /// Runs the MetalFX spatial scaler on the sRGB-encoded LDR image. Returns false (after
        /// logging once) when it cannot run, so the caller uses the Ferox spatial upscaler.
        private func encodeMetalFXSpatial(
            _ cb: any MTLCommandBuffer, source: any MTLTexture,
            destination: any MTLTexture, input: (Int, Int), output: (Int, Int)
        ) -> Bool {
            #if canImport(MetalFX)
                let key = ScalerKey(
                    inputWidth: input.0, inputHeight: input.1, outputWidth: output.0, outputHeight: output.1)
                if spatialKey != key || spatialScaler == nil {
                    let d = MTLFXSpatialScalerDescriptor()
                    d.colorTextureFormat = source.pixelFormat
                    d.outputTextureFormat = destination.pixelFormat
                    d.inputWidth = input.0
                    d.inputHeight = input.1
                    d.outputWidth = output.0
                    d.outputHeight = output.1
                    // Values are already display-encoded (sRGB curve in a unorm texture).
                    d.colorProcessingMode = .perceptual
                    guard let scaler = d.makeSpatialScaler(device: device),
                        source.usage.contains(scaler.colorTextureUsage),
                        destination.usage.contains(scaler.outputTextureUsage)
                    else {
                        metalFXSpatialFailed = true
                        Log.warning(
                            "Render", "MetalFX spatial scaler unavailable for these formats; using Ferox spatial")
                        return false
                    }
                    spatialScaler = scaler
                    spatialKey = key
                }
                guard let scaler = spatialScaler else { return false }
                scaler.colorTexture = source
                scaler.outputTexture = destination
                scaler.inputContentWidth = input.0
                scaler.inputContentHeight = input.1
                scaler.encode(commandBuffer: cb)
                return true
            #else
                metalFXSpatialFailed = true
                return false
            #endif
        }

        // MARK: - Present

        /// An `rgba8Unorm_srgb` view of an LDR target, so sampling decodes the stored sRGB
        /// values and an sRGB destination re-encodes them exactly.
        private func srgbView(_ base: any MTLTexture, keep: [any MTLTexture]) -> (any MTLTexture)? {
            // Drop views of targets that were reallocated (a view retains its parent texture).
            let live = Set(keep.map { ObjectIdentifier($0) })
            srgbViews.removeAll { !live.contains($0.base) }
            let id = ObjectIdentifier(base)
            if let v = srgbViews.first(where: { $0.base == id }) { return v.view }
            guard let v = base.makeTextureView(pixelFormat: TargetFormat.ldrSRGBView) else { return nil }
            v.label = "\(base.label ?? "Ferox.LDR").sRGB"
            srgbViews.append((id, v))
            return v
        }

        /// Copies `source` (an LDR target) into `destination` (the drawable or an offscreen
        /// texture) and then calls `overlay` in the same render pass, so UI and other
        /// screen-space overlays are drawn at output resolution over the final image.
        func encodePresent(
            _ cb: any MTLCommandBuffer, source: any MTLTexture, targets: RenderTargets,
            destination: any MTLTexture, viewport: PixelRect? = nil,
            overlay: ((any MTLRenderCommandEncoder, MTLPixelFormat) -> Void)? = nil
        ) {
            guard let view = srgbView(source, keep: targets.ldr) else { return }
            let full = PixelRect(x: 0, y: 0, width: destination.width, height: destination.height)
            let rect = viewport ?? full
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            // A partial viewport leaves the rest of the drawable uncovered: clear it to black.
            pass.colorAttachments[0].loadAction = rect == full ? .dontCare : .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            func setViewport(_ enc: any MTLRenderCommandEncoder, _ r: PixelRect) {
                enc.setViewport(
                    MTLViewport(
                        originX: Double(r.x), originY: Double(r.y), width: Double(r.width),
                        height: Double(r.height), znear: 0, zfar: 1))
            }
            do {
                let pso = try pipeline("blitFragment", format: destination.pixelFormat)
                guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
                enc.label = "Ferox.Present"
                enc.setRenderPipelineState(pso)
                enc.setFragmentTexture(view, index: 0)
                setViewport(enc, rect)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                // The UI overlay covers the whole drawable, whatever the camera viewport.
                if rect != full { setViewport(enc, full) }
                overlay?(enc, destination.pixelFormat)
                enc.endEncoding()
            } catch {
                Log.error("Render", "Present pass unavailable: \(error)")
            }
        }
    }
#endif
