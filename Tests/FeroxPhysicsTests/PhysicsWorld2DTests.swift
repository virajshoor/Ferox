import FeroxCore
/// Behavioural tests for the 2D rigid-body world: integration, contact response, triggers,
/// sleeping, raycasts, collision filters, contact manifolds and body lifetime.
import XCTest

@testable import FeroxPhysics

final class PhysicsWorld2DTests: XCTestCase {

    private let dt: Float = 1.0 / 60.0

    /// Steps the world for roughly `seconds` at the fixed 1/60 step.
    private func advance(_ world: PhysicsWorld2D, seconds: Float) {
        let steps = Int((seconds / dt).rounded())
        for _ in 0..<steps { world.step(dt) }
    }

    /// Static floor whose top surface sits at y = 0.5.
    @discardableResult
    private func makeGround(_ world: PhysicsWorld2D, filter: CollisionFilter = .default, isTrigger: Bool = false)
        -> BodyID
    {
        var shape = Shape2D.box(halfExtents: Vec2(50, 0.5))
        shape.filter = filter
        shape.isTrigger = isTrigger
        return world.createBody(BodyDesc2D(type: .static, position: .zero, shapes: [shape]))
    }

    /// Unit-sized box (half extents 0.5) with the given physical properties.
    private func makeBox(
        _ world: PhysicsWorld2D, at p: Vec2, material: PhysicsMaterial = .default,
        filter: CollisionFilter = .default, allowSleep: Bool = true
    ) -> BodyID {
        var shape = Shape2D.box(halfExtents: Vec2(0.5, 0.5))
        shape.material = material
        shape.filter = filter
        var desc = BodyDesc2D(type: .dynamic, position: p, shapes: [shape])
        desc.allowSleep = allowSleep
        return world.createBody(desc)
    }

    /// Gravity alone accelerates an unobstructed body at 9.81 m/s^2.
    func testFreeFallAccumulatesGravity() throws {
        let world = PhysicsWorld2D()
        let box = makeBox(world, at: Vec2(0, 100))
        advance(world, seconds: 1)
        let body = try XCTUnwrap(world.body(box))
        XCTAssertEqual(body.linearVelocity.y, -9.81, accuracy: 0.05)
        XCTAssertEqual(body.linearVelocity.x, 0, accuracy: 1e-4)
    }

    /// A dynamic box dropped onto a static floor settles with its bottom face on the floor.
    func testBoxComesToRestOnStaticGround() throws {
        let world = PhysicsWorld2D()
        makeGround(world)
        let box = makeBox(world, at: Vec2(0, 5))
        advance(world, seconds: 2)
        let body = try XCTUnwrap(world.body(box))
        XCTAssertEqual(body.position.x, 0, accuracy: 0.05)
        XCTAssertEqual(body.position.y, 1.0, accuracy: 0.05)
        XCTAssertEqual(body.linearVelocity.y, 0, accuracy: 0.1)
        XCTAssertGreaterThan(world.activeContactCount, 0)
    }

    /// A bouncy box leaves the floor with upward speed after its first impact.
    func testRestitutionProducesRebound() throws {
        let world = PhysicsWorld2D()
        makeGround(world)
        let box = makeBox(world, at: Vec2(0, 3), material: PhysicsMaterial(friction: 0.5, restitution: 0.8))
        var descended = false
        var rebounded = false
        for _ in 0..<180 {
            world.step(dt)
            let vy = try XCTUnwrap(world.body(box)).linearVelocity.y
            if vy < -2 { descended = true }
            if descended && vy > 1 { rebounded = true }
        }
        XCTAssertTrue(rebounded)
    }

    /// A trigger reports overlap events and does not stop the body that passes through it.
    func testTriggerReportsOverlapWithoutContactResponse() throws {
        let world = PhysicsWorld2D()
        makeGround(world, isTrigger: true)
        let box = makeBox(world, at: Vec2(0, 5))
        var events: [ContactEvent<Vec2>] = []
        world.onContact = { events.append($0) }
        advance(world, seconds: 2)
        XCTAssertLessThan(try XCTUnwrap(world.body(box)).position.y, 0)
        XCTAssertTrue(events.contains { $0.isTrigger && $0.phase == .began })
        XCTAssertTrue(events.filter(\.isTrigger).allSatisfy { $0.points.isEmpty })
    }

