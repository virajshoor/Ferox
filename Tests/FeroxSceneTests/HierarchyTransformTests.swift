/// Tests for scene hierarchy and transforms in FeroxScene: parent/child linking, cycle
/// rejection, re-parenting, subtree traversal, world-space helpers, and `TransformSystem`
/// propagation of world matrices and motion history.
import FeroxCore
import XCTest
@testable import FeroxScene

final class HierarchyTests: XCTestCase {
    // setParent links the child to its parent and keeps siblings in insertion order.
    func testSetParentLinksChildAndParent() {
        let world = World()
        let root = world.createEntity(named: "Root")
        let first = world.createEntity(named: "First")
        let second = world.createEntity(named: "Second")
        XCTAssertTrue(world.setParent(first, root))
        XCTAssertTrue(world.setParent(second, root))
        XCTAssertEqual(world.parent(of: first), root)
        XCTAssertEqual(world.children(of: root), [first, second])
    }

    // An entity cannot be its own parent, and a parent cannot be placed under one of its descendants.
    func testSetParentRejectsSelfAndCycles() {
        let world = World()
        let a = world.createEntity(named: "A")
        let b = world.createEntity(named: "B")
        XCTAssertFalse(world.setParent(a, a))
        XCTAssertTrue(world.setParent(b, a))
        XCTAssertFalse(world.setParent(a, b))
        XCTAssertNil(world.parent(of: a))
    }

    // Re-parenting moves the child out of the old parent's child list.
    func testReparentingMovesChild() {
        let world = World()
        let p1 = world.createEntity(named: "P1")
        let p2 = world.createEntity(named: "P2")
        let child = world.createEntity(named: "Child", parent: p1)
        XCTAssertTrue(world.setParent(child, p2))
        XCTAssertTrue(world.children(of: p1).isEmpty)
        XCTAssertEqual(world.children(of: p2), [child])
        XCTAssertEqual(world.parent(of: child), p2)
    }

    // Passing a null parent turns the child into a root entity.
    func testNullParentMakesRoot() {
        let world = World()
        let parent = world.createEntity(named: "Parent")
        let child = world.createEntity(named: "Child", parent: parent)
        XCTAssertTrue(world.setParent(child, .null))
        XCTAssertNil(world.parent(of: child))
        XCTAssertTrue(world.rootEntities.contains(child))
    }

    // rootEntities lists only entities with a Transform and no parent, in index order.
    func testRootEntitiesAreParentlessAndSorted() {
        let world = World()
        let a = world.createEntity(named: "A")
        let b = world.createEntity(named: "B")
        let c = world.createEntity(named: "C")
        world.setParent(b, a)
        XCTAssertEqual(world.rootEntities, [a, c])
    }

    // Destroying a parent also destroys all of its descendants.
    func testDestroyingParentDestroysDescendants() {
        let world = World()
        let parent = world.createEntity(named: "Parent")
        let child = world.createEntity(named: "Child", parent: parent)
        let grandchild = world.createEntity(named: "Grandchild", parent: child)
        world.destroy(parent)
        XCTAssertFalse(world.isAlive(parent))
        XCTAssertFalse(world.isAlive(child))
        XCTAssertFalse(world.isAlive(grandchild))
    }

    // visitSubtree walks depth-first, visiting each child's descendants before its next sibling.
    func testVisitSubtreeIsDepthFirst() {
        let world = World()
        let root = world.createEntity(named: "root")
        let c1 = world.createEntity(named: "c1", parent: root)
        _ = world.createEntity(named: "g1", parent: c1)
        _ = world.createEntity(named: "c2", parent: root)
        var names: [String] = []
        var depths: [Int] = []
        world.visitSubtree(root) { e, depth in
            names.append(world.get(Name.self, e)?.value ?? "")
            depths.append(depth)
        }
        XCTAssertEqual(names, ["root", "c1", "g1", "c2"])
        XCTAssertEqual(depths, [0, 1, 2, 1])
    }

    // worldMatrix composes ancestor transforms, so a child's world position includes its parent's offset.
    func testWorldMatrixComposesAncestors() {
        let world = World()
        let parent = world.createEntity(named: "Parent", transform: Transform(position: Vec3(1, 0, 0)))
        let child = world.createEntity(named: "Child", transform: Transform(position: Vec3(0, 2, 0)), parent: parent)
        let p = world.worldMatrix(of: child).translation
        XCTAssertEqual(p.x, 1, accuracy: 1e-5)
        XCTAssertEqual(p.y, 2, accuracy: 1e-5)
    }

    // keepWorldTransform adjusts the child's local transform so its world position does not change.
    func testKeepWorldTransformPreservesWorldPosition() {
        let world = World()
        let parent = world.createEntity(named: "Parent", transform: Transform(position: Vec3(10, 0, 0)))
        let child = world.createEntity(named: "Child")
        XCTAssertTrue(world.setParent(child, parent, keepWorldTransform: true))
        let w = world.worldMatrix(of: child).translation
        XCTAssertEqual(w.x, 0, accuracy: 1e-4)
        XCTAssertEqual(world.get(Transform.self, child)?.position.x ?? 0, -10, accuracy: 1e-4)
    }

