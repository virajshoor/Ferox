import FeroxCore
/// Tests for the ECS bridge: PhysicsSystem2D creates and removes bodies to match entities, writes
/// poses back to Transform, interpolates for rendering and publishes CollisionEvent2D on the EventBus.
import XCTest

@testable import FeroxPhysics
@testable import FeroxScene

final class PhysicsSystemTests: XCTestCase {

    private let dt: Float = 1.0 / 60.0

    /// Scheduler with a fresh PhysicsSystem2D attached to `world`.
    private func makeScheduler(_ world: World) -> (SystemScheduler, PhysicsSystem2D) {
        let scheduler = SystemScheduler(world: world)
        let system = PhysicsSystem2D()
        scheduler.add(system)
        return (scheduler, system)
    }

    /// Runs the fixed-update phase `steps` times, flushing the event bus after each step.
    private func fixedUpdate(_ scheduler: SystemScheduler, events: EventBus, steps: Int = 1) {
        for _ in 0..<steps {
            scheduler.run(.fixedUpdate, context: SystemContext(time: FrameTime(), dt: dt, events: events))
            events.flush()
        }
    }

    /// Creates an entity with a Transform, an optional RigidBody2D and a 1 x 1 (or given size) box collider.
    @discardableResult
    private func spawnEntity(_ world: World, at p: Vec3, rigidBody: RigidBody2D?, size: Vec2 = Vec2(1, 1)) -> Entity {
        let e = world.createEntity()
        world.add(Transform(position: p), to: e)
        if let rigidBody { world.add(rigidBody, to: e) }
        world.add(Collider2D.box(size), to: e)
        return e
    }

    /// Static floor entity (no RigidBody2D) whose top surface sits at y = 0.5.
    @discardableResult
    private func spawnGround(_ world: World) -> Entity {
        spawnEntity(world, at: .zero, rigidBody: nil, size: Vec2(100, 1))
    }

    /// An entity with a RigidBody2D and Collider2D gets a dynamic body after a fixed update.
    func testFixedUpdateCreatesDynamicBodyForEntity() throws {
        let world = World()
        let (scheduler, system) = makeScheduler(world)
        let box = spawnEntity(world, at: Vec3(0, 5, 0), rigidBody: RigidBody2D(type: .dynamic))
        fixedUpdate(scheduler, events: EventBus())
        let id = try XCTUnwrap(system.body(for: box))
        XCTAssertEqual(try XCTUnwrap(system.physics.body(id)).type, .dynamic)
        XCTAssertEqual(system.physics.bodyCount, 1)
    }

    /// A Collider2D without a RigidBody2D becomes a static body.
    func testColliderWithoutRigidBodyBecomesStaticBody() throws {
        let world = World()
        let (scheduler, system) = makeScheduler(world)
        let ground = spawnGround(world)
        fixedUpdate(scheduler, events: EventBus())
        let id = try XCTUnwrap(system.body(for: ground))
        XCTAssertEqual(try XCTUnwrap(system.physics.body(id)).type, .static)
    }

    /// The RigidBody2D initial velocity is applied to the body when it is created.
    func testInitialVelocityIsAppliedOnCreation() throws {
        let world = World()
        let (scheduler, system) = makeScheduler(world)
        var rb = RigidBody2D(type: .dynamic)
        rb.initialVelocity = Vec2(3, 0)
        rb.gravityScale = 0
        let box = spawnEntity(world, at: Vec3(0, 5, 0), rigidBody: rb)
        fixedUpdate(scheduler, events: EventBus())
        let id = try XCTUnwrap(system.body(for: box))
        XCTAssertEqual(try XCTUnwrap(system.physics.body(id)).linearVelocity.x, 3, accuracy: 1e-3)
    }

    /// A dynamic entity dropped onto a static collider rests on it, and its Transform follows the body.
    func testDynamicEntityRestsOnStaticColliderAndWritesBackTransform() throws {
        let world = World()
        let (scheduler, _) = makeScheduler(world)
        spawnGround(world)
        let box = spawnEntity(world, at: Vec3(0, 5, 0), rigidBody: RigidBody2D(type: .dynamic))
        fixedUpdate(scheduler, events: EventBus(), steps: 120)
        let transform = try XCTUnwrap(world.get(Transform.self, box))
        XCTAssertEqual(transform.position.x, 0, accuracy: 0.05)
        XCTAssertEqual(transform.position.y, 1.0, accuracy: 0.05)
    }

