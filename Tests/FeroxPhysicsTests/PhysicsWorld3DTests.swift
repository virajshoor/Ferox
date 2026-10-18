/// Behavioural tests for the 3D rigid-body world: resting contacts on planes, boxes and triangle
/// meshes, raycasts, teleporting, triggers and sleeping.
import XCTest
import FeroxCore
@testable import FeroxPhysics

final class PhysicsWorld3DTests: XCTestCase {

    private let dt: Float = 1.0 / 60.0

    /// Steps the world for roughly `seconds` at the fixed 1/60 step.
    private func advance(_ world: PhysicsWorld3D, seconds: Float) {
        let steps = Int((seconds / dt).rounded())
        for _ in 0..<steps { world.step(dt) }
    }

    /// Dynamic sphere of radius 0.5 at `p`, with linear damping disabled.
    private func makeSphere(_ world: PhysicsWorld3D, at p: Vec3) -> BodyID {
        var desc = BodyDesc3D(type: .dynamic, position: p, shapes: [Shape3D.sphere(0.5)])
        desc.linearDamping = 0
        return world.createBody(desc)
    }

    /// A sphere falling under gravity alone gains 9.81 m/s of downward speed per second.
    func testFreeFallVelocityMatchesGravity() throws {
        let world = PhysicsWorld3D()
        let sphere = makeSphere(world, at: Vec3(0, 100, 0))
        advance(world, seconds: 1)
        let body = try XCTUnwrap(world.body(sphere))
        XCTAssertEqual(body.linearVelocity.y, -9.81, accuracy: 0.05)
        XCTAssertEqual(body.linearVelocity.x, 0, accuracy: 1e-4)
    }

    /// A sphere dropped onto an infinite plane at y = 0 comes to rest with its centre at the radius.
    func testSphereRestsOnPlane() throws {
        let world = PhysicsWorld3D()
        _ = world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [Shape3D.plane(normal: .up, distance: 0)]))
        let sphere = makeSphere(world, at: Vec3(0, 3, 0))
        advance(world, seconds: 2)
        let body = try XCTUnwrap(world.body(sphere))
        XCTAssertEqual(body.position.y, 0.5, accuracy: 0.05)
        XCTAssertEqual(body.linearVelocity.y, 0, accuracy: 0.1)
    }

    /// A dynamic box dropped onto a static box rests with its bottom face on the top face of the floor.
    func testBoxRestsOnStaticBox() throws {
        let world = PhysicsWorld3D()
        _ = world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [Shape3D.box(Vec3(5, 0.5, 5))]))
        let box = world.createBody(BodyDesc3D(type: .dynamic, position: Vec3(0, 3, 0), shapes: [Shape3D.box(Vec3(0.5, 0.5, 0.5))]))
        advance(world, seconds: 2)
        let body = try XCTUnwrap(world.body(box))
        XCTAssertEqual(body.position.x, 0, accuracy: 0.05)
        XCTAssertEqual(body.position.y, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(world.activeContactCount, 0)
    }

    /// A ray pointing down hits the top face of a static box at the expected point and distance.
    func testRaycastHitsTopFaceOfBox() throws {
        let world = PhysicsWorld3D()
        let box = world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [Shape3D.box(Vec3(1, 1, 1))]))
        let hit = try XCTUnwrap(world.raycast(origin: Vec3(0, 5, 0), direction: Vec3(0, -1, 0)))
        XCTAssertEqual(hit.body, box)
        XCTAssertEqual(hit.distance, 4, accuracy: 1e-3)
        XCTAssertEqual(hit.point.y, 1, accuracy: 1e-3)
        XCTAssertEqual(hit.normal.y, 1, accuracy: 1e-3)
    }

    /// Rays that miss the box laterally, or stop before reaching it, report no hit.
    func testRaycastMissesLateralAndShortRays() {
        let world = PhysicsWorld3D()
        world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [Shape3D.box(Vec3(1, 1, 1))]))
        XCTAssertNil(world.raycast(origin: Vec3(5, 5, 0), direction: Vec3(0, -1, 0)))
        XCTAssertNil(world.raycast(origin: Vec3(0, 5, 0), direction: Vec3(0, -1, 0), maxDistance: 2))
    }

    /// A sphere dropped onto a two-triangle floor mesh rests on the mesh surface.
    func testSphereRestsOnTriangleMeshFloor() throws {
        let vertices = [Vec3(-5, 0, -5), Vec3(5, 0, -5), Vec3(5, 0, 5), Vec3(-5, 0, 5)]
        let mesh = TriangleMesh(vertices: vertices, indices: [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(mesh.triangleCount, 2)

        let world = PhysicsWorld3D()
        _ = world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [Shape3D(.mesh(mesh))]))
        let sphere = makeSphere(world, at: Vec3(0, 3, 0))
        advance(world, seconds: 2)
        XCTAssertEqual(try XCTUnwrap(world.body(sphere)).position.y, 0.5, accuracy: 0.1)
    }

    /// A mesh whose indices reference missing vertices is discarded and contributes no triangles.
    func testMalformedMeshIndicesAreRejected() {
        let mesh = TriangleMesh(vertices: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)], indices: [0, 1, 9])
        XCTAssertEqual(mesh.triangleCount, 0)
    }

    /// setTransform teleports a dynamic body to the requested position and rotation.
    func testSetTransformTeleportsBody() throws {
        let world = PhysicsWorld3D(gravity: .zero)
        let sphere = makeSphere(world, at: .zero)
        world.setTransform(sphere, position: Vec3(1, 2, 3), rotation: .identity, resetInterpolation: true)
        let body = try XCTUnwrap(world.body(sphere))
        XCTAssertEqual(body.position.x, 1, accuracy: 1e-5)
        XCTAssertEqual(body.position.y, 2, accuracy: 1e-5)
        XCTAssertEqual(body.position.z, 3, accuracy: 1e-5)
        XCTAssertEqual(body.previousPosition.z, 3, accuracy: 1e-5)
    }

    /// A trigger box reports overlap events and does not stop a sphere falling through it.
    func testTriggerReportsOverlapWithoutContactResponse() throws {
        let world = PhysicsWorld3D()
        _ = world.createBody(BodyDesc3D(
            type: .static, position: .zero, shapes: [Shape3D.box(Vec3(5, 0.5, 5)).withTrigger()]))
        let sphere = makeSphere(world, at: Vec3(0, 5, 0))
        var events: [ContactEvent<Vec3>] = []
        world.onContact = { events.append($0) }
        advance(world, seconds: 2)
        XCTAssertLessThan(try XCTUnwrap(world.body(sphere)).position.y, 0)
        XCTAssertTrue(events.contains { $0.isTrigger && $0.phase == .began })
        XCTAssertTrue(events.filter(\.isTrigger).allSatisfy { $0.points.isEmpty })
    }

    /// A resting sphere on a plane falls asleep once it has been still long enough.
    func testRestingSphereFallsAsleep() throws {
        let world = PhysicsWorld3D()
        _ = world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: [Shape3D.plane(normal: .up, distance: 0)]))
        let sphere = makeSphere(world, at: Vec3(0, 2, 0))
        advance(world, seconds: 3)
        XCTAssertFalse(try XCTUnwrap(world.body(sphere)).isAwake)
    }
}

private extension Shape3D {
    /// Returns a copy of the shape flagged as a trigger.
    func withTrigger() -> Shape3D {
        var s = self
        s.isTrigger = true
        return s
    }
}
