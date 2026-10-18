/// Tests for the CPU stages that feed the GPU: 2D tessellation, debug line collection,
/// sprite batching and 3D scene extraction (camera choice, culling, lights).
import XCTest
import Ferox
@testable import FeroxRender

final class TessellatorTests: XCTestCase {
    /// Total area of the triangles `indices` describes.
    func triangleArea(_ p: [Vec2], _ indices: [UInt32]) -> Float {
        stride(from: 0, to: indices.count, by: 3).reduce(Float(0)) { sum, i in
            sum + abs(Tessellator.signedArea([p[Int(indices[i])], p[Int(indices[i + 1])], p[Int(indices[i + 2])]]))
        }
    }

    // Winding is reported by the sign of the area.
    func testSignedArea() {
        let ccw = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 1), Vec2(0, 1)]
        XCTAssertEqual(Tessellator.signedArea(ccw), 2)
        XCTAssertEqual(Tessellator.signedArea(ccw.reversed()), -2)
        XCTAssertEqual(Tessellator.signedArea([Vec2(0, 0), Vec2(1, 1)]), 0)
    }

    // A convex quad becomes two triangles covering its area, in either winding.
    func testTriangulateQuadBothWindings() {
        let quad = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 1), Vec2(0, 1)]
        for poly in [quad, Array(quad.reversed())] {
            let idx = Tessellator.triangulate(poly)
            XCTAssertEqual(idx.count, 6)
            XCTAssertEqual(triangleArea(poly, idx), 2, accuracy: 1e-5)
        }
    }

    // A concave L-shape is triangulated without covering the notch.
    func testTriangulateConcave() {
        let l = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 1), Vec2(1, 1), Vec2(1, 2), Vec2(0, 2)]
        let idx = Tessellator.triangulate(l)
        XCTAssertEqual(idx.count, (l.count - 2) * 3)
        XCTAssertEqual(triangleArea(l, idx), 3, accuracy: 1e-5, "area of the L, not of its bounding square")
        XCTAssertTrue(idx.allSatisfy { Int($0) < l.count })
    }

    // Degenerate outlines yield no triangles.
    func testTriangulateDegenerate() {
        XCTAssertTrue(Tessellator.triangulate([]).isEmpty)
        XCTAssertTrue(Tessellator.triangulate([Vec2(0, 0), Vec2(1, 0)]).isEmpty)
        XCTAssertTrue(Tessellator.triangulate([Vec2(0, 0), Vec2(1, 0), Vec2(2, 0)]).isEmpty, "collinear")
    }

    // Circles clamp their segment count and lie on the radius.
    func testCircle() {
        XCTAssertEqual(Tessellator.circle(radius: 1, segments: 1).count, 3)
        XCTAssertEqual(Tessellator.circle(radius: 1, segments: 10_000).count, 256)
        for p in Tessellator.circle(radius: 2, segments: 16) { XCTAssertEqual(p.length, 2, accuracy: 1e-5) }
        XCTAssertGreaterThan(Tessellator.signedArea(Tessellator.circle(radius: 1, segments: 32)), 0, "counter-clockwise")
    }

    // Rounded rectangles stay inside their size; a zero radius gives four corners.
    func testRoundedRect() {
        XCTAssertEqual(Tessellator.roundedRect(size: Vec2(4, 2), cornerRadius: 0).count, 4)
        let r = Tessellator.roundedRect(size: Vec2(4, 2), cornerRadius: 10, segmentsPerCorner: 4)
        XCTAssertEqual(r.count, 4 * 5)
        for p in r { XCTAssertTrue(abs(p.x) <= 2 + 1e-5 && abs(p.y) <= 1 + 1e-5) }
    }

    // Strokes emit two vertices per point and one quad per segment.
    func testStroke() {
        let open = Tessellator.stroke([Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)], width: 0.2, closed: false)
        XCTAssertEqual(open.positions.count, 6)
        XCTAssertEqual(open.indices.count, 2 * 6)
        let closed = Tessellator.stroke([Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)], width: 0.2, closed: true)
        XCTAssertEqual(closed.indices.count, 3 * 6)
        // Straight segments are offset by half the width.
        let line = Tessellator.stroke([Vec2(0, 0), Vec2(2, 0)], width: 0.5, closed: false)
        for p in line.positions { XCTAssertEqual(abs(p.y), 0.25, accuracy: 1e-5) }
        XCTAssertTrue(Tessellator.stroke([Vec2(0, 0)], width: 1, closed: false).indices.isEmpty)
        XCTAssertTrue(Tessellator.stroke([Vec2(0, 0), Vec2(1, 0)], width: 0, closed: false).indices.isEmpty)
        let dupes = Tessellator.stroke([Vec2(0, 0), Vec2(0, 0), Vec2(1, 0)], width: 0.1, closed: false)
        XCTAssertEqual(dupes.positions.count, 4, "duplicate points are dropped")
    }
}

