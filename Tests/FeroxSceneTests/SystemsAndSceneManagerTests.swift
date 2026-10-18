/// Tests for FeroxScene's frame orchestration: `SystemScheduler` phase order, ordering within a
/// phase, edit-mode and enabled-flag filtering, attach and detach hooks, and `SceneManager`
/// loading, unloading, persistence across scenes, and timed transitions.
import FeroxCore
import XCTest
@testable import FeroxScene

/// Collects the names of systems in the order they ran.
private final class RunRecorder {
    var events: [String] = []
}

/// A system that records when it is attached and detached.
private final class AttachProbe: System {
    let phase: SystemPhase = .update
    private(set) var attached = false
    private(set) var detached = false
    func update(world: World, context: SystemContext) {}
    func attach(world: World) { attached = true }
    func detach(world: World) { detached = true }
}

private func makeContext(editMode: Bool = false) -> SystemContext {
    SystemContext(time: FrameTime(), dt: 1.0 / 60.0, events: EventBus(), isEditMode: editMode)
}

/// Builds a scene document with `count` named entities.
private func makeDocument(name: String, count: Int) -> SceneDocument {
    let records = (0..<count).map { index in
        SceneDocument.EntityRecord(id: index, components: ["Name": .object(["value": .string("\(name)\(index)")])])
    }
    return SceneDocument(name: name, entities: records)
}

final class SystemSchedulerTests: XCTestCase {
    // Phases run in their declared order regardless of the order the systems were added.
    func testPhasesRunInDeclaredOrder() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        let rec = RunRecorder()
        scheduler.add(ClosureSystem("late", phase: .lateUpdate) { _, _ in rec.events.append("late") })
        scheduler.add(ClosureSystem("early", phase: .earlyUpdate) { _, _ in rec.events.append("early") })
        scheduler.add(ClosureSystem("pre", phase: .preRender) { _, _ in rec.events.append("pre") })
        scheduler.add(ClosureSystem("fixed", phase: .fixedUpdate) { _, _ in rec.events.append("fixed") })
        scheduler.add(ClosureSystem("update", phase: .update) { _, _ in rec.events.append("update") })
        for phase in SystemPhase.allCases {
            scheduler.run(phase, context: makeContext())
        }
        XCTAssertEqual(rec.events, ["early", "fixed", "update", "late", "pre"])
    }

    // Within a phase, lower order values run first and equal orders keep insertion order.
    func testOrderWithinPhaseIsStable() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        let rec = RunRecorder()
        scheduler.add(ClosureSystem("b", phase: .update, order: 2) { _, _ in rec.events.append("b") })
        scheduler.add(ClosureSystem("a", phase: .update, order: 1) { _, _ in rec.events.append("a") })
        scheduler.add(ClosureSystem("c", phase: .update, order: 1) { _, _ in rec.events.append("c") })
        scheduler.run(.update, context: makeContext())
        XCTAssertEqual(rec.events, ["a", "c", "b"])
    }

    // Running one phase executes only the systems registered for that phase.
    func testRunOnlyExecutesRequestedPhase() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        let rec = RunRecorder()
        scheduler.add(ClosureSystem("update", phase: .update) { _, _ in rec.events.append("update") })
        scheduler.add(ClosureSystem("late", phase: .lateUpdate) { _, _ in rec.events.append("late") })
        scheduler.run(.update, context: makeContext())
        XCTAssertEqual(rec.events, ["update"])
    }

    // In edit mode only systems that opt in with runsInEditMode execute.
    func testEditModeSkipsGameplaySystems() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        let rec = RunRecorder()
        scheduler.add(ClosureSystem("play", phase: .update, runsInEditMode: false) { _, _ in rec.events.append("play") })
        scheduler.add(ClosureSystem("edit", phase: .update, runsInEditMode: true) { _, _ in rec.events.append("edit") })
        scheduler.run(.update, context: makeContext(editMode: true))
        XCTAssertEqual(rec.events, ["edit"])
    }

    // A disabled system is skipped until it is enabled again.
    func testDisabledSystemIsSkipped() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        let rec = RunRecorder()
        let system = ClosureSystem("toggle", phase: .update) { _, _ in rec.events.append("toggle") }
        scheduler.add(system)
        system.isEnabled = false
        scheduler.run(.update, context: makeContext())
        XCTAssertTrue(rec.events.isEmpty)
        system.isEnabled = true
        scheduler.run(.update, context: makeContext())
        XCTAssertEqual(rec.events, ["toggle"])
    }

    // A removed system no longer runs.
    func testRemovedSystemDoesNotRun() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        let rec = RunRecorder()
        let system = ClosureSystem("gone", phase: .update) { _, _ in rec.events.append("gone") }
        scheduler.add(system)
        scheduler.remove(system)
        scheduler.run(.update, context: makeContext())
        XCTAssertTrue(rec.events.isEmpty)
    }

    // Systems are attached when added to a scheduler and detached when removed.
    func testAttachAndDetachHooksFire() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        let probe = AttachProbe()
        scheduler.add(probe)
        XCTAssertTrue(probe.attached)
        XCTAssertFalse(probe.detached)
        scheduler.remove(probe)
        XCTAssertTrue(probe.detached)
    }

    // A system that mutates the world sees its own structural changes applied before the next system runs.
    func testSystemChangesAreFlushedBetweenSystems() {
        let world = World()
        let scheduler = SystemScheduler(world: world)
        var seenByNext = 0
        scheduler.add(ClosureSystem("spawn", phase: .update, order: 0) { world, _ in
            _ = world.createEntity()
        })
        scheduler.add(ClosureSystem("count", phase: .update, order: 1) { world, _ in
            seenByNext = world.entityCount
        })
        scheduler.run(.update, context: makeContext())
        XCTAssertEqual(seenByNext, 1)
    }
}

