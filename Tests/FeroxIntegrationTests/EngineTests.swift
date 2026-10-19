/// Headless tests for `Engine`: subsystem wiring, the frame order, fixed steps, edit mode,
/// physics integration through the ECS, and lifecycle (start/shutdown).
import XCTest
@testable import Ferox

final class EngineTests: XCTestCase {
    /// A game that records which hooks ran, and how often.
    final class RecordingGame: Game {
        var log: [String] = []
        var fixedSteps = 0
        var updates = 0
        var setupError: (any Error)?
        func setup(engine: Engine) throws {
            log.append("setup")
            if let setupError { throw setupError }
        }
        func fixedUpdate(engine: Engine, dt: Float) { fixedSteps += 1 }
        func update(engine: Engine, time: FrameTime) { updates += 1; log.append("update") }
        func lateUpdate(engine: Engine, time: FrameTime) { log.append("lateUpdate") }
        func shutdown(engine: Engine) { log.append("shutdown") }
    }

    struct Boom: Error {}

    func makeEngine(edit: Bool = false, fixedHz: Double = 60) throws -> Engine {
        var config = EngineConfiguration(title: "Test")
        config.enableAudio = false
        config.isEditMode = edit
        config.graphics.frame.fixedUpdateHz = fixedHz
        return try Engine(configuration: config)
    }

    // The engine creates both physics systems by default and exposes core resources.
    func testDefaultSubsystems() throws {
        let engine = try makeEngine()
        XCTAssertNotNil(engine.physics2D)
        XCTAssertNotNil(engine.physics3D)
        XCTAssertFalse(engine.isEditMode)
    }

    // Physics systems can be disabled individually.
    func testPhysicsCanBeDisabled() throws {
        var config = EngineConfiguration(title: "NoPhysics")
        config.enableAudio = false
        config.physics2D = false
        config.physics3D = false
        let engine = try Engine(configuration: config)
        XCTAssertNil(engine.physics2D)
        XCTAssertNil(engine.physics3D)
    }

