/// Tests for the ECS `World` in FeroxScene: entity lifetime and generational slot reuse,
/// component add/get/set/modify/remove, typed iteration (`forEach`), deferral of structural
/// changes made during iteration, resources, and the structure-version counter.
import FeroxCore
import XCTest
@testable import FeroxScene

private struct TestHealth: Component, Equatable {
    var hp: Int
}

private struct TestVelocity: Component, Equatable {
    var dx: Float
}

private struct TestMarker: Component {}

private struct TestGravity {
    var g: Float
}

private struct TestScore {
    var value: Int
}

final class WorldEntityTests: XCTestCase {
    // A newly created entity is alive and counted.
    func testCreatedEntityIsAliveAndCounted() {
        let world = World()
        let e = world.createEntity()
        XCTAssertTrue(world.isAlive(e))
        XCTAssertEqual(world.entityCount, 1)
        XCTAssertEqual(world.entities, [e])
    }

    // Destroying an entity makes it dead and removes it from the live list.
    func testDestroyedEntityIsDead() {
        let world = World()
        let e = world.createEntity()
        world.destroy(e)
        XCTAssertFalse(world.isAlive(e))
        XCTAssertEqual(world.entityCount, 0)
        XCTAssertTrue(world.entities.isEmpty)
    }

    // A recycled slot gets a new generation, so the old handle stays dead.
    func testRecycledSlotGetsNewGeneration() {
        let world = World()
        let first = world.createEntity()
        world.destroy(first)
        let second = world.createEntity()
        XCTAssertEqual(second.index, first.index)
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertFalse(world.isAlive(first))
        XCTAssertTrue(world.isAlive(second))
    }

    // A stale handle cannot see components added to the entity that reused its slot.
    func testStaleHandleDoesNotSeeReplacementComponents() {
        let world = World()
        let first = world.createEntity()
        world.add(TestHealth(hp: 5), to: first)
        world.destroy(first)
        let second = world.createEntity()
        world.add(TestHealth(hp: 9), to: second)
        XCTAssertNil(world.get(TestHealth.self, first))
        XCTAssertFalse(world.has(TestHealth.self, first))
        XCTAssertEqual(world.get(TestHealth.self, second)?.hp, 9)
    }

    // The null entity is never alive.
    func testNullEntityIsNotAlive() {
        let world = World()
        XCTAssertFalse(world.isAlive(.null))
        XCTAssertTrue(Entity.null.isNull)
    }

    // The entity lifecycle callbacks fire on creation and destruction.
    func testLifecycleCallbacksFire() {
        let world = World()
        var created = 0
        var destroyed = 0
        world.onEntityCreated = { _ in created += 1 }
        world.onEntityDestroyed = { _ in destroyed += 1 }
        let e = world.createEntity()
        world.destroy(e)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(destroyed, 1)
    }

    // createEntity(named:) attaches a Name and a Transform to the new entity.
    func testNamedEntityHasNameAndTransform() {
        let world = World()
        let e = world.createEntity(named: "Hero", transform: Transform(position: Vec3(1, 0, 0)))
        XCTAssertEqual(world.get(Name.self, e)?.value, "Hero")
        XCTAssertEqual(world.get(Transform.self, e)?.position, Vec3(1, 0, 0))
    }

    // clear destroys every entity and component but keeps resources.
    func testClearKeepsResources() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 1), to: e)
        world.setResource(TestScore(value: 3))
        world.clear()
        XCTAssertFalse(world.isAlive(e))
        XCTAssertEqual(world.entityCount, 0)
        XCTAssertEqual(world.resource(TestScore.self)?.value, 3)
    }
}

final class WorldComponentTests: XCTestCase {
    // Components can be added, read, checked and removed.
    func testAddGetHasRemove() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 4), to: e)
        XCTAssertTrue(world.has(TestHealth.self, e))
        XCTAssertEqual(world.get(TestHealth.self, e), TestHealth(hp: 4))
        world.remove(TestHealth.self, from: e)
        XCTAssertFalse(world.has(TestHealth.self, e))
        XCTAssertNil(world.get(TestHealth.self, e))
    }

    // set only replaces an existing component and reports whether it did.
    func testSetOnlyReplacesExistingComponents() {
        let world = World()
        let e = world.createEntity()
        XCTAssertFalse(world.set(TestHealth(hp: 2), for: e))
        world.add(TestHealth(hp: 1), to: e)
        XCTAssertTrue(world.set(TestHealth(hp: 2), for: e))
        XCTAssertEqual(world.get(TestHealth.self, e)?.hp, 2)
    }

    // modify mutates a component in place and returns nil for an entity without it.
    func testModifyMutatesInPlace() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 1), to: e)
        world.modify(TestHealth.self, e) { $0.hp += 10 }
        XCTAssertEqual(world.get(TestHealth.self, e)?.hp, 11)
        XCTAssertNil(world.modify(TestHealth.self, world.createEntity()) { _ in })
    }

    // The subscript reads a component, writes a new one, and removes it when assigned nil.
    func testSubscriptGetSetRemove() {
        let world = World()
        let e = world.createEntity()
        world[TestHealth.self, e] = TestHealth(hp: 4)
        XCTAssertEqual(world[TestHealth.self, e]?.hp, 4)
        world[TestHealth.self, e] = nil
        XCTAssertFalse(world.has(TestHealth.self, e))
    }

    // Adding a component that is already present replaces it without changing the entity count.
    func testAddReplacesExistingComponent() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 1), to: e)
        world.add(TestHealth(hp: 8), to: e)
        XCTAssertEqual(world.get(TestHealth.self, e)?.hp, 8)
        XCTAssertEqual(world.count(of: TestHealth.self), 1)
    }

    // Adding a component to a destroyed entity is ignored.
    func testAddToDeadEntityIsIgnored() {
        let world = World()
        let e = world.createEntity()
        world.destroy(e)
        world.add(TestHealth(hp: 1), to: e)
        XCTAssertEqual(world.count(of: TestHealth.self), 0)
    }

    // Set does not count as a structural change, while adding a new component does.
    func testStructureVersionTracksStructuralChangesOnly() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 1), to: e)
        let before = world.structureVersion
        world.set(TestHealth(hp: 2), for: e)
        XCTAssertEqual(world.structureVersion, before)
        world.add(TestVelocity(dx: 1), to: e)
        XCTAssertGreaterThan(world.structureVersion, before)
    }
}

