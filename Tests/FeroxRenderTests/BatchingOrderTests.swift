/// Tests that the CPU sorts behind 2D batching and shadowed-light selection keep their order:
/// sprites by sorting layer, then order in layer, then creation; lights by distance with
/// equal distances kept in index order.
import XCTest
import Ferox
@testable import FeroxRender

final class SpriteBatchingOrderTests: XCTestCase {
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

    // Layers dominate, then order in layer; sprites that tie keep their creation order.
    func testLayerThenOrderThenCreation() {
        sprite("late-high", at: .zero, layer: 1, order: 0)
        sprite("neg", at: .zero, layer: -1, order: 3)
        sprite("same-a", at: .zero, layer: 0, order: 2)
        sprite("same-b", at: .zero, layer: 0, order: 2)
        sprite("zero", at: .zero, layer: 0, order: 0)
        sprite("early", at: .zero, layer: 0, order: -4)
        let f = build()
        XCTAssertEqual(f.batches.map { $0.texture?.rawValue }, ["neg", "early", "zero", "same-a", "same-b", "late-high"])
        XCTAssertEqual(f.drawnObjects, 6)
    }

    // A sprite and a shape on one entity at the same layer and order keep their append order
    // (sprites first, then shapes), so the sprite batch comes before the untextured shape.
    func testSameEntitySpriteBeforeShape() {
        let e = sprite("pair", at: .zero)
        world.add(ShapeRenderer(.rectangle(size: Vec2(1, 1), cornerRadius: 0), color: .red), to: e)
        let textures: [String?] = build().batches.map { $0.texture?.rawValue }
        XCTAssertEqual(textures, ["pair", nil])
    }
}

final class ShadowedLightOrderTests: XCTestCase {
    var world: World!
    var assets: AssetManager!

    override func setUp() {
        Engine.registerBuiltinComponents()
        world = World()
        assets = AssetManager(database: nil)
    }

    @discardableResult
    func camera(at z: Float = 10) -> Entity {
        let e = world.createEntity(named: "Camera", transform: Transform(position: Vec3(0, 0, z)))
        world.add(Camera.perspective(), to: e)
        return e
    }

    @discardableResult
    func light(at p: Vec3, shadows: Bool) -> Entity {
        let e = world.createEntity(named: "Light", transform: Transform(position: p))
        var l = Light(type: .point, range: 1)
        l.castsShadows = shadows
        world.add(l, to: e)
        return e
    }

    func extract() -> RenderFrameData {
        TransformSystem.update(world)
        return RenderSceneExtractor.extract(world: world, assets: assets, animations: nil, aspect: 16.0 / 9)
    }

    // Shadowed lights come nearest first. (1,0,0) and (-1,0,0) are equally far from the
    // camera, so they stay in index order; the unshadowed light is left out.
    func testEqualDistancesKeepIndexOrder() {
        camera()
        light(at: Vec3(1, 0, 0), shadows: true)
        light(at: Vec3(-1, 0, 0), shadows: true)
        light(at: Vec3(0, 0, 0), shadows: true)
        light(at: Vec3(0, 1, 0), shadows: false)
        let f = extract()
        XCTAssertEqual(f.shadowedLights, [2, 0, 1])
        XCTAssertEqual(f.shadowedLights.map { f.lights[$0].positionRange.x }, [0, 1, -1])
    }
}