    // A missing asset root is reported instead of silently ignored.
    func testMissingAssetRootThrows() {
        var config = EngineConfiguration(title: "Assets")
        config.enableAudio = false
        config.assetRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ferox-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try Engine(configuration: config))
    }

    // start calls setup once; update and lateUpdate run once per tick, in that order.
    func testHookOrder() throws {
        let engine = try makeEngine()
        let game = RecordingGame()
        try engine.start(game)
        engine.tick(delta: 1.0 / 60)
        XCTAssertEqual(game.log, ["setup", "update", "lateUpdate"])
    }

    // One second at 60 Hz fixed rate yields about 60 fixed steps regardless of frame rate.
    func testFixedStepsAreFrameRateIndependent() throws {
        for frameRate in [30.0, 60.0, 144.0] {
            let engine = try makeEngine()
            let game = RecordingGame()
            try engine.start(game)
            engine.simulate(frames: Int(frameRate), delta: 1 / frameRate)
            XCTAssertEqual(Double(game.fixedSteps), 60, accuracy: 2, "at \(frameRate) fps")
            XCTAssertEqual(game.updates, Int(frameRate))
        }
    }

    // In edit mode the game's per-frame hooks are skipped (setup still runs).
    func testEditModeSkipsGameHooks() throws {
        let engine = try makeEngine(edit: true)
        let game = RecordingGame()
        try engine.start(game)
        engine.simulate(frames: 10)
        XCTAssertEqual(game.log, ["setup"])
        XCTAssertEqual(game.fixedSteps, 0)
    }

    // Edit mode is a runtime switch: leaving it starts the hooks on the next tick.
    func testEditModeToggle() throws {
        let engine = try makeEngine(edit: true)
        let game = RecordingGame()
        try engine.start(game)
        engine.tick(delta: 1.0 / 60)
        XCTAssertEqual(game.updates, 0)
        engine.isEditMode = false
        engine.tick(delta: 1.0 / 60)
        XCTAssertEqual(game.updates, 1)
    }

    // A dynamic 3D body created through components falls under gravity and lands on a box.
    func testPhysics3DThroughComponents() throws {
        let engine = try makeEngine()
        let world = engine.world
        let ground = world.createEntity(named: "Ground")
        world.add(Collider3D.box(Vec3(20, 1, 20)), to: ground) // top face at y = 0.5
        let crate = world.createEntity(named: "Crate", transform: Transform(position: Vec3(0, 5, 0)))
        world.add(RigidBody3D(), to: crate)
        world.add(Collider3D.box(Vec3(1, 1, 1)), to: crate)
        engine.simulate(frames: 240)
        let y = try XCTUnwrap(world.get(Transform.self, crate)).position.y
        XCTAssertEqual(y, 1.0, accuracy: 0.1, "crate should rest on the ground")
    }

    // A dynamic 2D body falls in -Y under default gravity.
    func testPhysics2DFalls() throws {
        let engine = try makeEngine()
        let world = engine.world
        let ball = world.createEntity(named: "Ball", transform: Transform(position: Vec3(0, 10, 0)))
        world.add(RigidBody2D(), to: ball)
        world.add(Collider2D.circle(0.5), to: ball)
        engine.simulate(frames: 30)
        let y = try XCTUnwrap(world.get(Transform.self, ball)).position.y
        XCTAssertLessThan(y, 10)
    }

    // Transforms are propagated by the end of every tick.
    func testWorldTransformsUpdatedEachTick() throws {
        let engine = try makeEngine()
        let parent = engine.world.createEntity(named: "Parent", transform: Transform(position: Vec3(1, 0, 0)))
        let child = engine.world.createEntity(named: "Child", transform: Transform(position: Vec3(0, 2, 0)), parent: parent)
        engine.tick(delta: 1.0 / 60)
        let p = try XCTUnwrap(engine.world.get(WorldTransform.self, child)).matrix.translation
        XCTAssertEqual(p.x, 1, accuracy: 1e-5)
        XCTAssertEqual(p.y, 2, accuracy: 1e-5)
    }

    // The active camera is the enabled one with the highest priority.
    func testActiveCameraPriority() throws {
        let engine = try makeEngine()
        let world = engine.world
        let low = world.createEntity(named: "Low")
        world.add(Camera.perspective(), to: low)
        let high = world.createEntity(named: "High")
        var camera = Camera.perspective()
        camera.priority = 5
        world.add(camera, to: high)
        engine.tick(delta: 1.0 / 60)
        XCTAssertEqual(engine.activeCamera()?.entity, high)
        world.add(Disabled(), to: high)
        XCTAssertEqual(engine.activeCamera()?.entity, low)
    }

    // A render-target camera and a disabled parent are not the screen camera, and a
    // priority tie keeps the lowest entity index. This is the same rule the extractor uses.
    func testActiveCameraMatchesTheScreenCamera() throws {
        let engine = try makeEngine()
        let world = engine.world
        let parent = world.createEntity(named: "Parent")
        let child = world.createEntity(named: "Child", parent: parent)
        var hidden = Camera.perspective()
        hidden.priority = 10
        world.add(hidden, to: child)
        world.add(Disabled(), to: parent)

        let offscreen = world.createEntity(named: "Offscreen")
        var target = Camera.perspective()
        target.priority = 9
        target.renderTarget = AssetID("rt")
        world.add(target, to: offscreen)

        let first = world.createEntity(named: "First")
        var tied = Camera.perspective()
        tied.priority = 1
        world.add(tied, to: first)
        let second = world.createEntity(named: "Second")
        var tiedToo = Camera.perspective()
        tiedToo.priority = 1
        world.add(tiedToo, to: second)
        engine.tick(delta: 1.0 / 60)
        XCTAssertLessThan(first.index, second.index)
        XCTAssertEqual(engine.activeCamera()?.entity, first)
        XCTAssertEqual(RenderSceneExtractor.mainCamera(in: world)?.0, first)
        XCTAssertNil(engine.activeCamera()?.camera.renderTarget)
    }

    // A pause of the clock stops fixed steps but the frame loop keeps running.
    func testPausedClockRunsNoFixedSteps() throws {
        let engine = try makeEngine()
        let game = RecordingGame()
        try engine.start(game)
        engine.clock.isPaused = true
        engine.simulate(frames: 30)
        XCTAssertEqual(game.fixedSteps, 0)
        XCTAssertEqual(game.updates, 30)
    }

    // shutdown calls the game's shutdown once and later ticks are no-ops.
    func testShutdownIsIdempotent() throws {
        let engine = try makeEngine()
        let game = RecordingGame()
        try engine.start(game)
        engine.shutdown()
        engine.shutdown()
        engine.tick(delta: 1.0 / 60)
        XCTAssertEqual(game.log, ["setup", "shutdown"])
        XCTAssertTrue(engine.isShutDown)
    }

    // An error thrown by setup propagates to the caller.
    func testSetupErrorPropagates() throws {
        let engine = try makeEngine()
        let game = RecordingGame()
        game.setupError = Boom()
        XCTAssertThrowsError(try engine.start(game))
    }

    // requestQuit only raises the flag; the host decides when to close.
    func testRequestQuit() throws {
        let engine = try makeEngine()
        XCTAssertFalse(engine.quitRequested)
        engine.requestQuit()
        XCTAssertTrue(engine.quitRequested)
    }

    // Changing graphics notifies the host once per actual change.
    func testGraphicsChangeNotifiesHost() throws {
        let engine = try makeEngine()
        var notifications = 0
        engine.onGraphicsChanged = { _ in notifications += 1 }
        let unchanged = engine.graphics
        engine.graphics = unchanged // unchanged: no notification
        XCTAssertEqual(notifications, 0)
        var expected = 0
        for preset in [QualityPreset.low, .ultra, .ultra] {
            var next = engine.graphics
            next.apply(preset)
            if next != engine.graphics { expected += 1 }
            engine.graphics = next
        }
        XCTAssertEqual(notifications, expected)
        XCTAssertGreaterThan(expected, 0)
    }

    // The collision mesh cache rebuilds only when the asset revision changes.
    func testCollisionMeshCacheKeyedByRevision() {
        let cache = CollisionMeshCache()
        var builds = 0
        let id = AssetID("mesh")
        func build() -> TriangleMesh {
            builds += 1
            return TriangleMesh(vertices: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)], indices: [0, 1, 2])
        }
        _ = cache.mesh(id, revision: 1, build: build)
        _ = cache.mesh(id, revision: 1, build: build)
        XCTAssertEqual(builds, 1)
        _ = cache.mesh(id, revision: 2, build: build)
        XCTAssertEqual(builds, 2)
    }
}
