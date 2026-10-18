/// Determinism and settling tests for the 2D and 3D rigid-body worlds: the same pile built twice
/// in fresh worlds must produce bit-identical body state, and every body must come to rest above
/// the static ground.
import XCTest
import FeroxCore
@testable import FeroxPhysics

final class PhysicsDeterminismTests: XCTestCase {

    private let dt: Float = 1.0 / 60.0
    private let steps = 120
    private let boxCount = 30
    /// Top surface of the static ground (both grounds are centred at the origin with half height 0.5).
    private let groundTop: Float = 0.5
    private let epsilon: Float = 0.05

    // MARK: 2D

    /// Builds a static floor and `boxCount` unit boxes in staggered columns above it.
    private func buildPile2D() -> (world: PhysicsWorld2D, boxes: [BodyID]) {
        let world = PhysicsWorld2D()
        _ = world.createBody(
            BodyDesc2D(type: .static, position: .zero, shapes: [Shape2D.box(halfExtents: Vec2(50, 0.5))]))
        var boxes: [BodyID] = []
        for i in 0..<boxCount {
            let column = Float(i % 6), row = Float(i / 6)
            let position = Vec2(column * 1.2 - 3, 2 + row * 1.2)
            let id = world.createBody(
                BodyDesc2D(type: .dynamic, position: position, shapes: [Shape2D.box(halfExtents: Vec2(0.5, 0.5))]))
            boxes.append(id)
        }
        return (world, boxes)
    }

    /// Runs the 2D pile for `steps` fixed steps in a fresh world and returns the final body states.
    private func simulatePile2D() -> [Body2D] {
        let (world, boxes) = buildPile2D()
        for _ in 0..<steps { world.step(dt) }
        return boxes.compactMap { world.body($0) }
    }

    /// Two identical 2D runs in fresh worlds give exactly equal positions and velocities.
    func testPile2DIsDeterministicAcrossFreshWorlds() {
        let first = simulatePile2D()
        let second = simulatePile2D()
        XCTAssertEqual(first.count, boxCount)
        XCTAssertEqual(second.count, boxCount)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.position.x, b.position.x)
            XCTAssertEqual(a.position.y, b.position.y)
            XCTAssertEqual(a.linearVelocity.x, b.linearVelocity.x)
            XCTAssertEqual(a.linearVelocity.y, b.linearVelocity.y)
        }
    }

    /// After settling, every 2D box is still above the ground top (minus a small epsilon).
    func testPile2DComesToRestAboveGround() {
        let bodies = simulatePile2D()
        XCTAssertEqual(bodies.count, boxCount)
        for b in bodies {
            XCTAssertGreaterThan(b.position.y, groundTop - epsilon)
        }
    }

    // MARK: 3D

    /// Builds a static floor and `boxCount` unit boxes in staggered columns above it.
    private func buildPile3D() -> (world: PhysicsWorld3D, boxes: [BodyID]) {
        let world = PhysicsWorld3D()
        _ = world.createBody(
            BodyDesc3D(type: .static, position: .zero, shapes: [Shape3D.box(Vec3(50, 0.5, 50))]))
        var boxes: [BodyID] = []
        for i in 0..<boxCount {
            let column = Float(i % 6), row = Float(i / 6)
            let position = Vec3(column * 1.2 - 3, 2 + row * 1.2, 0)
            let id = world.createBody(
                BodyDesc3D(type: .dynamic, position: position, shapes: [Shape3D.box(Vec3(0.5, 0.5, 0.5))]))
            boxes.append(id)
        }
        return (world, boxes)
    }

    /// Runs the 3D pile for `steps` fixed steps in a fresh world and returns the final body states.
    private func simulatePile3D() -> [Body3D] {
        let (world, boxes) = buildPile3D()
        for _ in 0..<steps { world.step(dt) }
        return boxes.compactMap { world.body($0) }
    }

    /// Two identical 3D runs in fresh worlds give exactly equal positions and velocities.
    func testPile3DIsDeterministicAcrossFreshWorlds() {
        let first = simulatePile3D()
        let second = simulatePile3D()
        XCTAssertEqual(first.count, boxCount)
        XCTAssertEqual(second.count, boxCount)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.position.x, b.position.x)
            XCTAssertEqual(a.position.y, b.position.y)
            XCTAssertEqual(a.position.z, b.position.z)
            XCTAssertEqual(a.linearVelocity.x, b.linearVelocity.x)
            XCTAssertEqual(a.linearVelocity.y, b.linearVelocity.y)
            XCTAssertEqual(a.linearVelocity.z, b.linearVelocity.z)
        }
    }

    /// After settling, every 3D box is still above the ground top (minus a small epsilon).
    func testPile3DComesToRestAboveGround() {
        let bodies = simulatePile3D()
        XCTAssertEqual(bodies.count, boxCount)
        for b in bodies {
            XCTAssertGreaterThan(b.position.y, groundTop - epsilon)
        }
    }
}