final class SceneManagerTests: XCTestCase {
    // Loading a document tags each created entity with the new scene and makes it active.
    func testLoadTagsEntitiesAndActivatesScene() throws {
        let world = World()
        let manager = SceneManager(world: world)
        let handle = try manager.load(document: makeDocument(name: "A", count: 2))
        let members = world.entities(with: SceneMember.self)
        XCTAssertEqual(members.count, 2)
        for e in members {
            XCTAssertEqual(world.get(SceneMember.self, e)?.scene, handle)
        }
        XCTAssertEqual(manager.activeScene, handle)
        XCTAssertEqual(manager.loaded.map(\.name), ["A"])
    }

    // Single mode unloads the current scene before loading the new one.
    func testSingleModeReplacesCurrentScene() throws {
        let world = World()
        let manager = SceneManager(world: world)
        try manager.load(document: makeDocument(name: "A", count: 2))
        try manager.load(document: makeDocument(name: "B", count: 1))
        XCTAssertEqual(world.entityCount, 1)
        XCTAssertEqual(manager.loaded.map(\.name), ["B"])
    }

    // Additive mode keeps the existing scene loaded alongside the new one.
    func testAdditiveModeKeepsExistingScene() throws {
        let world = World()
        let manager = SceneManager(world: world)
        try manager.load(document: makeDocument(name: "A", count: 2))
        try manager.load(document: makeDocument(name: "B", count: 1), mode: .additive)
        XCTAssertEqual(world.entityCount, 3)
        XCTAssertEqual(manager.loaded.count, 2)
    }

    // Unloading a scene destroys its entities and clears it from the loaded list.
    func testUnloadDestroysSceneEntities() throws {
        let world = World()
        let manager = SceneManager(world: world)
        let handle = try manager.load(document: makeDocument(name: "A", count: 2))
        manager.unload(handle)
        XCTAssertEqual(world.entityCount, 0)
        XCTAssertTrue(manager.loaded.isEmpty)
        XCTAssertNil(manager.activeScene)
    }

    // Entities marked PersistAcrossScenes survive unloading their scene.
    func testPersistAcrossScenesSurvivesUnload() throws {
        let world = World()
        let manager = SceneManager(world: world)
        let handle = try manager.load(document: makeDocument(name: "A", count: 2))
        let persistent = try XCTUnwrap(world.entities(with: SceneMember.self).first)
        world.add(PersistAcrossScenes(), to: persistent)
        manager.unload(handle)
        XCTAssertTrue(world.isAlive(persistent))
        XCTAssertEqual(world.entityCount, 1)
    }

    // A scene registered by name loads through its provider, and an unknown name throws.
    func testLoadByRegisteredName() throws {
        let world = World()
        let manager = SceneManager(world: world)
        manager.register("Level1") { makeDocument(name: "L", count: 1) }
        try manager.load("Level1")
        XCTAssertEqual(manager.loaded.map(\.name), ["L"])
        XCTAssertThrowsError(try manager.load("Missing"))
    }

    // A zero-duration transition loads the target scene immediately.
    func testZeroDurationTransitionLoadsImmediately() {
        let world = World()
        let manager = SceneManager(world: world)
        manager.register("B") { makeDocument(name: "B", count: 1) }
        manager.transition(to: "B", transition: .none)
        XCTAssertEqual(manager.loaded.map(\.name), ["B"])
        XCTAssertFalse(manager.isTransitioning)
    }

    // A timed transition swaps scenes at the midpoint and fades out by the end.
    func testTimedTransitionSwapsAtMidpoint() {
        let world = World()
        let manager = SceneManager(world: world)
        manager.register("B") { makeDocument(name: "B", count: 1) }
        manager.transition(to: "B", transition: SceneTransition(duration: 1))
        XCTAssertTrue(manager.isTransitioning)
        XCTAssertTrue(manager.loaded.isEmpty)

        manager.update(dt: 0.6)
        XCTAssertEqual(manager.loaded.map(\.name), ["B"])
        XCTAssertTrue(manager.isTransitioning)
        XCTAssertEqual(manager.fadeAlpha, 0.8, accuracy: 1e-5)

        manager.update(dt: 0.5)
        XCTAssertFalse(manager.isTransitioning)
        XCTAssertEqual(manager.fadeAlpha, 0, accuracy: 1e-6)
    }

    // Saving a loaded scene produces a document with its entities and name.
    func testSaveProducesDocumentForScene() throws {
        let world = World()
        let manager = SceneManager(world: world)
        let handle = try manager.load(document: makeDocument(name: "A", count: 2))
        let doc = try manager.save(handle)
        XCTAssertEqual(doc.name, "A")
        XCTAssertEqual(doc.entities.count, 2)
    }

    // Load and unload notifications fire with the affected scene handle.
    func testLoadAndUnloadCallbacksFire() throws {
        let world = World()
        let manager = SceneManager(world: world)
        var loadedHandles: [SceneHandle] = []
        var unloadedHandles: [SceneHandle] = []
        manager.onSceneLoaded = { loadedHandles.append($0) }
        manager.onSceneUnloaded = { unloadedHandles.append($0) }
        let handle = try manager.load(document: makeDocument(name: "A", count: 1))
        manager.unload(handle)
        XCTAssertEqual(loadedHandles, [handle])
        XCTAssertEqual(unloadedHandles, [handle])
    }
}
