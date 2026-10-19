#if canImport(AppKit) && canImport(MetalKit)
    @preconcurrency import AppKit
    @preconcurrency import Metal
    @preconcurrency import MetalKit
    @preconcurrency import QuartzCore

    /// Runs a `Game` in a macOS window: creates the application, the window, a Metal view,
    /// the engine and the renderer, and drives one `Engine.tick()` + `Renderer.render` per
    /// display refresh.
    ///
    /// ```swift
    /// final class MyGame: Game { ... }
    /// GameHost.run(MyGame(), configuration: EngineConfiguration(title: "My Game"))
    /// ```
    ///
    /// Frame pacing: the view runs at `graphics.frame.targetFPS`, or the display's maximum
    /// refresh rate when nil (ProMotion displays run at up to 120 Hz). `vsync` maps to
    /// `CAMetalLayer.displaySyncEnabled`; the renderer bounds CPU run-ahead with
    /// `maxFramesInFlight`.
    @MainActor
    public final class GameHost: NSObject {
        public let engine: Engine
        public let renderer: Renderer
        public let window: NSWindow
        public let view: GameView
        private let inputBackend: MacInputBackend
        private var appDelegate: AppDelegate?
        /// Called every frame after `Engine.tick()` and before rendering — the place for
        /// host-level drawing such as editor gizmos (`renderer.debugDraw`).
        public var onFrame: ((FrameTime) -> Void)?

        /// Creates a host without starting the application loop (embedding, the editor).
        public init(engine: Engine, frame: NSRect? = nil) throws {
            self.engine = engine
            let config = engine.configuration
            do {
                renderer = try Renderer(
                    settings: engine.graphics, assets: engine.assets,
                    shaderDirectory: config.shaderDirectory)
            } catch {
                throw EngineError.rendererUnavailable("\(error)")
            }
            renderer.animations = engine.animation.library
            inputBackend = MacInputBackend(input: engine.input)

            let size = NSSize(
                width: CGFloat(max(config.windowSize.x, 320)), height: CGFloat(max(config.windowSize.y, 200)))
            window = NSWindow(
                contentRect: frame ?? NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = config.title
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.center()

            view = GameView(frame: NSRect(origin: .zero, size: size), device: renderer.renderDevice.device)
            super.init()
            view.input = inputBackend
            view.colorPixelFormat = .bgra8Unorm_srgb
            view.depthStencilPixelFormat = .invalid  // the renderer owns its depth buffers
            view.framebufferOnly = true  // the final pass is a render pass, never compute/blit
            view.autoResizeDrawable = true
            view.delegate = self
            applyFramePacing()
            window.contentView = view
            window.delegate = self
            engine.onGraphicsChanged = { [weak self] settings in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.renderer.settings = settings
                    self.applyFramePacing()
                }
            }
        }

        /// Creates the application and runs `game`. Closing the window quits the application
        /// (the process ends), so code after this call does not run.
        /// `configure` runs after the host exists and before `Game.setup` (the editor uses it
        /// to install its panels and gizmo hook). Fatal
        /// startup errors (no Metal device, broken asset folder, `Game.setup` throwing) are
        /// logged and shown in an alert, and the process exits with status 1.
        public static func run(
            _ game: any Game, configuration: EngineConfiguration = EngineConfiguration(),
            configure: ((GameHost) throws -> Void)? = nil
        ) {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let host: GameHost
            do {
                let engine = try Engine(configuration: configuration)
                host = try GameHost(engine: engine)
                try configure?(host)
                try engine.start(game)
            } catch {
                Log.error("Engine", "Startup failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "\(configuration.title) could not start"
                alert.informativeText = "\(error)"
                alert.runModal()
                exit(1)
            }
            let delegate = AppDelegate(host: host)
            host.appDelegate = delegate
            app.delegate = delegate
            app.mainMenu = makeMenu(title: configuration.title)
            host.window.makeKeyAndOrderFront(nil)
            host.window.makeFirstResponder(host.view)
            app.activate(ignoringOtherApps: true)
            app.run()
        }

        /// Re-applies frame pacing after `renderer.settings` changed at runtime.
        public func applyFramePacing() {
            let frame = renderer.settings.frame
            let screenMax = window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
            view.preferredFramesPerSecond = min(max(frame.targetFPS ?? screenMax, 1), max(screenMax, 1))
            if let layer = view.layer as? CAMetalLayer {
                layer.displaySyncEnabled = frame.vsync
                layer.maximumDrawableCount = min(max(frame.maxFramesInFlight, 2), 3)
            }
        }

        /// Stops the game, waits for the GPU and releases GPU caches. Idempotent.
        public func shutdown() {
            guard !engine.isShutDown else { return }
            view.isPaused = true
            engine.shutdown()
            renderer.waitUntilIdle()
            renderer.purgeCaches()
        }

        private static func makeMenu(title: String) -> NSMenu {
            let main = NSMenu()
            let appItem = NSMenuItem()
            main.addItem(appItem)
            let appMenu = NSMenu()
            appMenu.addItem(
                withTitle: "Quit \(title)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            return main
        }
    }

    extension GameHost: MTKViewDelegate {
        public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Render targets follow the drawable size on the next frame (`RenderTargets.ensure`).
        }

        public nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { frame() }
        }

        private func frame() {
            guard !engine.isShutDown else { return }
            inputBackend.poll()
            engine.viewportPoints = Vec2(Float(view.bounds.width), Float(view.bounds.height))
            engine.ui.backingScale = Float(window.backingScaleFactor)
            let time = engine.tick()
            onFrame?(time)
            // The drawable is acquired as late as possible: after simulation, before encoding.
            if let drawable = view.currentDrawable {
                renderer.render(
                    world: engine.world, to: RenderOutput(texture: drawable.texture, drawable: drawable),
                    time: time.elapsed, deltaTime: Float(time.unscaledDelta), ui: engine.ui)
            }
            if engine.quitRequested { window.performClose(nil) }
        }
    }

    extension GameHost: NSWindowDelegate {
        public nonisolated func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                shutdown()
                NSApp.terminate(nil)
            }
        }

        public nonisolated func windowDidResignKey(_ notification: Notification) {
            // Releases held keys so a key released while unfocused does not stick.
            MainActor.assumeIsolated { inputBackend.focusLost() }
        }

        public nonisolated func windowDidChangeScreen(_ notification: Notification) {
            MainActor.assumeIsolated { applyFramePacing() }
        }
    }

    /// Terminates with the window and shuts the engine down on Quit.
    @MainActor
    private final class AppDelegate: NSObject, NSApplicationDelegate {
        unowned let host: GameHost
        init(host: GameHost) { self.host = host }

        nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

        nonisolated func applicationWillTerminate(_ notification: Notification) {
            MainActor.assumeIsolated { host.shutdown() }
        }
    }

    /// The Metal view: forwards keyboard, mouse and gesture events to the input backend.
    public final class GameView: MTKView {
        weak var input: MacInputBackend?

        public override var acceptsFirstResponder: Bool { true }
        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func forward(_ event: NSEvent) -> Bool { input?.handle(event, in: self) ?? false }

        public override func keyDown(with event: NSEvent) {
            // Command shortcuts (⌘Q, ⌘W) go to the menu.
            if event.modifierFlags.contains(.command) || !forward(event) { super.keyDown(with: event) }
        }
        public override func keyUp(with event: NSEvent) { if !forward(event) { super.keyUp(with: event) } }
        public override func flagsChanged(with event: NSEvent) {
            if !forward(event) { super.flagsChanged(with: event) }
        }
        public override func mouseMoved(with event: NSEvent) { _ = forward(event) }
        public override func mouseDragged(with event: NSEvent) { _ = forward(event) }
        public override func rightMouseDragged(with event: NSEvent) { _ = forward(event) }
        public override func otherMouseDragged(with event: NSEvent) { _ = forward(event) }
        public override func mouseDown(with event: NSEvent) { _ = forward(event) }
        public override func mouseUp(with event: NSEvent) { _ = forward(event) }
        public override func rightMouseDown(with event: NSEvent) { _ = forward(event) }
        public override func rightMouseUp(with event: NSEvent) { _ = forward(event) }
        public override func otherMouseDown(with event: NSEvent) { _ = forward(event) }
        public override func otherMouseUp(with event: NSEvent) { _ = forward(event) }
        public override func scrollWheel(with event: NSEvent) { _ = forward(event) }
        public override func magnify(with event: NSEvent) { _ = forward(event) }
        public override func rotate(with event: NSEvent) { _ = forward(event) }
    }
#endif