final class WorldIterationTests: XCTestCase {
    // A single-component forEach visits every entity with that component and writes changes back.
    func testForEachSingleComponentWritesBack() {
        let world = World()
        for hp in [1, 2, 3] {
            world.add(TestHealth(hp: hp), to: world.createEntity())
        }
        world.forEach(TestHealth.self) { _, h in h.hp *= 2 }
        var total = 0
        world.read(TestHealth.self) { _, h in total += h.hp }
        XCTAssertEqual(total, 12)
    }

    // A two-component forEach visits only entities that have both components.
    func testForEachPairVisitsIntersectionOnly() {
        let world = World()
        let both = world.createEntity()
        world.add(TestHealth(hp: 1), to: both)
        world.add(TestVelocity(dx: 1), to: both)
        let healthOnly = world.createEntity()
        world.add(TestHealth(hp: 1), to: healthOnly)
        let velocityOnly = world.createEntity()
        world.add(TestVelocity(dx: 1), to: velocityOnly)
        var visited: [Entity] = []
        world.forEach(TestHealth.self, TestVelocity.self) { e, h, v in
            visited.append(e)
            h.hp = 99
            v.dx = 7
        }
        XCTAssertEqual(visited, [both])
        XCTAssertEqual(world.get(TestHealth.self, both)?.hp, 99)
        XCTAssertEqual(world.get(TestVelocity.self, both)?.dx, 7)
    }

    // A three-component forEach visits only entities carrying all three components.
    func testForEachTripleVisitsIntersectionOnly() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 1), to: e)
        world.add(TestVelocity(dx: 1), to: e)
        world.add(TestMarker(), to: e)
        let partial = world.createEntity()
        world.add(TestHealth(hp: 1), to: partial)
        world.add(TestVelocity(dx: 1), to: partial)
        var count = 0
        world.forEach(TestHealth.self, TestVelocity.self, TestMarker.self) { _, _, _, _ in count += 1 }
        XCTAssertEqual(count, 1)
    }

    // Structural additions made during a query are deferred until the query returns.
    func testStructuralAddDuringIterationIsDeferred() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 1), to: e)
        var visibleInside = true
        world.forEach(TestHealth.self) { entity, _ in
            world.add(TestMarker(), to: entity)
            visibleInside = world.has(TestMarker.self, entity)
        }
        XCTAssertFalse(visibleInside)
        XCTAssertTrue(world.has(TestMarker.self, e))
    }

    // Destroying an entity during a query is deferred, so it stays alive until the query returns.
    func testDestroyDuringIterationIsDeferred() {
        let world = World()
        let target = world.createEntity()
        world.add(TestHealth(hp: 1), to: target)
        let actor = world.createEntity()
        world.add(TestHealth(hp: 1), to: actor)
        var targetAliveInside = false
        world.forEach(TestHealth.self) { entity, _ in
            if entity == actor {
                world.destroy(target)
                targetAliveInside = world.isAlive(target)
            }
        }
        XCTAssertTrue(targetAliveInside)
        XCTAssertFalse(world.isAlive(target))
    }

    // flushDeferred does nothing while a query is running, so deferred work waits for the query to finish.
    func testFlushDeferredIsNoOpDuringIteration() {
        let world = World()
        let e = world.createEntity()
        world.add(TestHealth(hp: 1), to: e)
        var ran = false
        world.forEach(TestHealth.self) { _, _ in
            world.deferStructural { ran = true }
            world.flushDeferred()
            XCTAssertFalse(ran)
        }
        XCTAssertTrue(ran)
    }

    // deferStructural runs its operation immediately when no query is active.
    func testDeferStructuralRunsImmediatelyOutsideIteration() {
        let world = World()
        var ran = false
        world.deferStructural { ran = true }
        XCTAssertTrue(ran)
        XCTAssertFalse(world.isIterating)
    }

    // entities(with:) and count(of:) report the entities holding a component type.
    func testEntitiesWithComponentAndCount() {
        let world = World()
        let a = world.createEntity()
        world.add(TestMarker(), to: a)
        _ = world.createEntity()
        XCTAssertEqual(world.entities(with: TestMarker.self), [a])
        XCTAssertEqual(world.count(of: TestMarker.self), 1)
    }
}

final class WorldResourceTests: XCTestCase {
    // Resources are stored per type, can be replaced, and can be removed.
    func testResourcesAreTypedSingletons() {
        let world = World()
        XCTAssertNil(world.resource(TestGravity.self))
        world.setResource(TestGravity(g: 9.8))
        XCTAssertEqual(world.resource(TestGravity.self)?.g ?? 0, 9.8, accuracy: 1e-5)
        world.setResource(TestGravity(g: 1.6))
        XCTAssertEqual(world.resource(TestGravity.self)?.g ?? 0, 1.6, accuracy: 1e-5)
        world.removeResource(TestGravity.self)
        XCTAssertNil(world.resource(TestGravity.self))
    }
}