    /// A ray from the left hits the near face of a static box with the expected point, normal and distance.
    func testRaycastHitsNearFaceOfBox() throws {
        let world = PhysicsWorld2D()
        let box = world.createBody(
            BodyDesc2D(type: .static, position: .zero, shapes: [Shape2D.box(halfExtents: Vec2(1, 1))]))
        let hit = try XCTUnwrap(world.raycast(from: Vec2(-5, 0), to: Vec2(5, 0)))
        XCTAssertEqual(hit.body, box)
        XCTAssertEqual(hit.point.x, -1, accuracy: 1e-3)
        XCTAssertEqual(hit.normal.x, -1, accuracy: 1e-3)
        XCTAssertEqual(hit.distance, 4, accuracy: 1e-3)
    }

    /// Rays that pass above the box, or end before reaching it, report no hit.
    func testRaycastMissesWhenPassingAboveOrStoppingShort() {
        let world = PhysicsWorld2D()
        world.createBody(BodyDesc2D(type: .static, position: .zero, shapes: [Shape2D.box(halfExtents: Vec2(1, 1))]))
        XCTAssertNil(world.raycast(from: Vec2(-5, 3), to: Vec2(5, 3)))
        XCTAssertNil(world.raycast(from: Vec2(-5, 0), to: Vec2(-2, 0)))
    }

    /// setTransform teleports a body and, with resetInterpolation, also resets its previous pose.
    func testSetTransformTeleportsBodyAndResetsInterpolation() throws {
        let world = PhysicsWorld2D(gravity: .zero)
        let box = makeBox(world, at: .zero)
        world.setTransform(box, position: Vec2(3, 4), angle: 0.5, resetInterpolation: true)
        let body = try XCTUnwrap(world.body(box))
        XCTAssertEqual(body.position.x, 3, accuracy: 1e-5)
        XCTAssertEqual(body.position.y, 4, accuracy: 1e-5)
        XCTAssertEqual(body.angle, 0.5, accuracy: 1e-5)
        XCTAssertEqual(body.previousPosition.x, 3, accuracy: 1e-5)
        XCTAssertEqual(body.previousPosition.y, 4, accuracy: 1e-5)
    }

    /// A velocity set through the world integrates into position when no forces act.
    func testSetLinearVelocityIntegratesPosition() throws {
        let world = PhysicsWorld2D(gravity: .zero)
        let box = makeBox(world, at: .zero)
        world.setLinearVelocity(box, Vec2(2, 0))
        advance(world, seconds: 1)
        let body = try XCTUnwrap(world.body(box))
        XCTAssertEqual(body.position.x, 2, accuracy: 0.05)
        XCTAssertEqual(body.position.y, 0, accuracy: 0.05)
    }

    /// A resting body falls asleep after its time-to-sleep, while a body with allowSleep false stays awake.
    func testRestingBodySleepsOnlyWhenAllowed() throws {
        let world = PhysicsWorld2D()
        makeGround(world)
        let sleeper = makeBox(world, at: Vec2(-5, 5))
        let staying = makeBox(world, at: Vec2(5, 5), allowSleep: false)
        advance(world, seconds: 3)
        XCTAssertFalse(try XCTUnwrap(world.body(sleeper)).isAwake)
        XCTAssertTrue(try XCTUnwrap(world.body(staying)).isAwake)
    }

    /// A mask that excludes the floor's category lets the body fall through it.
    func testCollisionFilterMaskSeparatesBodies() throws {
        let world = PhysicsWorld2D()
        makeGround(world)
        let box = makeBox(world, at: Vec2(0, 5), filter: CollisionFilter(category: 2, mask: 2))
        advance(world, seconds: 2)
        XCTAssertLessThan(try XCTUnwrap(world.body(box)).position.y, -1)
    }

