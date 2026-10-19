import Foundation

/// Everything needed to start an `Engine`. Plain data so it can be loaded from a project
/// file or built in code.
/// `URL` is not `Sendable` on the Swift 5.10 Linux SDK. The roots are immutable paths.
public struct EngineConfiguration: @unchecked Sendable {
    /// Window title (macOS host) and log prefix.
    public var title = "Ferox"
    /// Initial window content size in points.
    public var windowSize = Vec2(1280, 720)
    /// Renderer quality settings. `graphics.frame.fixedUpdateHz` drives the simulation rate.
    public var graphics = GraphicsSettings()
    /// Project asset folder (an `AssetDatabase` root). nil runs without file assets:
    /// everything must be registered in code (`AssetManager.registerMesh` etc.).
    public var assetRoot: URL?
    /// Re-imports changed asset files while running (development builds).
    public var hotReloadAssets = false
    /// Uses the AVFoundation backend when available; otherwise (or when false) a silent
    /// backend that tracks voices without producing sound — tests and headless runs.
    public var enableAudio = true
    /// Adds the built-in 2D/3D physics systems. Disable for games with their own physics.
    public var physics2D = true
    public var physics3D = true
    /// Editor edit mode: only systems with `runsInEditMode` execute and gameplay hooks
    /// (`Game.update` etc.) are not called.
    public var isEditMode = false
    /// Directory of `.metal` sources to compile at startup and hot-reload, instead of the
    /// shaders bundled with FeroxRender (shader development).
    public var shaderDirectory: URL?

    public init(title: String = "Ferox") { self.title = title }
}

/// Game code plugged into the engine loop. Every hook has an empty default, so a game
/// implements only what it needs. All hooks run on the main thread.
///
/// Per frame, in order (see Docs/05-Engine-Lifecycle.md):
/// 1. `earlyUpdate` systems
/// 2. `fixedUpdate(engine:dt:)` then fixed-update systems (physics) — 0…N times
/// 3. `update(engine:time:)` then update systems
/// 4. late-update systems (animation), `lateUpdate(engine:time:)`
/// 5. transform propagation, pre-render systems, event flush
public protocol Game: AnyObject {
    /// Called once after the engine (and, with a window, the renderer) is ready.
    func setup(engine: Engine) throws
    /// Fixed-rate step: deterministic gameplay that must match physics.
    func fixedUpdate(engine: Engine, dt: Float)
    /// Variable-rate gameplay, once per rendered frame.
    func update(engine: Engine, time: FrameTime)
    /// After animation; camera follow belongs here.
    func lateUpdate(engine: Engine, time: FrameTime)
    /// Called once before the engine stops.
    func shutdown(engine: Engine)
}

extension Game {
    public func setup(engine: Engine) throws {}
    public func fixedUpdate(engine: Engine, dt: Float) {}
    public func update(engine: Engine, time: FrameTime) {}
    public func lateUpdate(engine: Engine, time: FrameTime) {}
    public func shutdown(engine: Engine) {}
}

/// The engine runtime: owns the world, the subsystems and the frame loop.
///
/// `Engine` is platform independent — it never touches Metal or AppKit — so a whole game
/// can be simulated headlessly (`tick(delta:)`) in unit tests or on a server. Rendering
/// and windowing are added by `GameHost` on macOS, which calls `tick()` once per display
/// frame and hands the world to `Renderer`.
///
/// Not thread safe: create and drive it from one thread (the main thread with a window).
public final class Engine {
    public let configuration: EngineConfiguration
    public let world: World
    public let events: EventBus
    public let scheduler: SystemScheduler
    public let scenes: SceneManager
    public let input: InputSystem
    public let assets: AssetManager
    public let animation: AnimationSystem
    public let physics2D: PhysicsSystem2D?
    public let physics3D: PhysicsSystem3D?
    public let audio: any AudioBackend
    public let ui: UIContext
    /// Frame clock: set `clock.timeScale` for slow motion, `clock.isPaused` to pause
    /// simulation (rendering continues).
    public var clock: FrameClock
    /// The game driven by this engine (held strongly; released by `shutdown()`).
    public private(set) var game: (any Game)?
    /// Last frame's timing.
    public private(set) var time = FrameTime()
    /// Rolling frame-time history (unscaled seconds) for the profiler overlay and FeroxDiag.
    public private(set) var frameStatistics = FrameStatistics()
    /// Live graphics settings. Changing them (a quality menu, a benchmark sweep) notifies
    /// the host through `onGraphicsChanged`, which applies them to the renderer before the
    /// next frame. Headless engines simply store the value.
    public var graphics: GraphicsSettings {
        didSet { if graphics != oldValue { onGraphicsChanged?(graphics) } }
    }
    /// Set by the host (`GameHost`) to apply `graphics` changes.
    public var onGraphicsChanged: ((GraphicsSettings) -> Void)?
    /// Viewport size in points, set by the host before each tick (UI layout).
    public var viewportPoints = Vec2(1280, 720)
    /// Set by `requestQuit()`; the host closes the window at the end of the frame.
    public private(set) var quitRequested = false
    public private(set) var isShutDown = false
    /// Edit mode: game hooks and systems that do not opt in with `runsInEditMode` are
    /// skipped, so the scene can be edited without simulating it. Starts from
    /// `configuration.isEditMode`; the editor toggles it for Play and Stop.
    public var isEditMode: Bool

