/// Tests for `EditorSession`: selection, undo/redo, Play/Stop snapshot restore, pause and
/// step, duplication, editor-owned entities, and scene save/load validation.
import XCTest

@testable import Ferox

final class EditorSessionTests: XCTestCase {
    var engine: Engine!
    var session: EditorSession!

    override func setUpWithError() throws {
        var config = EngineConfiguration(title: "EditorTest")
        config.enableAudio = false
        engine = try Engine(configuration: config)
        session = EditorSession(engine: engine)
    }

    override func tearDown() {
        session = nil
        engine = nil
    }

    func position(_ e: Entity) -> Vec3 { engine.world.get(Transform.self, e)?.position ?? Vec3(.nan, .nan, .nan) }

    func entityNamed(_ name: String) -> Entity? {
        session.sceneEntities.first { session.displayName(of: $0) == name }
    }

    // Creating a session puts the engine into edit mode.
    func testSessionStartsInEditMode() {
        XCTAssertTrue(engine.isEditMode)
        XCTAssertEqual(session.state, .editing)
    }

    // createEntity selects the new entity and can be undone and redone.
    func testCreateUndoRedo() {
        let e = session.createEntity(named: "Box")
        XCTAssertEqual(session.selection, e)
        XCTAssertEqual(session.sceneEntities.count, 1)
        session.undo()
        XCTAssertEqual(session.sceneEntities.count, 0)
        XCTAssertNil(session.selection)
        session.redo()
        XCTAssertEqual(session.sceneEntities.count, 1)
        XCTAssertNotNil(entityNamed("Box"))
    }

    // Consecutive transform edits on one entity coalesce into a single undo step.
    func testTransformEditsCoalesce() throws {
        let e = session.createEntity(named: "Mover")
        for x in 1...5 { session.setTransform(Transform(position: Vec3(Float(x), 0, 0)), of: e) }
        XCTAssertEqual(position(e).x, 5)
        session.undo()  // reverts all five moves at once
        let restored = try XCTUnwrap(entityNamed("Mover"))
        XCTAssertEqual(position(restored).x, 0)
        session.undo()  // reverts the creation
        XCTAssertNil(entityNamed("Mover"))
    }

    // Undo restores the selection by document position even though entity ids change.
    func testUndoPreservesSelection() {
        _ = session.createEntity(named: "A")
        let b = session.createEntity(named: "B")
        session.rename(b, to: "B2")
        session.undo()
        XCTAssertEqual(session.selection.map(session.displayName(of:)), "B")
    }

    // A new edit clears the redo stack.
    func testNewEditClearsRedo() {
        _ = session.createEntity(named: "A")
        session.undo()
        XCTAssertTrue(session.canRedo)
        _ = session.createEntity(named: "B")
        XCTAssertFalse(session.canRedo)
    }

    // Undo history is bounded by maxUndoSteps.
    func testUndoHistoryIsBounded() {
        session.maxUndoSteps = 3
        for i in 0..<10 { _ = session.createEntity(named: "E\(i)") }
        var undone = 0
        while session.canUndo {
            session.undo()
            undone += 1
        }
        XCTAssertEqual(undone, 3)
        XCTAssertEqual(session.sceneEntities.count, 7)
    }

    // Stop restores the scene exactly as it was when Play was pressed.
    func testPlayStopRestoresScene() throws {
        let crate = engine.world.createEntity(named: "Crate", transform: Transform(position: Vec3(0, 10, 0)))
        engine.world.add(RigidBody3D(), to: crate)
        engine.world.add(Collider3D.box(Vec3(1, 1, 1)), to: crate)
        session.play()
        XCTAssertEqual(session.state, .playing)
        XCTAssertFalse(engine.isEditMode)
        engine.simulate(frames: 60)
        XCTAssertLessThan(position(crate).y, 9, "the crate falls during play")
        let spawned = engine.world.createEntity(named: "Spawned")  // created by gameplay
        session.stop()
        XCTAssertEqual(session.state, .editing)
        XCTAssertTrue(engine.isEditMode)
        XCTAssertFalse(engine.world.isAlive(spawned))
        let restored = try XCTUnwrap(entityNamed("Crate"))
        XCTAssertEqual(position(restored).y, 10, accuracy: 1e-5)
        XCTAssertEqual(session.sceneEntities.count, 1)
    }

    // Edits are not recorded in play mode, and undo is unavailable there.
    func testNoUndoDuringPlay() {
        _ = session.createEntity(named: "A")
        session.play()
        XCTAssertFalse(session.canUndo)
        session.recordUndo("ignored")
        session.stop()
        session.undo()
        XCTAssertEqual(session.sceneEntities.count, 0)
        XCTAssertFalse(session.canUndo)
    }

    // While paused the simulation does not advance; step advances one fixed step.
    func testPauseAndStep() {
        let crate = engine.world.createEntity(named: "Crate", transform: Transform(position: Vec3(0, 10, 0)))
        engine.world.add(RigidBody3D(), to: crate)
        engine.world.add(Collider3D.box(Vec3(1, 1, 1)), to: crate)
        session.play()
        engine.simulate(frames: 5)
        session.togglePause()
        XCTAssertEqual(session.state, .paused)
        let before = position(crate).y
        engine.simulate(frames: 10)
        XCTAssertEqual(position(crate).y, before, accuracy: 1e-6)
        session.step()
        XCTAssertLessThan(position(crate).y, before)
        session.togglePause()
        XCTAssertEqual(session.state, .playing)
    }