    /// A shared positive group collides regardless of masks, while a shared negative group never collides.
    func testSharedCollisionGroupOverridesMask() throws {
        let positive = PhysicsWorld2D()
        makeGround(positive, filter: CollisionFilter(category: 1, mask: 0, group: 1))
        let boxP = makeBox(positive, at: Vec2(0, 5), filter: CollisionFilter(category: 2, mask: 0, group: 1))
        advance(positive, seconds: 2)
        XCTAssertEqual(try XCTUnwrap(positive.body(boxP)).position.y, 1.0, accuracy: 0.05)

        let negative = PhysicsWorld2D()
        makeGround(negative, filter: CollisionFilter(category: 1, mask: .max, group: -1))
        let boxN = makeBox(negative, at: Vec2(0, 5), filter: CollisionFilter(category: 1, mask: .max, group: -1))
        advance(negative, seconds: 2)
        XCTAssertLessThan(try XCTUnwrap(negative.body(boxN)).position.y, -1)
    }

    /// Overlapping circles report a contact whose normal points from the first body to the second.
    func testCircleCircleContactNormalPointsFromAToB() throws {
        let world = PhysicsWorld2D(gravity: .zero)
        let a = world.createBody(
            BodyDesc2D(type: .dynamic, position: .zero, shapes: [Shape2D.circle(radius: 0.5)]))
        let b = world.createBody(
            BodyDesc2D(type: .dynamic, position: Vec2(0.8, 0), shapes: [Shape2D.circle(radius: 0.5)]))
        world.step(dt)
        let contact = try XCTUnwrap(world.contacts(of: a).first)
        XCTAssertEqual(contact.other, b)
        XCTAssertEqual(contact.normal.x, 1, accuracy: 0.01)
        XCTAssertEqual(contact.normal.y, 0, accuracy: 0.01)
        XCTAssertFalse(contact.points.isEmpty)
    }

    /// Overlapping boxes use the axis of least penetration; boxes with a gap report no contact.
    func testBoxBoxContactUsesMinimumPenetrationAxis() throws {
        let world = PhysicsWorld2D(gravity: .zero)
        let a = world.createBody(
            BodyDesc2D(type: .dynamic, position: .zero, shapes: [Shape2D.box(halfExtents: Vec2(0.5, 0.5))]))
        world.createBody(
            BodyDesc2D(type: .dynamic, position: Vec2(0.8, 0.3), shapes: [Shape2D.box(halfExtents: Vec2(0.5, 0.5))]))
        world.step(dt)
        let contact = try XCTUnwrap(world.contacts(of: a).first)
        XCTAssertEqual(contact.normal.x, 1, accuracy: 0.01)
        XCTAssertEqual(contact.normal.y, 0, accuracy: 0.01)

        let separated = PhysicsWorld2D(gravity: .zero)
        let c = separated.createBody(
            BodyDesc2D(type: .dynamic, position: .zero, shapes: [Shape2D.box(halfExtents: Vec2(0.5, 0.5))]))
        separated.createBody(
            BodyDesc2D(type: .dynamic, position: Vec2(1.5, 0), shapes: [Shape2D.box(halfExtents: Vec2(0.5, 0.5))]))
        separated.step(dt)
        XCTAssertTrue(separated.contacts(of: c).isEmpty)
    }

    /// Destroying a body invalidates its id, and a reused slot is issued under a new generation.
    func testDestroyedBodyIDBecomesInvalid() {
        let world = PhysicsWorld2D()
        let first = world.createBody(
            BodyDesc2D(type: .dynamic, position: .zero, shapes: [Shape2D.circle(radius: 0.5)]))
        world.destroyBody(first)
        XCTAssertFalse(world.isValid(first))
        XCTAssertNil(world.body(first))
        XCTAssertEqual(world.bodyCount, 0)

        let second = world.createBody(
            BodyDesc2D(type: .dynamic, position: .zero, shapes: [Shape2D.circle(radius: 0.5)]))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(world.isValid(first))
        XCTAssertTrue(world.isValid(second))
        XCTAssertEqual(world.bodyCount, 1)
    }

    /// A body landing on the floor emits a began event, and teleporting it away emits an ended event.
    func testContactBeganAndEndedEventsAreEmitted() throws {
        let world = PhysicsWorld2D()
        makeGround(world)
        let box = makeBox(world, at: Vec2(0, 5))
        var phases: [ContactEvent<Vec2>.Phase] = []
        world.onContact = { phases.append($0.phase) }
        advance(world, seconds: 2)
        XCTAssertTrue(phases.contains(.began))

        world.setTransform(box, position: Vec2(0, 20), angle: 0, resetInterpolation: true)
        world.step(dt)
        XCTAssertTrue(phases.contains(.ended))
    }
}