final class DebugDrawTests: XCTestCase {
    // Shapes produce the expected number of lines; empty boxes produce none.
    func testLineCounts() {
        let d = DebugDraw()
        d.box(AABB(min: Vec3(-1, -1, -1), max: Vec3(1, 1, 1)))
        XCTAssertEqual(d.lineCount, 12)
        d.box(.empty)
        XCTAssertEqual(d.lineCount, 12)
        d.polyline([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0)], closed: true)
        XCTAssertEqual(d.lineCount, 15)
        d.polyline([Vec3(0, 0, 0)])
        XCTAssertEqual(d.lineCount, 15)
        XCTAssertEqual(d.vertices.count, 30)
    }

    // Lines past the budget are counted as dropped, and clear resets both.
    func testBudgetAndClear() {
        let d = DebugDraw(maxLines: 5)
        for _ in 0..<8 { d.line(.zero, Vec3(1, 0, 0)) }
        XCTAssertEqual(d.lineCount, 5)
        XCTAssertEqual(d.droppedLines, 3)
        d.clear()
        XCTAssertEqual(d.lineCount, 0)
        XCTAssertEqual(d.droppedLines, 0)
        XCTAssertEqual(DebugDraw(maxLines: -3).maxLines, 0)
    }

    // Boxes honour their transform.
    func testBoxTransform() {
        let d = DebugDraw()
        d.box(AABB(min: .zero, max: Vec3(1, 1, 1)), transform: Mat4.translation(Vec3(10, 0, 0)))
        XCTAssertTrue(d.vertices.allSatisfy { $0.position.x >= 10 - 1e-5 })
    }
}

final class SpriteBatcherTests: XCTestCase {
    var world: World!
    var assets: AssetManager!
    var camera: RenderCamera!

    override func setUp() {
        Engine.registerBuiltinComponents()
        world = World()
        assets = AssetManager(database: nil)
        let e = world.createEntity(named: "Camera", transform: Transform(position: Vec3(0, 0, 10)))
        let cam = Camera.orthographic(size: 5)
        world.add(cam, to: e)
        TransformSystem.update(world)
        camera = RenderCamera(entity: e, camera: cam, worldMatrix: world.worldMatrix(of: e), aspect: 1)
    }

    @discardableResult
    func sprite(_ texture: String, at p: Vec2, layer: Int = 0, order: Int = 0) -> Entity {
        let e = world.createEntity(named: texture, transform: Transform(position: Vec3(p.x, p.y, 0)))
        var s = SpriteRenderer(texture: AssetID(texture), size: Vec2(1, 1))
        s.sortingLayer = layer
        s.orderInLayer = order
        world.add(s, to: e)
        return e
    }

    func build() -> SpriteFrameData {
        TransformSystem.update(world)
        return SpriteBatcher().build(world: world, assets: assets, camera: camera, targetSize: SIMD2(800, 800))
    }

    // Sprites sharing a texture and state merge into one draw.
    func testSameTextureMerges() {
        sprite("a", at: Vec2(0, 0))
        sprite("a", at: Vec2(1, 0))
        let f = build()
        XCTAssertEqual(f.batches.count, 1)
        XCTAssertEqual(f.batches[0].indexCount, 12)
        XCTAssertEqual(f.vertices.count, 8)
        XCTAssertEqual(f.drawnObjects, 2)
    }

    // A texture change splits the draw.
    func testTextureChangeSplits() {
        sprite("a", at: Vec2(0, 0))
        sprite("b", at: Vec2(1, 0))
        let f = build()
        XCTAssertEqual(f.batches.count, 2)
        XCTAssertEqual(f.batches[1].firstIndex, 6)
    }

    // Draw order follows sorting layer, then order in layer, not creation order.
    func testSortingOrder() {
        sprite("front", at: .zero, layer: 2)
        sprite("back", at: .zero, layer: 0, order: 5)
        sprite("middle", at: .zero, layer: 1)
        sprite("back-first", at: .zero, layer: 0, order: 1)
        let textures = build().batches.map { $0.texture?.rawValue }
        XCTAssertEqual(textures, ["back-first", "back", "middle", "front"])
    }

    // Sprites outside the camera are culled and counted.
    func testCulling() {
        sprite("a", at: .zero)
        sprite("a", at: Vec2(100, 0))
        let f = build()
        XCTAssertEqual(f.drawnObjects, 1)
        XCTAssertEqual(f.culledObjects, 1)
    }

