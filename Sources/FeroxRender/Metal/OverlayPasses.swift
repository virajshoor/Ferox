#if canImport(Metal)
    import FeroxAnimation
    import FeroxAssets
    import FeroxCore
    import FeroxScene
    import FeroxUI
    import Foundation
    import Metal

    /// Everything drawn after the lit 3D geometry: particles, the 2D layer (sprites, shapes,
    /// tilemaps, masks), debug lines, and — in the present pass, at output resolution — the UI.
    ///
    /// Particles, sprites and debug lines are encoded into the main HDR pass (they share its
    /// MSAA, depth and stencil attachments). The UI is drawn over the final tone-mapped image
    /// so it is never bloomed, blurred, jittered or upscaled.
    final class OverlayPasses {
        let device: any MTLDevice
        let shaders: ShaderLibrary

        // MARK: GPU particle state

        /// Per-emitter particle buffer on the GPU (ring of `capacity` particles).
        private struct GPUEmitter {
            let buffer: any MTLBuffer
            let capacity: Int
            var ringOffset = 0
            var lastSeen: UInt64
        }
        private var gpuEmitters: [Entity: GPUEmitter] = [:]
        private var trackedParticleBytes = 0
        /// Upper bound on one emitter's GPU particles (64 bytes each → 64 MB).
        static let maxGPUParticlesPerEmitter = 1 << 20

        // MARK: UI glyph atlas

        private struct GlyphTexture {
            let texture: any MTLTexture
            var revision: UInt64
        }
        private var glyphTextures: [Int: GlyphTexture] = [:]
        private var trackedGlyphBytes = 0

        init(device: any MTLDevice, shaders: ShaderLibrary) {
            self.device = device
            self.shaders = shaders
        }

        deinit {
            MemoryTracker.shared.free("GPU.Particles", bytes: trackedParticleBytes)
            MemoryTracker.shared.free("GPU.UIGlyphs", bytes: trackedGlyphBytes)
        }

        /// Releases every GPU particle buffer and glyph texture (scene unload, purge).
        func removeAll() {
            gpuEmitters.removeAll()
            glyphTextures.removeAll()
            MemoryTracker.shared.free("GPU.Particles", bytes: trackedParticleBytes)
            MemoryTracker.shared.free("GPU.UIGlyphs", bytes: trackedGlyphBytes)
            trackedParticleBytes = 0
            trackedGlyphBytes = 0
        }

        /// Number of resident GPU emitters (diagnostics and leak tests).
        var gpuEmitterCount: Int { gpuEmitters.count }

        // MARK: - Blending

        /// Configures premultiplied-alpha blending for a `SpriteBlendMode`. Vertex colours are
        /// premultiplied, and additive colours carry alpha 0, so `alpha`, `premultiplied` and
        /// `additive` all use (one, 1 − srcα).
        static func configureBlend(_ a: MTLRenderPipelineColorAttachmentDescriptor, _ mode: SpriteBlendMode) {
            a.isBlendingEnabled = mode != .opaque
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            switch mode {
            case .multiply:
                a.sourceRGBBlendFactor = .destinationColor
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .zero
                a.destinationAlphaBlendFactor = .one
            case .alpha, .premultiplied, .additive, .opaque:
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        }

        private func depthStencilState(compare: MTLCompareFunction, stencil: SpriteStencil = .none)
            -> (any MTLDepthStencilState)?
        {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = false
            switch stencil {
            case .none:
                break
            case .write:
                let s = MTLStencilDescriptor()
                s.stencilCompareFunction = .always
                s.depthStencilPassOperation = .replace
                d.frontFaceStencil = s
                d.backFaceStencil = s
            case .test:
                let s = MTLStencilDescriptor()
                s.stencilCompareFunction = .equal
                s.readMask = 0xFF
                s.writeMask = 0
                d.frontFaceStencil = s
                d.backFaceStencil = s
            }
            return device.makeDepthStencilState(descriptor: d)
        }

        private var depthStates: [String: any MTLDepthStencilState] = [:]
        private func cachedDepthState(compare: MTLCompareFunction, stencil: SpriteStencil) -> (
            any MTLDepthStencilState
        )? {
            let kind: String
            switch stencil {
            case .none: kind = "n"
            case .write: kind = "w"
            case .test: kind = "t"
            }
            let key = "\(compare.rawValue)\(kind)"
            if let s = depthStates[key] { return s }
            let s = depthStencilState(compare: compare, stencil: stencil)
            depthStates[key] = s
            return s
        }

        /// Main-pass attachment formats shared by every overlay pipeline drawn into HDR.
        private static func configureMainPass(_ d: MTLRenderPipelineDescriptor, samples: Int) {
            d.colorAttachments[0].pixelFormat = TargetFormat.hdr
            d.depthAttachmentPixelFormat = TargetFormat.depth
            d.stencilAttachmentPixelFormat = TargetFormat.depth
            d.rasterSampleCount = max(samples, 1)
        }

        // MARK: - Particles

        /// Uploads this frame's spawns and integrates every GPU emitter. Encode before the main
        /// pass. Buffers of emitters that disappeared are released.
        func updateGPUParticles(
            _ cb: any MTLCommandBuffer, world: World, deltaTime: Float, frameIndex: UInt64,
            allocator: FrameAllocator
        ) {
            var work: [(Entity, ParticleEmitter, [ParticleSystem.Spawn])] = []
            world.forEach(ParticleEmitter.self, ParticleState.self) { e, em, st in
                guard em.simulation == .gpu else { return }
                var spawns = ParticleSystem.takeGPUSpawns(em, &st)
                // GPU particles integrate in world space: local-space emitters are converted
                // at spawn time (they do not follow the emitter afterwards).
                if em.space == .local {
                    let m = st.emitterMatrix
                    for i in spawns.indices {
                        spawns[i].position = m.transformAffine(spawns[i].position)
                        spawns[i].velocity = m.transformDirection(spawns[i].velocity)
                    }
                }
                work.append((e, em, spawns))
            }
            for (e, s) in gpuEmitters where s.lastSeen + 1 < frameIndex || !world.isAlive(e) {
                release(e, s)
            }
            guard !work.isEmpty else { return }
            do {
                let spawnPSO = try shaders.computePipeline("spawnParticles")
                let simPSO = try shaders.computePipeline("simulateParticles")
                guard let enc = cb.makeComputeCommandEncoder() else { return }
                enc.label = "Ferox.Particles"
                defer { enc.endEncoding() }
                for (e, em, spawns) in work {
                    guard var ge = emitter(for: e, capacity: em.maxParticles, frameIndex: frameIndex) else { continue }
                    var u = ParticleSimUniforms()
                    u.gravityDrag = Vec4(em.gravity, max(em.drag, 0))
                    u.params = Vec4(max(deltaTime, 0), 0.2, 0, 0)
                    u.counts = SIMD4(
                        UInt32(ge.capacity), UInt32(min(spawns.count, ge.capacity)), UInt32(ge.ringOffset), 0)
                    if !spawns.isEmpty {
                        let color = SpriteBatcher.vertexColor(em.colorOverLifetime.evaluate(0), blend: em.blend)
                        let endScale = em.sizeOverLifetime.sample(1) ?? 1
                        let startScale = em.sizeOverLifetime.sample(0) ?? 1
                        let gpu: [GPUParticle] = spawns.prefix(ge.capacity).map { s in
                            var p = GPUParticle()
                            p.posLife = Vec4(s.position, max(s.lifetime, 1e-3))
                            p.velAge = Vec4(s.velocity, 0)
                            p.color = color
                            p.sizeRot = Vec4(s.size * startScale, s.size * endScale, s.rotation, s.angularVelocity)
                            return p
                        }
                        if let slice = allocator.upload(gpu) {
                            enc.setValue(u, index: 0, allocator: allocator)
                            enc.setSlice(slice, index: 1)
                            enc.setBuffer(ge.buffer, offset: 0, index: 3)
                            enc.dispatch1D(spawnPSO, count: gpu.count)
                            ge.ringOffset = (ge.ringOffset + gpu.count) % ge.capacity
                        }
                    }
                    enc.setValue(u, index: 0, allocator: allocator)
                    enc.setBuffer(ge.buffer, offset: 0, index: 3)
                    enc.dispatch1D(simPSO, count: ge.capacity)
                    gpuEmitters[e] = ge
                }
            } catch {
                Log.error("Render", "GPU particles unavailable: \(error)")
            }
        }

        private func emitter(for e: Entity, capacity requested: Int, frameIndex: UInt64) -> GPUEmitter? {
            let capacity = min(max(requested, 1), Self.maxGPUParticlesPerEmitter)
            if var ge = gpuEmitters[e], ge.capacity == capacity {
                ge.lastSeen = frameIndex
                return ge
            }
            if let old = gpuEmitters[e] { release(e, old) }
            // Zero-filled: age 0 ≥ lifetime 0 marks every slot dead.
            let length = capacity * MemoryLayout<GPUParticle>.stride
            guard let buffer = device.makeBuffer(length: length, options: .storageModePrivate) else {
                Log.error("Render", "GPU particle buffer allocation failed (\(capacity) particles)")
                return nil
            }
            buffer.label = "Ferox.Particles.\(e.index)"
            trackedParticleBytes += length
            MemoryTracker.shared.allocate("GPU.Particles", bytes: length)
            let ge = GPUEmitter(buffer: buffer, capacity: capacity, lastSeen: frameIndex)
            gpuEmitters[e] = ge
            return ge
        }

        private func release(_ e: Entity, _ ge: GPUEmitter) {
            gpuEmitters[e] = nil
            trackedParticleBytes -= ge.buffer.length
            MemoryTracker.shared.free("GPU.Particles", bytes: ge.buffer.length)
        }

        private func particlePipeline(_ blend: SpriteBlendMode, samples: Int) throws -> any MTLRenderPipelineState {
            try shaders.renderPipeline("particles.\(blend.rawValue).s\(samples)") { d in
                d.vertexFunction = try shaders.function("particleVertex")
                d.fragmentFunction = try shaders.function("particleFragment")
                Self.configureMainPass(d, samples: samples)
                Self.configureBlend(d.colorAttachments[0], blend)
            }
        }

        /// Draws GPU emitters and — for perspective cameras — CPU emitters as camera-facing
        /// billboards in the main pass (orthographic CPU particles are part of the 2D layer).
        /// Particles are depth-tested against the scene but do not write depth.
        func encodeParticles(
            _ enc: any MTLRenderCommandEncoder, world: World, uniforms: FrameUniforms,
            perspective: Bool, samples: Int, resources r: SceneResources
        ) {
            var draws: [(ParticleEmitter, BufferSlice?, (any MTLBuffer)?, Int, Float)] = []
            world.read(ParticleEmitter.self) { e, em in
                guard world.isActiveInHierarchy(e) else { return }
                if em.simulation == .gpu, let ge = gpuEmitters[e] {
                    draws.append((em, nil, ge.buffer, ge.capacity, 0.2))
                } else if em.simulation == .cpu, perspective, let st = world.get(ParticleState.self, e),
                    st.pool.count > 0, let slice = Self.uploadCPUParticles(em, st, allocator: r.allocator)
                {
                    // Colour and size over lifetime are baked on the CPU: no fade in the shader.
                    draws.append((em, slice, nil, st.pool.count, 0))
                }
            }
            guard !draws.isEmpty else { return }
            enc.pushDebugGroup("Ferox.Particles")
            defer { enc.popDebugGroup() }
            if let ds = cachedDepthState(compare: .greaterEqual, stencil: .none) { enc.setDepthStencilState(ds) }
            enc.setCullMode(.none)
            enc.setVertexValue(uniforms, index: BufferIndex.frame, allocator: r.allocator)
            enc.setFragmentValue(uniforms, index: BufferIndex.frame, allocator: r.allocator)
            enc.setFragmentSamplerState(r.samplers.linearClamp, index: 0)
            for (em, slice, buffer, count, fade) in draws {
                do {
                    enc.setRenderPipelineState(try particlePipeline(em.blend, samples: samples))
                } catch {
                    Log.error("Render", "Particle pipeline unavailable: \(error)")
                    return
                }
                var u = ParticleSimUniforms()
                u.params = Vec4(0, fade, 0, 0)
                u.counts = SIMD4(UInt32(count), 0, 0, 0)
                enc.setVertexValue(u, index: 0, allocator: r.allocator)
                if let slice {
                    enc.setVertexSlice(slice, index: 3)
                } else if let buffer {
                    enc.setVertexBuffer(buffer, offset: 0, index: 3)
                }
                let tex = em.texture.flatMap {
                    r.textures.texture($0, srgb: true, assets: r.assets, frame: r.frameIndex)
                }
                enc.setFragmentTexture(tex ?? r.fallback.white, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count * 6)
            }
        }

        /// Converts a CPU particle pool into `GPUParticle`s with colour and size over lifetime
        /// already applied (start size = end size, fade disabled).
        static func uploadCPUParticles(_ em: ParticleEmitter, _ st: ParticleState, allocator: FrameAllocator)
            -> BufferSlice?
        {
            let pool = st.pool
            let local = em.space == .local
            var out: [GPUParticle] = []
            out.reserveCapacity(pool.count)
            for i in 0..<pool.count {
                let t = min(max(pool.ages[i] / max(pool.lifetimes[i], 1e-4), 0), 1)
                var p = GPUParticle()
                let pos = local ? st.emitterMatrix.transformAffine(pool.positions[i]) : pool.positions[i]
                // Age 0 / lifetime 1 keeps the particle alive for the shader's dead test.
                p.posLife = Vec4(pos, 1)
                p.velAge = Vec4(.zero, 0)
                p.color = SpriteBatcher.vertexColor(em.colorOverLifetime.evaluate(t), blend: em.blend)
                let size = pool.sizes[i] * (em.sizeOverLifetime.sample(t) ?? 1)
                p.sizeRot = Vec4(size, size, pool.rotations[i], 0)
                out.append(p)
            }
            return allocator.upload(out)
        }

        // MARK: - 2D layer

        private func spritePipeline(
            _ blend: SpriteBlendMode, mask: Bool, samples: Int, colorFormat: MTLPixelFormat, depth: Bool
        ) throws -> any MTLRenderPipelineState {
            let key = "sprite.\(mask ? "mask" : blend.rawValue).s\(samples).c\(colorFormat.rawValue).d\(depth ? 1 : 0)"
            return try shaders.renderPipeline(key) { d in
                d.vertexFunction = try shaders.function("spriteVertex")
                d.fragmentFunction = try shaders.function(mask ? "spriteMaskFragment" : "spriteFragment")
                d.colorAttachments[0].pixelFormat = colorFormat
                if depth {
                    d.depthAttachmentPixelFormat = TargetFormat.depth
                    d.stencilAttachmentPixelFormat = TargetFormat.depth
                }
                d.rasterSampleCount = max(samples, 1)
                if mask {
                    d.colorAttachments[0].writeMask = []
                } else {
                    Self.configureBlend(d.colorAttachments[0], blend)
                }
            }
        }

        /// Draws the batched 2D layer in submission order. Depth is ignored (2D sorting is by
        /// layer and order); stencil masks are written and tested per `SpriteBatch.stencil`.
        func encodeSprites(
            _ enc: any MTLRenderCommandEncoder, data: SpriteFrameData, samples: Int,
            resources r: SceneResources, colorFormat: MTLPixelFormat = TargetFormat.hdr, depth: Bool = true
        ) {
            guard !data.isEmpty, !data.vertices.isEmpty, !data.indices.isEmpty,
                let vb = r.allocator.upload(data.vertices), let ib = r.allocator.upload(data.indices)
            else { return }
            let lights = data.lights.isEmpty ? nil : r.allocator.upload(data.lights)
            enc.pushDebugGroup("Ferox.Sprites")
            defer { enc.popDebugGroup() }
            enc.setCullMode(.none)
            enc.setVertexSlice(vb, index: 0)
            var uniforms = data.uniforms
            enc.setVertexValue(uniforms, index: 1, allocator: r.allocator)
            if let lights {
                enc.setFragmentSlice(lights, index: 2)
            } else {
                // The shader loops over `counts.x` = 0 lights, but the buffer must be bound.
                enc.setFragmentValue(Light2D(), index: 2, allocator: r.allocator)
            }
            for b in data.batches where b.indexCount > 0 {
                let isMask: Bool
                if case .write = b.stencil { isMask = true } else { isMask = false }
                do {
                    enc.setRenderPipelineState(
                        try spritePipeline(
                            b.blend, mask: isMask, samples: samples, colorFormat: colorFormat, depth: depth)
                    )
                } catch {
                    Log.error("Render", "Sprite pipeline unavailable: \(error)")
                    return
                }
                if depth, let ds = cachedDepthState(compare: .always, stencil: b.stencil) {
                    enc.setDepthStencilState(ds)
                }
                switch b.stencil {
                case .none: break
                case .write(let id), .test(let id): enc.setStencilReferenceValue(UInt32(id))
                }
                let tex = b.texture.flatMap {
                    r.textures.texture($0, srgb: true, assets: r.assets, frame: r.frameIndex)
                }
                let normal = b.normalMap.flatMap {
                    r.textures.texture($0, srgb: false, assets: r.assets, frame: r.frameIndex)
                }
                uniforms.counts.y = normal != nil ? 1 : 0
                enc.setFragmentValue(uniforms, index: 1, allocator: r.allocator)
                enc.setFragmentTexture(tex ?? r.fallback.white, index: 0)
                enc.setFragmentTexture(normal ?? r.fallback.white, index: 1)
                enc.setFragmentSamplerState(
                    b.filter == .nearest ? r.samplers.nearestClamp : r.samplers.linearClamp, index: 0)
                enc.drawIndexedPrimitives(
                    type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                    indexBuffer: ib.buffer,
                    indexBufferOffset: ib.offset + b.firstIndex * MemoryLayout<UInt32>.stride)
            }
        }

        // MARK: - Debug lines

        /// Draws `DebugDraw` lines in the main pass, either depth-tested or always on top.
        func encodeDebugLines(
            _ enc: any MTLRenderCommandEncoder, vertices: [LineVertex], alwaysOnTop: Bool,
            viewProjection: Mat4, samples: Int, resources r: SceneResources
        ) {
            guard vertices.count >= 2, let vb = r.allocator.upload(vertices) else { return }
            do {
                let pso = try shaders.renderPipeline("debugLines.s\(samples)") { d in
                    d.vertexFunction = try shaders.function("debugLineVertex")
                    d.fragmentFunction = try shaders.function("debugLineFragment")
                    Self.configureMainPass(d, samples: samples)
                    Self.configureBlend(d.colorAttachments[0], .premultiplied)
                }
                enc.pushDebugGroup("Ferox.DebugLines")
                defer { enc.popDebugGroup() }
                enc.setRenderPipelineState(pso)
                if let ds = cachedDepthState(compare: alwaysOnTop ? .always : .greaterEqual, stencil: .none) {
                    enc.setDepthStencilState(ds)
                }
                enc.setVertexSlice(vb, index: 0)
                var u = DebugUniforms()
                u.viewProjection = viewProjection
                enc.setVertexValue(u, index: 1, allocator: r.allocator)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count & ~1)
            } catch {
                Log.error("Render", "Debug line pipeline unavailable: \(error)")
            }
        }

        // MARK: - UI

        /// Draws UI batches into the present pass. `size` is the destination size in pixels;
        /// clip rectangles become scissor rectangles.
        func encodeUI(
            _ enc: any MTLRenderCommandEncoder, data: UIFrameData, format: MTLPixelFormat, size: SIMD2<Int>,
            glyphPages: [GlyphAtlasPageData], resources r: SceneResources
        ) {
            guard !data.batches.isEmpty, !data.vertices.isEmpty, !data.indices.isEmpty,
                let vb = r.allocator.upload(data.vertices), let ib = r.allocator.upload(data.indices)
            else { return }
            do {
                let pso = try shaders.renderPipeline("ui.\(format.rawValue)") { d in
                    d.vertexFunction = try shaders.function("uiVertex")
                    d.fragmentFunction = try shaders.function("uiFragment")
                    d.colorAttachments[0].pixelFormat = format
                    Self.configureBlend(d.colorAttachments[0], .premultiplied)
                }
                enc.pushDebugGroup("Ferox.UI")
                defer {
                    enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: max(size.x, 1), height: max(size.y, 1)))
                    enc.popDebugGroup()
                }
                enc.setRenderPipelineState(pso)
                enc.setCullMode(.none)
                enc.setVertexSlice(vb, index: 0)
                enc.setVertexValue(data.uniforms, index: 1, allocator: r.allocator)
                enc.setFragmentSamplerState(r.samplers.linearClamp, index: 0)
                let scale = data.uniforms.viewport.z
                for b in data.batches where b.indexCount > 0 {
                    guard let s = UIBatcher.scissor(b.clip, scale: scale, drawable: size) else { continue }
                    enc.setScissorRect(MTLScissorRect(x: s.x, y: s.y, width: s.width, height: s.height))
                    let tex: (any MTLTexture)?
                    switch b.texture {
                    case .none: tex = nil
                    case .image(let id): tex = r.textures.texture(id, srgb: true, assets: r.assets, frame: r.frameIndex)
                    case .glyphAtlas(let page): tex = glyphTexture(page, pages: glyphPages)
                    }
                    enc.setFragmentTexture(tex ?? r.fallback.white, index: 0)
                    enc.drawIndexedPrimitives(
                        type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                        indexBuffer: ib.buffer,
                        indexBufferOffset: ib.offset + b.firstIndex * MemoryLayout<UInt32>.stride)
                }
            } catch {
                Log.error("Render", "UI pipeline unavailable: \(error)")
            }
        }

        /// The R8 texture of glyph atlas page `index`, re-uploaded when its revision changed.
        private func glyphTexture(_ index: Int, pages: [GlyphAtlasPageData]) -> (any MTLTexture)? {
            guard pages.indices.contains(index) else { return nil }
            let page = pages[index]
            guard page.width > 0, page.height > 0, page.pixels.count >= page.width * page.height else { return nil }
            if let g = glyphTextures[index], g.revision == page.revision,
                g.texture.width == page.width, g.texture.height == page.height
            {
                return g.texture
            }
            let texture: any MTLTexture
            if let g = glyphTextures[index], g.texture.width == page.width, g.texture.height == page.height {
                texture = g.texture
            } else {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r8Unorm, width: page.width,
                    height: page.height, mipmapped: false)
                d.usage = .shaderRead
                d.storageMode = .shared
                guard let t = device.makeTexture(descriptor: d) else { return nil }
                t.label = "Ferox.GlyphAtlas\(index)"
                if let old = glyphTextures[index] {
                    trackedGlyphBytes -= old.texture.allocatedSize
                    MemoryTracker.shared.free("GPU.UIGlyphs", bytes: old.texture.allocatedSize)
                }
                trackedGlyphBytes += t.allocatedSize
                MemoryTracker.shared.allocate("GPU.UIGlyphs", bytes: t.allocatedSize)
                texture = t
            }
            // Shared storage: the CPU write is ordered before this frame's GPU read. Pages only
            // grow (glyphs are added, never moved), so a frame in flight that still samples the
            // texture sees either the old or the new coverage of untouched glyphs — identical.
            page.pixels.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, page.width, page.height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: page.width)
            }
            glyphTextures[index] = GlyphTexture(texture: texture, revision: page.revision)
            return texture
        }
    }

    /// A platform-neutral snapshot of one glyph atlas page (`GlyphAtlasPage` exists only
    /// where Core Text does), handed to the UI pass. `pixels` is row-major 8-bit coverage,
    /// `width × height` bytes; bump `revision` whenever the pixels change.
    public struct GlyphAtlasPageData: Sendable {
        public var width: Int
        public var height: Int
        public var pixels: [UInt8]
        public var revision: UInt64
        public init(width: Int, height: Int, pixels: [UInt8], revision: UInt64) {
            self.width = width
            self.height = height
            self.pixels = pixels
            self.revision = revision
        }
    }
#endif
