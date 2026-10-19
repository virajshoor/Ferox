/// Tests for viewport picking: `Camera.ray(through:aspect:cameraToWorld:)` and `EditorSession.pick`.
import XCTest

@testable import Ferox

final class EditorPickingTests: XCTestCase {
    var engine: Engine!
    var session: EditorSession!
    let cube = AssetID("test.pick.cube")

    override func setUpWithError() throws {
        var config = EngineConfiguration(title: "PickTest")
        config.enableAudio = false
        engine = try Engine(configuration: config)
        session = EditorSession(engine: engine)
        engine.assets.registerMesh(.cube(), id: cube)
    }

    override func tearDown() {
        session = nil
        engine = nil
    }

    func box(_ name: String, at p: Vec3) -> Entity {
        let e = engine.world.createEntity(named: name, transform: Transform(position: p))
        engine.world.add(MeshRenderer(mesh: cube), to: e)
        return e
    }

    // Camera at z = 10 looking down -Z; the default rotation faces Vec3.forward.
    let eye = Mat4.translation(Vec3(0, 0, 10))

    // The centre of the viewport unprojects to the camera's forward axis, for both projections.
    func testCentreRayFollowsCameraForward() {
        for camera in [Camera.perspective(), Camera.orthographic(size: 5)] {
            let ray = camera.ray(through: Vec2(0.5, 0.5), aspect: 16.0 / 9, cameraToWorld: eye)
            XCTAssertEqual(ray.direction.z, -1, accuracy: 1e-4)
            XCTAssertEqual(ray.origin.x, 0, accuracy: 1e-4)
            XCTAssertEqual(ray.origin.y, 0, accuracy: 1e-4)
        }
    }

    // Top-left origin: a point above the centre (smaller y) points the ray upward.
    func testViewportYIsTopDown() {
        let ray = Camera.perspective().ray(through: Vec2(0.5, 0.1), aspect: 1, cameraToWorld: eye)
        XCTAssertGreaterThan(ray.direction.y, 0)
        let right = Camera.perspective().ray(through: Vec2(0.9, 0.5), aspect: 1, cameraToWorld: eye)
        XCTAssertGreaterThan(right.direction.x, 0)
    }

    // The nearer of two boxes on the ray is picked; a ray that misses picks nothing.
    func testPickReturnsNearestHit() {
        let near = box("Near", at: Vec3(0, 0, 0))
        _ = box("Far", at: Vec3(0, 0, -5))
        _ = engine.tick(delta: 1.0 / 60)
        let camera = Camera.perspective()
        XCTAssertEqual(session.pick(camera.ray(through: Vec2(0.5, 0.5), aspect: 1, cameraToWorld: eye)), near)
        XCTAssertNil(session.pick(camera.ray(through: Vec2(0.02, 0.02), aspect: 1, cameraToWorld: eye)))
    }

    // Editor-owned and disabled entities are never picked; the next box behind them is.
    func testPickSkipsEditorAndDisabledEntities() {
        let editorOwned = box("Gizmo", at: Vec3(0, 0, 4))
        let disabled = box("Hidden", at: Vec3(0, 0, 2))
        let target = box("Target", at: Vec3(0, 0, 0))
        session.editorEntities.insert(editorOwned)
        engine.world.add(Disabled(), to: disabled)
        _ = engine.tick(delta: 1.0 / 60)
        let ray = Camera.perspective().ray(through: Vec2(0.5, 0.5), aspect: 1, cameraToWorld: eye)
        XCTAssertEqual(session.pick(ray), target)
    }

    // A light without a mesh is pickable through its marker sphere.
    func testPickHitsLightMarker() {
        let light = engine.world.createEntity(named: "Lamp", transform: Transform(position: .zero))
        engine.world.add(Light(), to: light)
        _ = engine.tick(delta: 1.0 / 60)
        let ray = Camera.perspective().ray(through: Vec2(0.5, 0.5), aspect: 1, cameraToWorld: eye)
        XCTAssertEqual(session.pick(ray), light)
    }
}