    // setWorldPosition sets the world-space position by writing the local position relative to the parent.
    func testSetWorldPositionAdjustsLocalForParent() {
        let world = World()
        let parent = world.createEntity(named: "Parent", transform: Transform(position: Vec3(5, 0, 0)))
        let child = world.createEntity(named: "Child", parent: parent)
        world.setWorldPosition(child, Vec3(7, 0, 0))
        XCTAssertEqual(world.get(Transform.self, child)?.position.x ?? 0, 2, accuracy: 1e-5)
    }

    // A Disabled ancestor makes the whole subtree inactive, while unrelated entities stay active.
    func testDisabledAncestorDeactivatesSubtree() {
        let world = World()
        let parent = world.createEntity(named: "Parent")
        let child = world.createEntity(named: "Child", parent: parent)
        let other = world.createEntity(named: "Other")
        world.add(Disabled(), to: parent)
        XCTAssertFalse(world.isActiveInHierarchy(child))
        XCTAssertTrue(world.isActiveInHierarchy(other))
    }

    // find(named:) returns the first entity with the name, and entities(tagged:) returns those with the tag.
    func testFindNamedAndTagged() {
        let world = World()
        let hero = world.createEntity(named: "Hero")
        let enemy = world.createEntity(named: "Enemy")
        world.add(Tags(["Enemy"]), to: enemy)
        XCTAssertEqual(world.find(named: "Hero"), hero)
        XCTAssertNil(world.find(named: "Missing"))
        XCTAssertEqual(world.entities(tagged: "Enemy"), [enemy])
    }
}

final class TransformSystemTests: XCTestCase {
    // A child's world matrix includes the parent's translation.
    func testChildInheritsParentTranslation() {
        let world = World()
        let parent = world.createEntity(named: "Parent", transform: Transform(position: Vec3(10, 0, 0)))
        let child = world.createEntity(named: "Child", transform: Transform(position: Vec3(0, 5, 0)), parent: parent)
        TransformSystem.update(world)
        XCTAssertEqual(world.get(WorldTransform.self, child)?.position.x ?? 0, 10, accuracy: 1e-5)
        XCTAssertEqual(world.get(WorldTransform.self, child)?.position.y ?? 0, 5, accuracy: 1e-5)
    }

    // A child's world position is rotated by its parent's rotation.
    func testChildInheritsParentRotation() {
        let world = World()
        let quarterTurn = Quat(angle: .pi / 2, axis: Vec3(0, 0, 1))
        let parent = world.createEntity(named: "Parent", transform: Transform(rotation: quarterTurn))
        _ = world.createEntity(named: "Child", transform: Transform(position: Vec3(1, 0, 0)), parent: parent)
        TransformSystem.update(world)
        let child = world.children(of: parent).first ?? .null
        let p = world.get(WorldTransform.self, child)?.position ?? .zero
        XCTAssertEqual(p.x, 0, accuracy: 1e-5)
        XCTAssertEqual(p.y, 1, accuracy: 1e-5)
    }

    // Moving a parent updates the world matrices of its children on the next update.
    func testChildFollowsParentChanges() {
        let world = World()
        let parent = world.createEntity(named: "Parent", transform: Transform(position: Vec3(10, 0, 0)))
        let child = world.createEntity(named: "Child", transform: Transform(position: Vec3(0, 5, 0)), parent: parent)
        TransformSystem.update(world)
        world.modify(Transform.self, parent) { $0.position = Vec3(20, 0, 0) }
        TransformSystem.update(world)
        XCTAssertEqual(world.get(WorldTransform.self, child)?.position.x ?? 0, 20, accuracy: 1e-5)
    }

    // A flat root keeps the previous frame's matrix in `previous` for motion vectors.
    func testPreviousMatrixHoldsLastFrame() {
        let world = World()
        let e = world.createEntity(named: "Mover", transform: Transform(position: .zero))
        TransformSystem.update(world)
        world.modify(Transform.self, e) { $0.position = Vec3(3, 0, 0) }
        TransformSystem.update(world)
        let w = world.get(WorldTransform.self, e)
        XCTAssertEqual(w?.position.x ?? -1, 3, accuracy: 1e-5)
        XCTAssertEqual(w?.previous.translation.x ?? -1, 0, accuracy: 1e-5)
    }

    // Marking an entity as teleported makes its previous matrix equal its current matrix.
    func testResetHistoryMakesMotionVectorZero() {
        let world = World()
        let e = world.createEntity(named: "Teleporter", transform: Transform(position: .zero))
        TransformSystem.update(world)
        world.modify(Transform.self, e) { $0.position = Vec3(9, 0, 0) }
        TransformSystem.resetHistory(world, e)
        TransformSystem.update(world)
        let w = world.get(WorldTransform.self, e)
        XCTAssertEqual(w?.previous.translation.x ?? -1, w?.position.x ?? -2, accuracy: 1e-5)
    }
}