    /// Creates the engine and its subsystems. Throws if the asset root is unusable.
    public init(configuration: EngineConfiguration = EngineConfiguration()) throws {
        self.configuration = configuration
        graphics = configuration.graphics
        isEditMode = configuration.isEditMode
        Engine.registerBuiltinComponents()

        world = World()
        events = EventBus()
        scheduler = SystemScheduler(world: world)
        scenes = SceneManager(world: world)
        input = InputSystem()
        input.addMap(.defaultGameplay)
        input.addMap(.defaultUI)
        input.pushContext(InputSystem.Context("Gameplay", maps: [ActionMap.defaultGameplay.name]))

        var database: AssetDatabase?
        if let root = configuration.assetRoot {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { throw EngineError.assetRootMissing(root) }
            database = AssetDatabase(root: root)
        }
        assets = AssetManager(database: database)
        assets.hotReload = configuration.hotReloadAssets

        audio = Engine.makeAudioBackend(enabled: configuration.enableAudio)
        audio.memoryBudgetBytes = assets.budget.audioBytes
        ui = UIContext(fonts: Engine.makeFontProvider())
        clock = FrameClock(fixedHz: max(configuration.graphics.frame.fixedUpdateHz, 1))

        // Systems. Physics runs in fixedUpdate; animation, tweens and timelines in
        // lateUpdate (orders are defined on each system).
        physics2D = configuration.physics2D ? PhysicsSystem2D() : nil
        physics3D = configuration.physics3D ? PhysicsSystem3D() : nil
        animation = AnimationSystem()
        if let physics2D { scheduler.add(physics2D) }
        if let physics3D {
            // Mesh colliders read triangles from the asset manager. The BVH build is
            // cached per mesh revision so many bodies sharing a mesh pay for it once.
            let cache = CollisionMeshCache()
            physics3D.meshProvider = { [weak assets] id in
                guard let handle = assets?.mesh(id), let mesh = handle.value else { return nil }
                return cache.mesh(id, revision: handle.revision) {
                    TriangleMesh(vertices: mesh.positions, indices: mesh.indices)
                }
            }
            scheduler.add(physics3D)
        }
        scheduler.add(animation)
        scheduler.add(TweenSystem())
        scheduler.add(TimelineSystem(animation: animation))
        world.setResource(events)
        world.setResource(input)
        world.setResource(assets)
    }

    /// Registers the component types of every engine module with the shared serialization
    /// registry (scene files, prefabs, the editor inspector). Safe to call repeatedly.
    public static func registerBuiltinComponents() {
        registrationLock.locked {
            guard !registered else { return }
            registered = true
            ComponentRegistry.shared.registerPhysicsComponents()
            ComponentRegistry.shared.registerAnimationComponents()
        }
    }

    private static let registrationLock = NSLock()
    nonisolated(unsafe) private static var registered = false

    // MARK: Game lifecycle

    /// Attaches `game` and calls its `setup`. Only one game can be attached.
    public func start(_ game: any Game) throws {
        precondition(self.game == nil, "Engine.start called twice")
        self.game = game
        clock.reset()
        try game.setup(engine: self)
        Log.info("Engine", "\(configuration.title) started")
    }

    /// Asks the host to stop after the current frame (e.g. from a "Quit" button).
    public func requestQuit() { quitRequested = true }