    /// Destroying an entity removes its body from the physics world.
    func testDestroyingEntityRemovesBody() throws {
        let world = World()
        let (scheduler, system) = makeScheduler(world)
        let box = spawnEntity(world, at: Vec3(0, 5, 0), rigidBody: RigidBody2D(type: .dynamic))
        fixedUpdate(scheduler, events: EventBus())
        let id = try XCTUnwrap(system.body(for: box))

        world.destroy(box)
        fixedUpdate(scheduler, events: EventBus())
        XCTAssertNil(system.body(for: box))
        XCTAssertFalse(system.physics.isValid(id))
        XCTAssertEqual(system.physics.bodyCount, 0)
    }

    /// Removing both physics components from a live entity removes its body but keeps the entity.
    func testRemovingPhysicsComponentsRemovesBody() throws {
        let world = World()
        let (scheduler, system) = makeScheduler(world)
        let box = spawnEntity(world, at: Vec3(0, 5, 0), rigidBody: RigidBody2D(type: .dynamic))
        fixedUpdate(scheduler, events: EventBus())
        XCTAssertNotNil(system.body(for: box))

        world.remove(RigidBody2D.self, from: box)
        world.remove(Collider2D.self, from: box)
        fixedUpdate(scheduler, events: EventBus())
        XCTAssertNil(system.body(for: box))
        XCTAssertTrue(world.isAlive(box))
        XCTAssertFalse(world.has(PhysicsBody2DHandle.self, box))
    }

    /// A landing publishes a began CollisionEvent2D that names the entities involved.
    func testLandingPublishesBeganEventOnEventBus() throws {
        let world = World()
        let (scheduler, _) = makeScheduler(world)
        let ground = spawnGround(world)
        let box = spawnEntity(world, at: Vec3(0, 5, 0), rigidBody: RigidBody2D(type: .dynamic))
        let bus = EventBus()
        var began: [CollisionEvent2D] = []
        _ = bus.subscribe(CollisionEvent2D.self) { event in
            if event.phase == .began { began.append(event) }
        }
        fixedUpdate(scheduler, events: bus, steps: 120)
        let contact = try XCTUnwrap(began.first { $0.involves(box) })
        XCTAssertEqual(contact.other(than: box), ground)
        XCTAssertFalse(contact.isTrigger)
    }

    /// Teleporting a body away from its contact publishes an ended CollisionEvent2D.
    func testTeleportingAwayPublishesEndedEvent() {
        let world = World()
        let (scheduler, _) = makeScheduler(world)
        spawnGround(world)
        let box = spawnEntity(world, at: Vec3(0, 5, 0), rigidBody: RigidBody2D(type: .dynamic))
        let bus = EventBus()
        var phases: [ContactEvent<Vec2>.Phase] = []
        _ = bus.subscribe(CollisionEvent2D.self) { phases.append($0.phase) }
        fixedUpdate(scheduler, events: bus, steps: 120)
        XCTAssertTrue(phases.contains(.began))

        _ = world.set(Transform(position: Vec3(0, 20, 0)), for: box)
        fixedUpdate(scheduler, events: bus)
        XCTAssertTrue(phases.contains(.ended))
    }

    /// interpolate writes poses between the last two fixed steps, so alpha 0 gives the previous pose and alpha 1 the current one.
    func testInterpolateBlendsBetweenFixedSteps() throws {
        let world = World()
        let (scheduler, system) = makeScheduler(world)
        let box = spawnEntity(world, at: Vec3(0, 10, 0), rigidBody: RigidBody2D(type: .dynamic))
        fixedUpdate(scheduler, events: EventBus())
        let body = try XCTUnwrap(system.physics.body(try XCTUnwrap(system.body(for: box))))

        system.interpolate(world, alpha: 0)
        XCTAssertEqual(try XCTUnwrap(world.get(Transform.self, box)).position.y, 10, accuracy: 1e-3)

        system.interpolate(world, alpha: 1)
        XCTAssertEqual(try XCTUnwrap(world.get(Transform.self, box)).position.y, body.position.y, accuracy: 1e-3)
    }
}
