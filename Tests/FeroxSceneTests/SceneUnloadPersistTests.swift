/// Regression test: a `PersistAcrossScenes` entity parented under an entity of the unloaded
/// scene must be detached before the scene's entities are destroyed, so it survives the unload.
import XCTest

@testable import FeroxScene

final class SceneUnloadPersistTests: XCTestCase {
    func testPersistentChildOfDoomedParentSurvivesUnload() {
        let world = World()
        let manager = SceneManager(world: world)
        let handle = manager.createEmpty(name: "A")

        let parent = world.createEntity()
        world.add(SceneMember(scene: handle), to: parent)
        let child = world.createEntity()
        world.add(SceneMember(scene: handle), to: child)
        world.add(PersistAcrossScenes(), to: child)
        XCTAssertTrue(world.setParent(child, parent))

        manager.unload(handle)

        XCTAssertFalse(world.isAlive(parent))
        XCTAssertTrue(world.isAlive(child))
        XCTAssertNil(world.parent(of: child))
        XCTAssertEqual(world.entityCount, 1)
    }
}
