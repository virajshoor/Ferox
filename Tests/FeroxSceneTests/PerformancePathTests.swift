/// Behaviour pins for the hot paths in `TransformSystem` and the hierarchy helpers. These
/// tests guard the results of the lookup-hoisting refactor: flat roots, parent/child
/// composition, motion history, `Disabled` inheritance, and `worldMatrix(of:)` agreeing
/// with the system's cached world matrices.
import FeroxCore
import XCTest
@testable import FeroxScene

final class PerformancePathTests: XCTestCase {
    // Element-wise comparison: matrices composed in a different order differ by rounding.
    private func assertMatrixEqual(_ a: Mat4, _ b: Mat4, accuracy: Float = 1e-4,
                                   file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<4 {
            for r in 0..<4 {
                XCTAssertEqual(a[c][r], b[c][r], accuracy: accuracy, file: file, line: line)
            }
        }
    }

    // A flat root with no Parent or Children gets a world matrix equal to its local matrix.
    func testFlatRootWorldMatrixEqualsLocal() {
        let world = World()
        let transform = Transform(position: Vec3(1, 2, 3), scale: Vec3(2, 2, 2))
        let e = world.createEntity(named: "flat", transform: transform)
        TransformSystem.update(world)
        XCTAssertEqual(world.get(WorldTransform.self, e)?.matrix, transform.localMatrix)
    }

    // A child's world matrix is parent.local * child.local, and its translation is the sum
    // of both positions when neither rotates or scales.
    func testParentChildHierarchyComposesMatrices() {
        let world = World()
        let parentTransform = Transform(position: Vec3(10, 0, 0))
        let childTransform = Transform(position: Vec3(0, 5, 0))
        let parent = world.createEntity(named: "parent", transform: parentTransform)
        let child = world.createEntity(named: "child", transform: childTransform, parent: parent)
        TransformSystem.update(world)
        guard let childWorld = world.get(WorldTransform.self, child)?.matrix else {
            return XCTFail("child has no WorldTransform")
        }
        assertMatrixEqual(childWorld, parentTransform.localMatrix * childTransform.localMatrix)
        XCTAssertEqual(childWorld.translation.x, 10, accuracy: 1e-4)
        XCTAssertEqual(childWorld.translation.y, 5, accuracy: 1e-4)
        XCTAssertEqual(childWorld.translation.z, 0, accuracy: 1e-4)
    }

    // After a second update, `previous` holds the matrix from the previous frame, and
    // `matrix` holds the newly computed value.
    func testPreviousEqualsLastFrameAfterSecondUpdate() {
        let world = World()
        let e = world.createEntity(named: "mover", transform: Transform(position: Vec3(0, 0, 0)))
        TransformSystem.update(world)
        let firstFrame = world.get(WorldTransform.self, e)?.matrix
        world.modify(Transform.self, e) { $0.position = Vec3(4, 0, 0) }
        TransformSystem.update(world)
        let secondFrame = world.get(WorldTransform.self, e)
        XCTAssertEqual(secondFrame?.previous, firstFrame)
        XCTAssertEqual(secondFrame?.matrix, Transform(position: Vec3(4, 0, 0)).localMatrix)
    }

    // A Disabled ancestor makes the descendant inactive, while a sibling stays active.
    func testDisabledAncestorMakesDescendantInactive() {
        let world = World()
        let root = world.createEntity(named: "root")
        let child = world.createEntity(named: "child", parent: root)
        let sibling = world.createEntity(named: "sibling")
        XCTAssertTrue(world.isActiveInHierarchy(child))
        world.add(Disabled(), to: root)
        XCTAssertFalse(world.isActiveInHierarchy(child))
        XCTAssertTrue(world.isActiveInHierarchy(sibling))
    }

    // worldMatrix(of:) on a 3-deep chain agrees with the matrix cached by TransformSystem.
    func testWorldMatrixOfMatchesTransformSystemForThreeDeepChain() {
        let world = World()
        let a = world.createEntity(named: "a", transform: Transform(position: Vec3(1, 0, 0),
            rotation: Quat(angle: 0.5, axis: Vec3(0, 0, 1)), scale: Vec3(2, 2, 2)))
        let b = world.createEntity(named: "b", transform: Transform(position: Vec3(0, 3, 0),
            rotation: Quat(angle: -0.3, axis: Vec3(1, 0, 0))), parent: a)
        let c = world.createEntity(named: "c", transform: Transform(position: Vec3(0, 0, 4),
            scale: Vec3(0.5, 0.5, 0.5)), parent: b)
        TransformSystem.update(world)
        guard let cached = world.get(WorldTransform.self, c)?.matrix else {
            return XCTFail("c has no WorldTransform")
        }
        assertMatrixEqual(world.worldMatrix(of: c), cached)
    }
}