    // Disabled entities are skipped entirely.
    func testDisabledSkipped() {
        let e = sprite("a", at: .zero)
        world.add(Disabled(), to: e)
        let f = build()
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.drawnObjects + f.culledObjects, 0)
    }

    // Shapes are tessellated into untextured triangles.
    func testShapes() {
        let e = world.createEntity(named: "Box")
        world.add(ShapeRenderer(.rectangle(size: Vec2(2, 1), cornerRadius: 0), color: .red), to: e)
        let f = build()
        XCTAssertEqual(f.batches.count, 1)
        XCTAssertNil(f.batches[0].texture)
        XCTAssertEqual(f.indices.count, 6)
        XCTAssertTrue(f.indices.allSatisfy { Int($0) < f.vertices.count })
    }
}

final class SceneExtractionTests: XCTestCase {
    var world: World!
    var assets: AssetManager!
    let cube = AssetID("test.cube")

    override func setUp() {
        Engine.registerBuiltinComponents()
        world = World()
        assets = AssetManager(database: nil)
        assets.registerMesh(.cube(), id: cube)
    }

    @discardableResult
    func camera(priority: Int, at z: Float = 10) -> Entity {
        let e = world.createEntity(named: "Camera \(priority)", transform: Transform(position: Vec3(0, 0, z)))
        var c = Camera.perspective()
        c.priority = priority
        world.add(c, to: e)
        return e
    }

    @discardableResult
    func cubeEntity(at p: Vec3) -> Entity {
        let e = world.createEntity(named: "Cube", transform: Transform(position: p))
        world.add(MeshRenderer(mesh: cube), to: e)
        return e
    }

    func extract(_ options: ExtractionOptions = ExtractionOptions()) -> RenderFrameData {
        TransformSystem.update(world)
        return RenderSceneExtractor.extract(world: world, assets: assets, animations: nil, aspect: 16.0 / 9,
                                            options: options)
    }

    // Without a camera nothing is drawn.
    func testNoCamera() {
        cubeEntity(at: .zero)
        let f = extract()
        XCTAssertNil(f.camera)
        XCTAssertTrue(f.opaque.isEmpty)
    }

    // The highest-priority enabled camera wins.
    func testMainCameraPriority() {
        camera(priority: 1)
        let high = camera(priority: 9)
        XCTAssertEqual(RenderSceneExtractor.mainCamera(in: world)?.0, high)
        world.add(Disabled(), to: high)
        XCTAssertNotEqual(RenderSceneExtractor.mainCamera(in: world)?.0, high)
    }

    // A cube in front is visible; one behind the camera is culled.
    func testFrustumCulling() {
        camera(priority: 0)
        cubeEntity(at: .zero)
        cubeEntity(at: Vec3(0, 0, 50))
        let f = extract()
        XCTAssertEqual(f.visibleObjects, 1)
        XCTAssertEqual(f.culledObjects, 1)
        XCTAssertFalse(f.opaque.isEmpty)
    }

    // Disabled renderers are not extracted at all.
    func testDisabledMeshSkipped() {
        camera(priority: 0)
        let e = cubeEntity(at: .zero)
        world.add(Disabled(), to: e)
        let f = extract()
        XCTAssertEqual(f.visibleObjects + f.culledObjects, 0)
    }

    // A camera override replaces the scene camera (probe and editor views).
    func testCameraOverride() {
        camera(priority: 0)
        cubeEntity(at: .zero)
        var options = ExtractionOptions()
        let behind = Mat4(translation: Vec3(0, 0, -10), rotation: Quat(pitch: 0, yaw: .pi, roll: 0), scale: Vec3(1, 1, 1))
        options.cameraOverride = RenderCamera(entity: .null, camera: .perspective(), worldMatrix: behind, aspect: 1)
        let f = extract(options)
        XCTAssertEqual(f.camera?.entity, .null)
        XCTAssertEqual(f.camera?.position.z ?? 0, -10, accuracy: 1e-5)
        XCTAssertEqual(f.visibleObjects, 1, "the override looks back at the cube")
    }

    // The brightest directional light becomes the sun, and every light is listed.
    func testSunSelection() {
        camera(priority: 0)
        let dim = world.createEntity(named: "Dim")
        world.add(Light(type: .directional, intensity: 1), to: dim)
        let bright = world.createEntity(named: "Bright")
        world.add(Light(type: .directional, intensity: 5), to: bright)
        let f = extract()
        XCTAssertEqual(f.sun?.intensity, 5)
        XCTAssertEqual(f.directionalCount, 2)
    }

    // A shadow-casting directional light is preferred over a brighter one.
    func testShadowCasterPreferredAsSun() {
        camera(priority: 0)
        let bright = world.createEntity(named: "Bright")
        world.add(Light(type: .directional, intensity: 50), to: bright)
        let caster = world.createEntity(named: "Caster")
        var l = Light(type: .directional, intensity: 2)
        l.castsShadows = true
        world.add(l, to: caster)
        let f = extract()
        XCTAssertEqual(f.sun?.intensity, 2)
        XCTAssertEqual(f.sun?.castsShadows, true)
    }
}
