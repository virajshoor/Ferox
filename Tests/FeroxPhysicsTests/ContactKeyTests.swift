/// Contact keys must not alias when a body has more than 256 shapes.
import XCTest
import FeroxCore
import FeroxMath
import FeroxScene
@testable import FeroxPhysics

final class ContactKeyTests: XCTestCase {
    func testShape256DoesNotAliasShape0() {
        let a = ContactKey(bodyA: 0, shapeA: 0, bodyB: 1, shapeB: 0)
        let b = ContactKey(bodyA: 0, shapeA: 256, bodyB: 1, shapeB: 0)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(ContactKey(bodyA: 1, shapeA: 0, bodyB: 0, shapeB: 256), b)
    }

    func testCompoundWith256ShapesKeepsBothContacts() {
        let world = PhysicsWorld3D(gravity: .zero)
        var shapes: [Shape3D] = [Shape3D.sphere(0.5)]
        for i in 1..<256 {
            shapes.append(Shape3D(.sphere(radius: 0.05), localPose: Pose3D(position: Vec3(0, 500 + Float(i), 0))))
        }
        shapes.append(Shape3D(.sphere(radius: 0.5)))
        XCTAssertEqual(shapes.count, 257)
        world.createBody(BodyDesc3D(type: .static, position: .zero, shapes: shapes))
        world.createBody(BodyDesc3D(type: .dynamic, position: .zero, shapes: [.sphere(0.4)]))
        world.step(1.0 / 60)
        XCTAssertEqual(world.activeContactCount, 2)
    }

    func testTilemapIsNotCappedAt255() {
        var map = Tilemap(tileset: AssetID("tiles"), columns: 1, rows: 1, width: 1, height: 300)
        for y in 0..<300 { map[0, y] = 1 }
        let shapes = PhysicsSystem2D.tilemapShapes(map, material: .default, filter: .default)
        XCTAssertEqual(shapes.count, 300)
    }
}