    /// Calls `Game.shutdown`, unloads scenes and stops every voice. The audio backend
    /// itself is released with the engine. Idempotent.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        game?.shutdown(engine: self)
        game = nil
        scenes.unloadAll()
        audio.stopAll(fadeOut: 0)
        audio.update(dt: 0)
        Log.info("Engine", "\(configuration.title) stopped")
    }

    // MARK: Frame

    /// Runs one frame of simulation.
    ///
    /// - Parameter delta: Explicit frame delta in seconds for deterministic stepping (tests,
    ///   replays, offline capture). nil reads the monotonic clock.
    /// - Returns: The frame's timing.
    @discardableResult
    public func tick(delta: Double? = nil) -> FrameTime {
        guard !isShutDown else { return time }
        let (ft, steps) = delta.map { clock.tick(delta: $0) } ?? clock.tick()
        time = ft
        frameStatistics.add(ft.unscaledDelta)
        let edit = isEditMode

        Profiler.shared.beginFrame()
        Profiler.shared.scope("Engine.Frame") {
            input.beginFrame()
            let context = SystemContext(time: ft, dt: Float(ft.delta), events: events, isEditMode: edit)
            scheduler.run(.earlyUpdate, context: context)

            // Fixed steps: the game first, so forces it applies are integrated this step.
            if steps > 0 {
                let fixed = SystemContext(time: ft, dt: Float(ft.fixedDelta), events: events, isEditMode: edit)
                for _ in 0..<steps {
                    if !edit { game?.fixedUpdate(engine: self, dt: Float(ft.fixedDelta)) }
                    world.flushDeferred()
                    scheduler.run(.fixedUpdate, context: fixed)
                    events.flush()
                }
            }
            // Smooth rendering between fixed steps (bodies opted in with `interpolate`).
            let alpha = Float(ft.interpolationAlpha)
            physics2D?.interpolate(world, alpha: alpha)
            physics3D?.interpolate(world, alpha: alpha)

            if !edit { game?.update(engine: self, time: ft) }
            world.flushDeferred()
            scheduler.run(.update, context: context)

            scheduler.run(.lateUpdate, context: context)
            if !edit { game?.lateUpdate(engine: self, time: ft) }
            world.flushDeferred()

            scenes.update(dt: ft.delta)
            TransformSystem.update(world)
            scheduler.run(.preRender, context: context)
            events.flush()

            assets.update()
            updateAudioListener()
            audio.update(dt: ft.unscaledDelta)
            ui.update(input: input.state, dt: Float(ft.unscaledDelta), viewportPoints: viewportPoints)
        }
        return ft
    }

    /// Runs `frames` ticks of `delta` seconds each (headless simulation).
    public func simulate(frames: Int, delta: Double = 1.0 / 60) {
        for _ in 0..<max(frames, 0) { tick(delta: delta) }
    }

    // MARK: Helpers

    /// The camera the renderer draws to the screen. This is `RenderSceneExtractor.mainCamera`:
    /// active in the hierarchy, `renderTarget == nil`, highest priority, and on a tie the
    /// lowest entity index. Audio and game code follow the same camera as the picture.
    public func activeCamera() -> (entity: Entity, camera: Camera, transform: WorldTransform)? {
        guard let (e, c) = RenderSceneExtractor.mainCamera(in: world) else { return nil }
        let t = world.get(WorldTransform.self, e) ?? WorldTransform(matrix: world.worldMatrix(of: e))
        return (entity: e, camera: c, transform: t)
    }

    /// Spatial audio follows the active camera.
    private func updateAudioListener() {
        guard let cam = activeCamera() else { return }
        let m = cam.transform.matrix
        audio.setListener(
            position: m.translation, forward: m.transformDirection(.forward).normalized,
            up: m.transformDirection(.up).normalized)
    }

    private static func makeAudioBackend(enabled: Bool) -> any AudioBackend {
        #if canImport(AVFoundation)
            if enabled {
                do {
                    return try AVAudioBackend()
                } catch {
                    Log.warning("Audio", "Audio output unavailable (\(error)); continuing without sound")
                }
            }
        #endif
        return SilentAudioBackend()
    }

    private static func makeFontProvider() -> any UIFontProvider {
        #if canImport(CoreText)
            return CoreTextFontProvider()
        #else
            return MonospaceFontProvider()
        #endif
    }
}

/// Collision meshes built from mesh assets, keyed by asset id and revision.
final class CollisionMeshCache {
    private var meshes: [AssetID: (revision: UInt64, mesh: TriangleMesh)] = [:]

    func mesh(_ id: AssetID, revision: UInt64, build: () -> TriangleMesh) -> TriangleMesh {
        if let cached = meshes[id], cached.revision == revision { return cached.mesh }
        let m = build()
        meshes[id] = (revision, m)
        return m
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case assetRootMissing(URL)
    case rendererUnavailable(String)

    public var description: String {
        switch self {
        case .assetRootMissing(let url): return "Asset folder does not exist: \(url.path)"
        case .rendererUnavailable(let reason): return "Renderer unavailable: \(reason)"
        }
    }
}