    // Editor-owned entities survive restores and are never saved or listed.
    func testEditorEntitiesAreExcluded() throws {
        let camera = engine.world.createEntity(named: "Editor Camera")
        session.editorEntities = [camera]
        _ = session.createEntity(named: "A")
        XCTAssertFalse(session.sceneEntities.contains(camera))
        session.undo()
        XCTAssertTrue(engine.world.isAlive(camera))
        session.select(camera)
        XCTAssertNil(session.selection)
    }

    // Duplicate copies the whole subtree under the same parent.
    func testDuplicateSubtree() throws {
        let root = session.createEntity(named: "Root")
        _ = session.createEntity(named: "Child", parent: root)
        session.select(root)
        let copy = try XCTUnwrap(session.duplicateSelection())
        XCTAssertNotEqual(copy, root)
        XCTAssertEqual(session.selection, copy)
        XCTAssertEqual(engine.world.children(of: copy).count, 1)
        XCTAssertEqual(session.sceneEntities.count, 4)
    }

    // Delete removes the selected entity with its children.
    func testDeleteSelection() {
        let root = session.createEntity(named: "Root")
        _ = session.createEntity(named: "Child", parent: root)
        session.select(root)
        session.deleteSelection()
        XCTAssertEqual(session.sceneEntities.count, 0)
        XCTAssertNil(session.selection)
        session.undo()
        XCTAssertEqual(session.sceneEntities.count, 2)
    }

    // Save then load round-trips names, hierarchy and transforms.
    func testSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferox-\(UUID().uuidString).fxscene")
        defer { try? FileManager.default.removeItem(at: url) }
        let root = session.createEntity(named: "Root")
        session.setTransform(Transform(position: Vec3(1, 2, 3)), of: root)
        _ = session.createEntity(named: "Child", parent: root)
        session.sceneName = "Level"
        try session.save(to: url)
        XCTAssertFalse(session.isDirty)

        try session.newScene()
        XCTAssertEqual(session.sceneEntities.count, 0)
        try session.load(from: url)
        XCTAssertEqual(session.sceneName, "Level")
        let loaded = try XCTUnwrap(entityNamed("Root"))
        XCTAssertEqual(position(loaded).z, 3, accuracy: 1e-6)
        XCTAssertEqual(engine.world.children(of: loaded).count, 1)
    }

    // Malformed and oversized files are rejected and leave the scene untouched.
    func testLoadRejectsBadFiles() throws {
        _ = session.createEntity(named: "Keep")
        let dir = FileManager.default.temporaryDirectory
        let garbage = dir.appendingPathComponent("ferox-\(UUID().uuidString).fxscene")
        try Data("{ not json".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        XCTAssertThrowsError(try session.load(from: garbage))

        let cyclic = dir.appendingPathComponent("ferox-\(UUID().uuidString).fxscene")
        try Data(
            #"{"formatVersion":1,"name":"x","metadata":{},"entities":[{"id":0,"parent":1,"components":{}},{"id":1,"parent":0,"components":{}}]}"#
                .utf8
        ).write(to: cyclic)
        defer { try? FileManager.default.removeItem(at: cyclic) }
        XCTAssertThrowsError(try session.load(from: cyclic))

        XCTAssertThrowsError(try session.load(from: cyclic, limits: DecodeLimits(maxFileBytes: 8)))
        XCTAssertNotNil(entityNamed("Keep"))
    }

    // Saving and loading are refused during play mode.
    func testFileOperationsRequireEditMode() {
        session.play()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferox-never.fxscene")
        XCTAssertThrowsError(try session.save(to: url))
        XCTAssertThrowsError(try session.load(from: url))
        XCTAssertThrowsError(try session.newScene())
        session.stop()
    }

    // onChange fires for selection changes.
    func testOnChangeNotifies() {
        var changes = 0
        session.onChange = { changes += 1 }
        let e = engine.world.createEntity(named: "E")
        session.select(e)
        session.select(e)  // unchanged: no notification
        XCTAssertEqual(changes, 1)
    }
}

/// Tests for `GameLauncher.parse` and the headless runner.
final class LauncherTests: XCTestCase {
    // Defaults apply when no flags are given; unknown arguments are ignored.
    func testDefaults() {
        let o = GameLauncher.parse(["--unknown", "value"])
        XCTAssertEqual(o, GameLauncher.Options())
        XCTAssertFalse(o.headless)
        XCTAssertEqual(o.frames, 600)
    }

    // All flags are parsed.
    func testFlags() {
        let o = GameLauncher.parse(["--headless", "--frames", "120", "--dt", "0.02"])
        XCTAssertTrue(o.headless)
        XCTAssertEqual(o.frames, 120)
        XCTAssertEqual(o.delta, 0.02, accuracy: 1e-12)
    }

    // Out-of-range and malformed values are clamped or ignored.
    func testInvalidValues() {
        XCTAssertEqual(GameLauncher.parse(["--frames", "-5"]).frames, 0)
        XCTAssertEqual(GameLauncher.parse(["--frames", "999999999999"]).frames, 10_000_000)
        XCTAssertEqual(GameLauncher.parse(["--frames", "abc"]).frames, 600)
        XCTAssertEqual(GameLauncher.parse(["--dt", "0"]).delta, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(GameLauncher.parse(["--dt", "5"]).delta, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(GameLauncher.parse(["--dt", "nan"]).delta, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(GameLauncher.parse(["--frames"]).frames, 600, "a trailing flag without a value is ignored")
    }

    // The headless runner drives a game for the requested number of frames.
    func testRunHeadless() {
        final class Counter: Game {
            var updates = 0
            func update(engine: Engine, time: FrameTime) { updates += 1 }
        }
        let game = Counter()
        var options = GameLauncher.Options()
        options.headless = true
        options.frames = 25
        GameLauncher.runHeadless(game, configuration: EngineConfiguration(title: "Headless"), options: options)
        XCTAssertEqual(game.updates, 25)
    }
}
