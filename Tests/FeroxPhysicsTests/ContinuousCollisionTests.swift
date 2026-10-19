import FeroxCore
/// Tests for continuous collision: fast dynamic bodies must not tunnel through thin static walls.
import XCTest

@testable import FeroxPhysics

final class ContinuousCollisionTests: XCTestCase {
    // A 0.1 m sphere at 180 m/s moves 3 m per 60 Hz step, far more than the 0.1 m wall.
    func run3D(continuous: Bool) -> Float {
        let world = PhysicsWorld3D(gravity: .zero)
        world.settings.continuousCollision = continuous
        world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [.box(Vec3(2, 2, 0.05))]))
        var desc = BodyDesc3D(type: .dynamic, position: Vec3(0, 0, 5), shapes: [.sphere(0.1)])
        desc.linearVelocity = Vec3(0, 0, -180)
        let ball = world.createBody(desc)
        for _ in 0..<30 { world.step(1.0 / 60) }
        return world.body(ball)!.position.z
    }

    func testFastSphereDoesNotTunnelThroughThinWall() {
        XCTAssertLessThan(run3D(continuous: false), -1, "without CCD the sphere should tunnel (test setup check)")
        XCTAssertGreaterThan(run3D(continuous: true), 0, "with CCD the sphere must stay in front of the wall")
    }

    func run2D(continuous: Bool) -> Float {
        let world = PhysicsWorld2D(gravity: .zero)
        world.settings.continuousCollision = continuous
        world.createBody(BodyDesc2D(type: .static, position: .zero, shapes: [.box(halfExtents: Vec2(0.05, 2))]))
        var desc = BodyDesc2D(type: .dynamic, position: Vec2(5, 0), shapes: [.circle(radius: 0.1)])
        desc.linearVelocity = Vec2(-180, 0)
        let ball = world.createBody(desc)
        for _ in 0..<30 { world.step(1.0 / 60) }
        return world.body(ball)!.position.x
    }

    func testFastCircleDoesNotTunnelThroughThinWall() {
        XCTAssertLessThan(run2D(continuous: false), -1, "without CCD the circle should tunnel (test setup check)")
        XCTAssertGreaterThan(run2D(continuous: true), 0, "with CCD the circle must stay in front of the wall")
    }

    // A slow body resting on the ground is unaffected: CCD only engages above the core size.
    func testRestingBodyIsUnaffected() {
        let world = PhysicsWorld3D()
        world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [.box(Vec3(10, 0.5, 10))]))
        let box = world.createBody(
            BodyDesc3D(type: .dynamic, position: Vec3(0, 1, 0), shapes: [.box(Vec3(0.5, 0.5, 0.5))]))
        world.setLinearVelocity(box, Vec3(3, 0, 0))
        for _ in 0..<30 { world.step(1.0 / 60) }
        XCTAssertGreaterThan(world.body(box)!.position.x, 0.5, "sliding must not be stopped by the floor")
    }
}
