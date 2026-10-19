#if canImport(Metal)
    import FeroxAnimation
    import FeroxAssets
    import FeroxCore
    import FeroxScene
    import FeroxUI
    import Foundation
    import Metal

    // MARK: - Public types

    /// Points in the frame where game code can insert its own GPU work.
    public enum RenderHookStage: String, Sendable, CaseIterable {
        /// Before any scene pass, on the scene command buffer (compute work, uploads).
        case beforeScene
        /// Inside the main HDR pass, after opaque geometry (before the sky and transparents).
        case afterOpaque
        /// Inside the main HDR pass, after transparents, particles, sprites and debug lines.
        case afterTransparent
        /// After tone mapping and anti-aliasing, before the UI and presentation; `color` is
        /// the final LDR image (output resolution, sRGB-encoded values in `rgba8Unorm`).
        case afterPostProcess
    }

    /// What a render hook may use. Inside the main pass, pipelines must be built for
    /// `colorFormat`, `depthStencilFormat` and `sampleCount`, and use reverse-Z depth
    /// (greater-or-equal passes, 0 is the far plane).
    public struct RenderHookContext {
        public let stage: RenderHookStage
        public let commandBuffer: any MTLCommandBuffer
        /// The open main-pass encoder (`afterOpaque`, `afterTransparent`), else nil. Do not end it.
        public let encoder: (any MTLRenderCommandEncoder)?
        public let uniforms: FrameUniforms
        public let color: (any MTLTexture)?
        public let depth: (any MTLTexture)?
        public let colorFormat: MTLPixelFormat
        public let depthStencilFormat: MTLPixelFormat
        public let sampleCount: Int
        public let renderSize: SIMD2<Int>
    }

    /// Handle returned by `Renderer.addHook`, used to remove it.
    public struct RenderHookToken: Hashable, Sendable {
        let id: Int
    }

    /// Where a frame is drawn.
    public struct RenderOutput {
        /// Destination colour texture (a drawable's texture, or an offscreen target). Must
        /// have `.renderTarget` usage; its size is the output resolution.
        public var texture: any MTLTexture
        /// Presented after the frame's last command buffer when set.
        public var drawable: (any MTLDrawable)?
        /// Pixels per point of the destination (UI scaling).
        public init(texture: any MTLTexture, drawable: (any MTLDrawable)? = nil) {
            self.texture = texture
            self.drawable = drawable
        }
    }

    /// Measurements of the most recent frame. GPU time is that of the last *completed* frame
    /// (frames are pipelined), measured from command-buffer GPU start/end timestamps.
    public struct RenderFrameStatistics: Sendable, Hashable {
        public var frameIndex: UInt64 = 0
        /// CPU time spent encoding the frame (extraction included).
        public var cpuMilliseconds: Double = 0
        public var gpuMilliseconds: Double?
        public var renderWidth = 0
        public var renderHeight = 0
        public var outputWidth = 0
        public var outputHeight = 0
        /// Dynamic-resolution multiplier on top of the upscaler's render scale.
        public var dynamicScale: Float = 1
        public var visibleObjects = 0
        public var culledObjects = 0
        public var spritesDrawn = 0
        public var debugLines = 0
        public var reflectionProbeCaptures = 0
        /// Frames skipped because the GPU did not release a frame slot in time.
        public var skippedFrames = 0
    }

    // MARK: - Renderer

    /// The Metal renderer: turns a `World` into a frame.
    ///
    /// A frame runs in three command buffers, enqueued in this order so they execute in it:
    /// 1. **uploads** — mipmap generation for textures first used during this frame's encoding;
    /// 2. **scene** — environment/probe updates, shadows, culling & clustering, GPU particles,
    ///    the depth/normal/motion prepass, Hi-Z, SSAO or ray-traced effects, and the main HDR
    ///    pass (opaque, sky, transparent, particles, 2D layer, debug lines);
    /// 3. **post** — temporal AA/upscaling, DOF, motion blur, exposure, bloom, tone mapping,
    ///    FXAA/SMAA, spatial upscaling, sharpening, then presentation with the UI on top.
    ///
    /// The scene and post buffers are timed separately (`GPU.Scene`, `GPU.Post` in the
    /// profiler). At most `maxFramesInFlight` frames are encoded ahead of the GPU; per-frame
    /// buffers come from one `FrameAllocator` per slot, so the CPU never overwrites data the
    /// GPU is still reading.
    ///
    /// The renderer is not thread-safe: create and use it on one thread (normally the main
    /// thread). The camera renders into its `Camera.viewport` rectangle of the output, at that
    /// rectangle's size and aspect; the rest of the output is cleared to black and the UI
    /// still covers the whole output. Limitations: one camera per frame (the highest-priority
    /// enabled camera, so split-screen needs one renderer per view), `Camera.renderTarget` is
    /// not yet honoured, and the sky is drawn only for perspective cameras (orthographic
    /// cameras show `clearColor`).
    /// See Docs/08-Rendering-3D.md and Docs/03-Architecture.md.
    public final class Renderer {
        public let renderDevice: RenderDevice
        public var device: any MTLDevice { renderDevice.device }
        public var capabilities: DeviceCapabilities { renderDevice.capabilities }
        public let shaders: ShaderLibrary
        public let assets: AssetManager
        /// Skeletal animation data used for skinned meshes (set by the engine).
        public var animations: AnimationLibrary?
        public let maxFramesInFlight: Int

        /// Requested settings. Assigning re-resolves them against the device; inspect
        /// `resolved.fallbacks` to see what changed and why.
        public var settings: GraphicsSettings {
            didSet { if settings != oldValue { applySettings(previous: oldValue) } }
        }
        public private(set) var resolved: ResolvedGraphics
        /// Full-screen debug visualisation (replaces the final image).
        public var debugView: RenderDebugView = .none
        /// Immediate-mode debug lines, drawn and cleared every frame.
        public let debugDraw = DebugDraw()
        /// Glyph atlas pages for UI text. The default reads the pages of a
        /// `CoreTextFontProvider`; supply your own for a custom `UIFontProvider`.
        public var glyphPages: ((UIContext) -> [GlyphAtlasPageData])?
        public private(set) var statistics = RenderFrameStatistics()

        private let inFlight: DispatchSemaphore
        private let allocators: [FrameAllocator]
        private let pool: TexturePool
        private let meshes: MeshCache
        private let textures: TextureCache
        private let materials = MaterialBinder()
        private var samplers: SamplerSet
        private let fallback: FallbackTextures
        private let targets: RenderTargets
        private let passes: ScenePasses
        private let environment: EnvironmentLighting
        private let probes: ReflectionProbes
        private let rayTracing: RayTracingContext?
        private let post: PostProcessor
        private let overlays: OverlayPasses
        private let spriteBatcher = SpriteBatcher()
        private var dynamicResolution: DynamicResolutionController

        private var history: FrameUniformsBuilder.History?
        private var lastCamera: Entity?
        private var lastCameraPosition: Vec3?
        private var cutRequested = true
        private var frameIndex: UInt64 = 0
        private var hooks: [(id: Int, stage: RenderHookStage, body: (RenderHookContext) -> Void)] = []
        private var nextHookID = 0

        /// Written by command-buffer completion handlers (any thread), read on the render thread.
        private let gpuLock = NSLock()
        private var lastGPUMilliseconds: Double?
        /// Scene command buffer GPU time per frame slot, handed from the scene completion
        /// handler to the post one. Guarded by `gpuLock`.
        private var sceneGPUMilliseconds: [Double]

        private var offscreen: (any MTLTexture)?
        private var offscreenBytes = 0

        /// Camera moves longer than this in one frame are treated as cuts (teleports), which
        /// discard temporal history instead of smearing it.
        public var cutDistance: Float = 100

        /// - Parameters:
        ///   - device: The Metal device and queue; nil creates one for the system default GPU.
        ///   - settings: Requested graphics settings (resolved against the device).
        ///   - assets: Source of meshes, textures and materials.
        ///   - shaderDirectory: Directory of `.metal` sources to compile and hot-reload instead
        ///     of the bundled shaders (development only; also `FEROX_SHADER_DIR`).
        public init(
            device: RenderDevice? = nil, settings: GraphicsSettings = GraphicsSettings(), assets: AssetManager,
            shaderDirectory: URL? = nil
        ) throws {
            let rd = try device ?? RenderDevice()
            let d = rd.device
            renderDevice = rd
            self.assets = assets
            self.settings = settings
            resolved = GraphicsFeatureResolver.resolve(settings, capabilities: rd.capabilities)
            maxFramesInFlight = min(max(settings.frame.maxFramesInFlight, 1), 3)
            inFlight = DispatchSemaphore(value: maxFramesInFlight)
            allocators = (0..<maxFramesInFlight).map { FrameAllocator(device: d, label: "Ferox.Frame\($0)") }
            sceneGPUMilliseconds = Array(repeating: 0, count: maxFramesInFlight)
            shaders = try ShaderLibrary(device: d, sourceDirectory: shaderDirectory)
            pool = TexturePool(device: d)
            meshes = MeshCache(
                uploader: GPUUploader(
                    device: d, queue: rd.queue,
                    unifiedMemory: rd.capabilities.hasUnifiedMemory))
            textures = TextureCache(device: d, capabilities: rd.capabilities)
            samplers = try SamplerSet(device: d, anisotropy: resolved.settings.anisotropy)
            fallback = try FallbackTextures(device: d, queue: rd.queue)
            targets = RenderTargets(device: d)
            passes = ScenePasses(device: d, shaders: shaders, capabilities: rd.capabilities)
            environment = try EnvironmentLighting(device: d, shaders: shaders)
            probes = try ReflectionProbes(device: d, shaders: shaders)
            rayTracing =
                rd.capabilities.supportsRaytracing
                ? RayTracingContext(device: d, shaders: shaders, maxFramesInFlight: maxFramesInFlight) : nil
            post = try PostProcessor(device: d, shaders: shaders, pool: pool)
            overlays = OverlayPasses(device: d, shaders: shaders)
            dynamicResolution = DynamicResolutionController(settings: resolved.settings.dynamicResolution)
            for f in resolved.fallbacks { Log.info("Render", "Graphics fallback: \(f)") }
        }

        deinit {
            // Metal retains every resource a command buffer references, so this only keeps
            // the frame allocators' memory accounting honest until the GPU is done.
            waitUntilIdle(timeout: 2)
            MemoryTracker.shared.free("GPU.Offscreen", bytes: offscreenBytes)
        }

        // MARK: Configuration

        private func applySettings(previous: GraphicsSettings) {
            resolved = GraphicsFeatureResolver.resolve(settings, capabilities: capabilities)
            for f in resolved.fallbacks { Log.info("Render", "Graphics fallback: \(f)") }
            dynamicResolution.settings = resolved.settings.dynamicResolution
            if settings.frame.maxFramesInFlight != previous.frame.maxFramesInFlight {
                Log.warning("Render", "maxFramesInFlight changes take effect when the renderer is recreated")
            }
            if settings.anisotropy != previous.anisotropy {
                do {
                    samplers = try SamplerSet(device: device, anisotropy: resolved.settings.anisotropy)
                } catch {
                    Log.error("Render", "Sampler rebuild failed, keeping previous samplers: \(error)")
                }
            }
            invalidateHistory()
        }

        /// Discards temporal history (TAA, motion blur, ray-tracing denoisers, Hi-Z). Call on
        /// scene loads and camera cuts that the automatic detection would miss.
        public func cameraCut() { cutRequested = true }

        private func invalidateHistory() {
            history = nil
            targets.historyValid = false
            rayTracing?.resetHistory()
            passes.invalidateHiZ()
        }

        /// Registers GPU work at `stage`. Hooks run in registration order.
        @discardableResult
        public func addHook(_ stage: RenderHookStage, _ body: @escaping (RenderHookContext) -> Void) -> RenderHookToken
        {
            nextHookID += 1
            hooks.append((nextHookID, stage, body))
            return RenderHookToken(id: nextHookID)
        }

        public func removeHook(_ token: RenderHookToken) {
            hooks.removeAll { $0.id == token.id }
        }

        private func runHooks(_ stage: RenderHookStage, _ make: () -> RenderHookContext) {
            let matching = hooks.filter { $0.stage == stage }
            guard !matching.isEmpty else { return }
            let ctx = make()
            for h in matching { h.body(ctx) }
        }

        /// Releases cached GPU resources that can be recreated on demand (memory warning,
        /// level change). Resident meshes and textures are reloaded as they are drawn again.
        public func purgeCaches() {
            waitUntilIdle(timeout: 2)
            pool.purge()
            meshes.removeAll()
            textures.removeAll()
            post.releaseCaches()
            overlays.removeAll()
            spriteBatcher.removeAllCaches()
            rayTracing?.release()
            targets.release()
            probes.invalidateAll()
            invalidateHistory()
        }

        /// Blocks until every submitted frame has completed on the GPU (or `timeout` seconds
        /// pass). Returns false on timeout.
        @discardableResult
        public func waitUntilIdle(timeout: Double = 5) -> Bool {
            var acquired = 0
            for _ in 0..<maxFramesInFlight where inFlight.wait(timeout: .now() + timeout) == .success {
                acquired += 1
            }
            for _ in 0..<acquired { inFlight.signal() }
            return acquired == maxFramesInFlight
        }

        // MARK: Frame

        /// Renders `world` into `output` and, when `output.drawable` is set, presents it.
        ///
        /// - Parameters:
        ///   - time: Elapsed time in seconds (shader animation).
        ///   - deltaTime: Frame time in seconds (GPU particles, exposure adaptation, motion blur).
        ///   - ui: UI drawn on top of the final image at output resolution.
        /// - Returns: false when the frame was skipped (GPU stalled or a command buffer could
        ///   not be created).
        @discardableResult
        public func render(
            world: World, to output: RenderOutput, time: Double, deltaTime: Float,
            ui: UIContext? = nil
        ) -> Bool {
            let cpuStart = MonotonicClock.now()
            // Wait for a free frame slot. A one-second timeout turns a hung GPU into skipped
            // frames and a log message instead of a frozen application.
            guard inFlight.wait(timeout: .now() + 1) == .success else {
                statistics.skippedFrames += 1
                Log.warning("Render", "GPU did not release a frame slot within 1 s; frame skipped")
                return false
            }
            let queue = renderDevice.queue
            guard let cbUpload = queue.makeCommandBuffer(), let cbScene = queue.makeCommandBuffer(),
                let cbPost = queue.makeCommandBuffer()
            else {
                inFlight.signal()
                Log.error("Render", "Could not create command buffers; frame skipped")
                statistics.skippedFrames += 1
                return false
            }
            cbUpload.label = "Ferox.Uploads"
            cbScene.label = "Ferox.Scene"
            cbPost.label = "Ferox.Post"
            // Enqueue now so the upload buffer, encoded last, still executes first.
            cbUpload.enqueue()
            cbScene.enqueue()
            cbPost.enqueue()

            frameIndex += 1
            let slot = Int(frameIndex % UInt64(maxFramesInFlight))
            let allocator = allocators[slot]
            allocator.reset()
            materials.beginFrame()
            if shaders.reloadIfChanged() {
                Log.info("Render", "Shaders reloaded (generation \(shaders.generation))")
                environment.invalidate()
                probes.invalidateAll()
                post.releaseCaches()
            }
            let resources = SceneResources(
                assets: assets, meshes: meshes, textures: textures, materials: materials,
                samplers: samplers, fallback: fallback, allocator: allocator,
                frameIndex: frameIndex)

            Profiler.shared.scope("Render.Encode") {
                encodeFrame(
                    world: world, output: output, time: time, deltaTime: deltaTime, ui: ui, slot: slot,
                    scene: cbScene, post: cbPost, resources: resources)
            }

            // Texture first-use work found while encoding goes into the earlier buffer.
            textures.encodePendingWork(cbUpload)
            if let drawable = output.drawable { cbPost.present(drawable) }

            // GPU time for dynamic resolution and the profiler is the scene buffer's duration
            // plus the post buffer's. The scene handler always runs before the post handler
            // (same queue, committed in order), so the per-slot hand-off below is race free;
            // the lock only orders it against the CPU reading `lastGPUMilliseconds`.
            let sem = inFlight
            cbScene.addCompletedHandler { [weak self] cb in
                let ms = max((cb.gpuEndTime - cb.gpuStartTime) * 1000, 0)
                if ms > 0 { Profiler.shared.recordGPU(name: "GPU.Scene", duration: ms / 1000) }
                if let self { self.gpuLock.locked { self.sceneGPUMilliseconds[slot] = ms } }
            }
            cbPost.addCompletedHandler { [weak self] cb in
                if cb.status == .error {
                    Log.error("Render", "GPU frame failed: \(cb.error.map { "\($0)" } ?? "unknown error")")
                }
                let postMs = max((cb.gpuEndTime - cb.gpuStartTime) * 1000, 0)
                if postMs > 0 { Profiler.shared.recordGPU(name: "GPU.Post", duration: postMs / 1000) }
                if let self {
                    let total: Double = self.gpuLock.locked {
                        let t = self.sceneGPUMilliseconds[slot] + postMs
                        if t > 0 { self.lastGPUMilliseconds = t }
                        return t
                    }
                    if total > 0 { Profiler.shared.recordGPUFrame(duration: total / 1000) }
                }
                // Signal last: once the slot is free the CPU may reuse its allocator.
                sem.signal()
            }
            cbUpload.commit()
            cbScene.commit()
            cbPost.commit()

            pool.endFrame()
            if frameIndex % 120 == 0 {
                meshes.evict(frame: frameIndex)
                textures.evict(frame: frameIndex)
            }
            debugDraw.clear()
            statistics.frameIndex = frameIndex
            statistics.cpuMilliseconds = (MonotonicClock.now() - cpuStart) * 1000
            statistics.gpuMilliseconds = gpuLock.locked { lastGPUMilliseconds }
            statistics.reflectionProbeCaptures = probes.captures
            return true
        }

        private func encodeFrame(
            world: World, output: RenderOutput, time: Double, deltaTime: Float, ui: UIContext?,
            slot: Int, scene cb: any MTLCommandBuffer, post cbPost: any MTLCommandBuffer,
            resources r: SceneResources
        ) {
            let fullWidth = max(output.texture.width, 1)
            let fullHeight = max(output.texture.height, 1)
            // The main camera's viewport is the frame's output: render size, aspect and post
            // all work on that rectangle, and the present pass places it in the drawable.
            let viewportRect = RenderSceneExtractor.mainCamera(in: world)?.1.viewport ?? .unit
            let viewport = RenderMath.viewportPixels(viewportRect, outputWidth: fullWidth, outputHeight: fullHeight)
            let ow = viewport.width
            let oh = viewport.height
            statistics.outputWidth = ow
            statistics.outputHeight = oh

            // Dynamic resolution reacts to the last completed frame's GPU time.
            if resolved.settings.dynamicResolution.enabled, let gpu = gpuLock.locked({ lastGPUMilliseconds }) {
                let budget = 1000 / Double(max(resolved.settings.frame.targetFPS ?? 60, 1))
                dynamicResolution.update(gpuMilliseconds: gpu, budgetMs: budget)
            }
            let dyn = resolved.settings.dynamicResolution.enabled ? dynamicResolution.scale : 1
            let base = resolved.renderSize(forOutput: ow, oh)
            let rw = max(Int((Float(base.width) * dyn).rounded()), 8)
            let rh = max(Int((Float(base.height) * dyn).rounded()), 8)
            statistics.renderWidth = rw
            statistics.renderHeight = rh
            statistics.dynamicScale = dyn

            let cfg = RenderTargets.Config(
                renderWidth: rw, renderHeight: rh, outputWidth: ow, outputHeight: oh,
                msaaSamples: resolved.msaaSamples, temporalHistory: resolved.jitter,
                hiz: resolved.settings.gpuDrivenCulling && resolved.settings.occlusionCulling)
            do {
                if try targets.ensure(cfg) {
                    invalidateHistory()
                    post.releaseCaches()
                }
            } catch {
                Log.error("Render", "Render target allocation failed (\(rw)×\(rh)): \(error)")
                encodeClear(cbPost, output: output, ui: ui, resources: r)
                return
            }

            // --- Extraction
            var options = ExtractionOptions()
            options.frustumCull = !resolved.settings.gpuDrivenCulling
            options.lodBias = resolved.settings.lodBias
            options.shadowDistance = resolved.settings.shadows.maxDistance
            options.collectRayTracingInstances = resolved.usesRayTracing && rayTracing != nil
            let frame = Profiler.shared.scope("Render.Extract") {
                RenderSceneExtractor.extract(
                    world: world, assets: assets, animations: animations,
                    aspect: Float(ow) / Float(oh), options: options)
            }
            statistics.visibleObjects = frame.visibleObjects
            statistics.culledObjects = frame.culledObjects
            Profiler.shared.updateRenderCounters {
                $0.visibleObjects += frame.visibleObjects
                $0.culledObjects += frame.culledObjects
            }
            guard let camera = frame.camera else {
                // No camera: clear the output so stale drawable contents never show, keep the UI.
                encodeClear(cbPost, output: output, ui: ui, resources: r)
                return
            }

            // --- Temporal bookkeeping
            if cutRequested || camera.entity != lastCamera
                || (lastCameraPosition.map { ($0 - camera.position).length > cutDistance } ?? true)
            {
                invalidateHistory()
                cutRequested = false
            }
            lastCamera = camera.entity
            lastCameraPosition = camera.position

            let jitter =
                resolved.jitter
                ? RenderMath.jitter(
                    frame: frameIndex, phases: resolved.settings.antiAliasing.taaJitterPhases,
                    renderWidth: rw, renderHeight: rh)
                : Vec2.zero
            let exposure = RenderMath.exposure(ev100: camera.camera.exposureEV100)
            let uniforms = FrameUniformsBuilder.make(
                camera: camera, width: rw, height: rh, jitter: jitter,
                previous: history, environment: frame.environment,
                exposure: exposure, time: time, frameIndex: frameIndex,
                environmentMips: environment.prefilteredMipCount)
            history = FrameUniformsBuilder.History(
                viewProjection: uniforms.viewProjection,
                unjitteredViewProjection: uniforms.unjitteredViewProjection,
                jitter: jitter)

            // --- Environment and reflection probes (before the main prepare: probe capture
            // reuses the scene passes' per-frame state).
            var equirect: (any MTLTexture)?
            if case .texture(let id) = frame.environment.sky {
                equirect = textures.texture(id, srgb: false, assets: assets, frame: frameIndex)
            }
            environment.update(
                frame.environment, sun: frame.sun?.towardsLight, equirect: equirect,
                fallback: fallback.white, commandBuffer: cb, allocator: r.allocator)
            let probeData = probes.update(frame.probes, frameIndex: frameIndex)
            if let p = probes.nextCapture(frame.probes) {
                probes.capture(
                    p, world: world, animations: animations, graphics: resolved, passes: passes,
                    environment: environment, commandBuffer: cb, resources: r)
            }

            // --- Scene
            var state = passes.prepare(
                frame, uniforms: uniforms, graphics: resolved, probes: probeData,
                targets: targets, resources: r)
            runHooks(.beforeScene) {
                hookContext(.beforeScene, cb, nil, state.uniforms, targets.hdr, rw, rh, state.samples)
            }
            let shadowMap = passes.encodeShadows(
                cb, frame: frame, state: state, settings: resolved.settings.shadows,
                resources: r)
            let localShadows = passes.encodeLocalShadows(
                cb, frame: frame, state: state,
                settings: resolved.settings.shadows, resources: r)
            passes.encodeCompute(cb, frame: frame, state: state, targets: targets, resources: r)
            overlays.updateGPUParticles(
                cb, world: world, deltaTime: deltaTime, frameIndex: frameIndex,
                allocator: r.allocator)
            passes.encodePrepass(cb, frame: frame, state: state, targets: targets, resources: r)
            if cfg.hiz { passes.encodeHiZ(cb, state: state, targets: targets) }

            let postUniforms = PostUniformsBuilder.make(
                resolved.settings.post, antiAliasing: resolved.settings.antiAliasing,
                camera: camera.camera, frameIndex: frameIndex,
                deltaTime: deltaTime)
            var rt = RayTracingContext.Outputs()
            if let rayTracing, resolved.usesRayTracing, let depth = targets.depth, let normal = targets.normal,
                let motion = targets.motion
            {
                rt = rayTracing.encodeEffects(
                    cb, frame: frame, uniforms: state.uniforms, graphics: resolved, slot: slot,
                    depth: depth, normal: normal, motion: motion,
                    environment: environment.environment, resources: r)
            }
            let ssao = resolved.screenSpaceAO && rt.ambientOcclusion == nil && targets.ao != nil
            if ssao {
                post.encodeSSAO(
                    cb, targets: targets, uniforms: state.uniforms, post: postUniforms, allocator: r.allocator)
            }
            state.uniforms.effectFlags = Vec4(
                rt.shadow != nil ? 1 : 0, rt.ambientOcclusion != nil ? 1 : 0,
                rt.reflection != nil ? 1 : 0, ssao ? 1 : 0)
            let ao: any MTLTexture = rt.ambientOcclusion ?? (ssao ? targets.ao : nil) ?? fallback.white
            let lighting = LightingTextures(
                prefiltered: environment.prefiltered, brdfLUT: environment.brdfLUT,
                shadowMap: shadowMap, rtShadow: rt.shadow ?? fallback.white,
                rtReflection: rt.reflection ?? fallback.clear, ambientOcclusion: ao,
                irradiance: environment.irradiance,
                probes: probeData.isEmpty ? fallback.cubeArray : probes.array,
                localShadows: localShadows)

            if let pass = passes.mainPassDescriptor(targets: targets, clearColor: camera.camera.clearColor),
                let enc = cb.makeRenderCommandEncoder(descriptor: pass)
            {
                enc.label = "Ferox.MainPass"
                passes.encodeOpaque(enc, frame: frame, state: state, lighting: lighting, resources: r)
                runHooks(.afterOpaque) {
                    hookContext(.afterOpaque, cb, enc, state.uniforms, targets.hdr, rw, rh, state.samples)
                }
                let perspective = camera.camera.projection == .perspective
                if perspective {
                    passes.encodeSky(enc, environment: environment.environment, state: state, resources: r)
                }
                passes.encodeTransparent(enc, frame: frame, state: state, lighting: lighting, resources: r)
                overlays.encodeParticles(
                    enc, world: world, uniforms: state.uniforms, perspective: perspective,
                    samples: state.samples, resources: r)
                let sprites = Profiler.shared.scope("Render.Sprites") {
                    spriteBatcher.build(world: world, assets: assets, camera: camera, targetSize: SIMD2(rw, rh))
                }
                statistics.spritesDrawn = sprites.drawnObjects
                overlays.encodeSprites(enc, data: sprites, samples: state.samples, resources: r)
                statistics.debugLines = debugDraw.lineCount
                overlays.encodeDebugLines(
                    enc, vertices: debugDraw.vertices, alwaysOnTop: debugDraw.alwaysOnTop,
                    viewProjection: state.uniforms.viewProjection, samples: state.samples,
                    resources: r)
                runHooks(.afterTransparent) {
                    hookContext(.afterTransparent, cb, enc, state.uniforms, targets.hdr, rw, rh, state.samples)
                }
                enc.endEncoding()
            }

            // --- Post and present
            let inputs = PostInputs(
                uniforms: state.uniforms, post: postUniforms, graphics: resolved,
                ambientOcclusion: ao, debugView: debugView)
            guard
                let final = post.encode(
                    cbPost, targets: targets, inputs: inputs, fallback: fallback,
                    allocator: r.allocator)
            else {
                encodeClear(cbPost, output: output, ui: ui, resources: r)
                return
            }
            runHooks(.afterPostProcess) {
                RenderHookContext(
                    stage: .afterPostProcess, commandBuffer: cbPost, encoder: nil, uniforms: state.uniforms,
                    color: final, depth: targets.depth, colorFormat: final.pixelFormat,
                    depthStencilFormat: TargetFormat.depth, sampleCount: 1, renderSize: SIMD2(ow, oh))
            }
            let uiData = ui.map { buildUI($0) }
            let pages = ui.map { glyphPageData($0) } ?? []
            post.encodePresent(
                cbPost, source: final, targets: targets, destination: output.texture,
                viewport: viewport
            ) { enc, format in
                if let uiData {
                    self.overlays.encodeUI(
                        enc, data: uiData, format: format, size: SIMD2(fullWidth, fullHeight),
                        glyphPages: pages, resources: r)
                }
            }
        }

        private func hookContext(
            _ stage: RenderHookStage, _ cb: any MTLCommandBuffer, _ enc: (any MTLRenderCommandEncoder)?,
            _ u: FrameUniforms, _ color: (any MTLTexture)?, _ w: Int, _ h: Int,
            _ samples: Int
        ) -> RenderHookContext {
            RenderHookContext(
                stage: stage, commandBuffer: cb, encoder: enc, uniforms: u, color: color,
                depth: targets.depth, colorFormat: TargetFormat.hdr, depthStencilFormat: TargetFormat.depth,
                sampleCount: samples, renderSize: SIMD2(w, h))
        }

        /// Clears the output to black and draws the UI (no camera, or a failed frame).
        private func encodeClear(
            _ cb: any MTLCommandBuffer, output: RenderOutput, ui: UIContext?, resources r: SceneResources
        ) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.label = "Ferox.Clear"
            if let ui {
                overlays.encodeUI(
                    enc, data: buildUI(ui), format: output.texture.pixelFormat,
                    size: SIMD2(output.texture.width, output.texture.height),
                    glyphPages: glyphPageData(ui), resources: r)
            }
            enc.endEncoding()
        }

        private func buildUI(_ ui: UIContext) -> UIFrameData {
            Profiler.shared.scope("Render.UI") {
                UIBatcher.build(ui.draw(), viewportSize: ui.size, scale: ui.scaleFactor)
            }
        }

        private func glyphPageData(_ ui: UIContext) -> [GlyphAtlasPageData] {
            if let glyphPages { return glyphPages(ui) }
            #if canImport(CoreText)
                // Arrays are copy-on-write: this shares the provider's pixel storage.
                if let ct = ui.fonts as? CoreTextFontProvider {
                    return ct.pages.map {
                        GlyphAtlasPageData(width: $0.width, height: $0.height, pixels: $0.pixels, revision: $0.revision)
                    }
                }
            #endif
            return []
        }

        // MARK: Offscreen rendering

        /// Renders one frame into an internal `bgra8Unorm_srgb` texture of the given size and
        /// waits for the GPU. Used by headless tools, tests and benchmarks.
        public func renderOffscreen(
            world: World, width: Int, height: Int, time: Double = 0, deltaTime: Float = 1.0 / 60,
            ui: UIContext? = nil
        ) -> (any MTLTexture)? {
            let w = min(max(width, 1), 16384)
            let h = min(max(height, 1), 16384)
            if offscreen?.width != w || offscreen?.height != h {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm_srgb, width: w, height: h,
                    mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                MemoryTracker.shared.free("GPU.Offscreen", bytes: offscreenBytes)
                offscreen = device.makeTexture(descriptor: d)
                offscreen?.label = "Ferox.Offscreen"
                offscreenBytes = offscreen?.allocatedSize ?? 0
                MemoryTracker.shared.allocate("GPU.Offscreen", bytes: offscreenBytes)
            }
            guard let target = offscreen,
                render(world: world, to: RenderOutput(texture: target), time: time, deltaTime: deltaTime, ui: ui)
            else { return nil }
            waitUntilIdle()
            return target
        }

        /// Copies a 2D `bgra8`/`rgba8` texture into CPU memory (tightly packed rows, 4 bytes per
        /// pixel). Blocks until the copy has finished. Returns nil for other formats.
        public func readPixels(_ texture: any MTLTexture) -> [UInt8]? {
            let fourByte: Set<MTLPixelFormat> = [.bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb]
            guard fourByte.contains(texture.pixelFormat), texture.textureType == .type2D else { return nil }
            let rowBytes = texture.width * 4
            let length = rowBytes * texture.height
            guard length > 0, let buffer = device.makeBuffer(length: length, options: .storageModeShared),
                let cb = renderDevice.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder()
            else { return nil }
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: length)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            guard cb.status == .completed else { return nil }
            return [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: length))
        }

        /// Number of resident GPU particle emitters (diagnostics and leak tests).
        public var gpuParticleEmitterCount: Int { overlays.gpuEmitterCount }
    }
#endif
