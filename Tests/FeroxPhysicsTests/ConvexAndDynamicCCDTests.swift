import FeroxMath
import XCTest

@testable import FeroxPhysics

final class ConvexHullTests: XCTestCase {
    func boxCorners() -> [Vec3] {
        var points: [Vec3] = []
        for i in 0..<8 {
            let x: Float = (i & 1) == 0 ? -1 : 1
            let y: Float = (i & 2) == 0 ? -1 : 1
            let z: Float = (i & 4) == 0 ? -1 : 1
            points.append(Vec3(x, y, z))
        }
        return points
    }

    func testDegenerateInputIsNil() {
        XCTAssertNil(ConvexHull3D.build([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0)]))
        XCTAssertNil(ConvexHull3D.build([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]))
        XCTAssertNil(Shape3D.convex([Vec3(0, 0, 0), Vec3(1, 1, 1)]))
    }

    func testBoxCornersHaveTheCubeVolume() {
        let hull = ConvexHull3D.build(boxCorners())
        XCTAssertNotNil(hull)
        XCTAssertEqual(hull!.triangleCount, 12)
        XCTAssertEqual(hull!.volume, 8, accuracy: 1e-3)
    }

    func testSphereHitsTheTopFace() {
        let hull = ConvexHull3D.build(boxCorners())!
        let shape = Shape3D(.convex(hull))
        let sphere = Shape3D.sphere(0.5)
        let m = Collide3D.manifold(sphere, Pose3D(position: Vec3(0, 1.2, 0)), shape, Pose3D(), margin: 0)
        XCTAssertFalse(m.points.isEmpty)
        // Normal points from shape A (the sphere) toward shape B (the hull).
        XCTAssertLessThan(m.normal.y, -0.9)
        XCTAssertLessThan(m.points[0].separation, 0)
    }

    func testSeparatedSphereProducesNoContact() {
        let hull = ConvexHull3D.build(boxCorners())!
        let m = Collide3D.manifold(
            Shape3D.sphere(0.5), Pose3D(position: Vec3(0, 3, 0)), Shape3D(.convex(hull)), Pose3D(), margin: 0)
        XCTAssertTrue(m.points.isEmpty)
    }

    func testHullTouchesHull() {
        let hull = ConvexHull3D.build(boxCorners())!
        let a = Shape3D(.convex(hull))
        let b = Shape3D(.convex(hull))
        let m = Collide3D.manifold(a, Pose3D(position: Vec3(0, 1.5, 0)), b, Pose3D(), margin: 0)
        XCTAssertFalse(m.points.isEmpty, "overlapping box hulls must produce a contact")
        XCTAssertLessThan(m.points[0].separation, 0)
    }

    func testRayHitsTheHull() {
        let hull = ConvexHull3D.build(boxCorners())!
        let hit = hull.raycast(origin: Vec3(0, 3, 0), direction: Vec3(0, -1, 0), maxT: 10)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit!.0, 2, accuracy: 1e-3)
        XCTAssertGreaterThan(hit!.1.y, 0.9)
    }

    func testDynamicSphereRestsOnAStaticHull() {
        let world = PhysicsWorld3D(gravity: Vec3(0, -10, 0))
        let hull = Shape3D.convex(boxCorners())!
        world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [hull]))
        let ball = world.createBody(
            BodyDesc3D(type: .dynamic, position: Vec3(0, 3, 0), shapes: [.sphere(0.5)]))
        for _ in 0..<180 { world.step(1.0 / 60) }
        let y = world.body(ball)!.position.y
        XCTAssertGreaterThan(y, 1.3)
        XCTAssertLessThan(y, 1.8)
    }
}

final class DynamicContinuousCollisionTests: XCTestCase {
    func testTwoFastSpheresDoNotTunnel() {
        let world = PhysicsWorld3D(gravity: .zero)
        world.settings.continuousCollision = true
        var left = BodyDesc3D(type: .dynamic, position: Vec3(-3, 0, 0), shapes: [.sphere(0.25)])
        left.linearVelocity = Vec3(40, 0, 0)
        var right = BodyDesc3D(type: .dynamic, position: Vec3(3, 0, 0), shapes: [.sphere(0.25)])
        right.linearVelocity = Vec3(-40, 0, 0)
        let a = world.createBody(left)
        let b = world.createBody(right)
        for _ in 0..<30 { world.step(1.0 / 60) }
        let pa = world.body(a)!.position.x
        let pb = world.body(b)!.position.x
        XCTAssertLessThan(pa, pb)
        XCTAssertGreaterThan(pb - pa, 0.4)
    }

    func testTwoFastCirclesDoNotTunnel() {
        let world = PhysicsWorld2D(gravity: .zero)
        world.settings.continuousCollision = true
        var left = BodyDesc2D(type: .dynamic, position: Vec2(-3, 0), shapes: [.circle(radius: 0.25)])
        left.linearVelocity = Vec2(40, 0)
        var right = BodyDesc2D(type: .dynamic, position: Vec2(3, 0), shapes: [.circle(radius: 0.25)])
        right.linearVelocity = Vec2(-40, 0)
        let a = world.createBody(left)
        let b = world.createBody(right)
        for _ in 0..<30 { world.step(1.0 / 60) }
        let pa = world.body(a)!.position.x
        let pb = world.body(b)!.position.x
        XCTAssertLessThan(pa, pb)
        XCTAssertGreaterThan(pb - pa, 0.4)
    }
}
