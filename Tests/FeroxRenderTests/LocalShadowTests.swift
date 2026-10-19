import Ferox
/// Tests for point- and spot-light shadow planning (`LocalShadowPlanner`), the extractor's
/// shadow inputs (`shadowedLights`, the per-instance receive flag), the shared probe face
/// size and the camera viewport conversion. None of these touch Metal.
import XCTest

@testable import FeroxRender

final class LocalShadowPlannerTests: XCTestCase {
    func light(
        type: Float, at p: Vec3 = .zero, range: Float = 10, direction: Vec3 = .forward,
        cosOuter: Float = cos(0.5)
    ) -> LightData {
        var d = LightData()
        d.positionRange = Vec4(p, range)
        d.color = Vec4(1, 1, 1, type)
        d.direction = Vec4(direction, cosOuter)
        d.extra = Vec4(1, -1, 0, 0)
        return d
    }

    /// Projects `p` with `m` and returns normalised device coordinates, or nil behind the light.
    func project(_ m: Mat4, _ p: Vec3) -> Vec3? {
        let c = m * Vec4(p, 1)
        guard c.w > 0 else { return nil }
        return Vec3(c.x / c.w, c.y / c.w, c.z / c.w)
    }

    /// The shader's face choice follows the dominant axis, positive before negative.
    func testPointFaceSelection() {
        XCTAssertEqual(LocalShadowPlanner.pointFace(for: Vec3(1, 0.5, 0)), 0)
        XCTAssertEqual(LocalShadowPlanner.pointFace(for: Vec3(-2, 1, 1)), 1)
        XCTAssertEqual(LocalShadowPlanner.pointFace(for: Vec3(0, 3, -1)), 2)
        XCTAssertEqual(LocalShadowPlanner.pointFace(for: Vec3(0, -3, 1)), 3)
        XCTAssertEqual(LocalShadowPlanner.pointFace(for: Vec3(0, 0, 2)), 4)
        XCTAssertEqual(LocalShadowPlanner.pointFace(for: Vec3(0.1, 0, -2)), 5)
    }

    /// Each cube face maps a point straight ahead of it to the centre, with standard depth in (0, 1).
    func testPointFaceMatricesLookDownTheirAxis() throws {
        let position = Vec3(2, 1, -3)
        for face in 0..<6 {
            let dir = LocalShadowPlanner.pointFaces[face].direction
            XCTAssertEqual(LocalShadowPlanner.pointFace(for: dir), face)
            let m = LocalShadowPlanner.pointFaceMatrix(position: position, range: 10, face: face, resolution: 512)
            let ndc = try XCTUnwrap(project(m, position + dir * 5), "face \(face)")
            XCTAssertEqual(ndc.x, 0, accuracy: 1e-4)
            XCTAssertEqual(ndc.y, 0, accuracy: 1e-4)
            XCTAssertGreaterThan(ndc.z, 0)
            XCTAssertLessThan(ndc.z, 1)
            XCTAssertNil(project(m, position - dir * 5), "a point behind face \(face) is not projected")
        }
    }

    /// Depth grows with distance and reaches 1 at the light's range.
    func testPointFaceDepthIsMonotonic() throws {
        let m = LocalShadowPlanner.pointFaceMatrix(position: .zero, range: 10, face: 0, resolution: 512)
        let near = try XCTUnwrap(project(m, Vec3(1, 0, 0))).z
        let far = try XCTUnwrap(project(m, Vec3(9, 0, 0))).z
        let edge = try XCTUnwrap(project(m, Vec3(10, 0, 0))).z
        XCTAssertLessThan(near, far)
        XCTAssertEqual(edge, 1, accuracy: 1e-4)
    }

    /// A spot matrix centres its axis and keeps the cone's rim inside the map, including a straight-down spot.
    func testSpotMatrixCoversCone() throws {
        let halfAngle: Float = 0.5
        for dir in [Vec3.forward, Vec3(0, -1, 0)] {
            let m = LocalShadowPlanner.spotMatrix(
                position: .zero, direction: dir, cosOuter: cos(halfAngle),
                range: 10, resolution: 512)
            let centre = try XCTUnwrap(project(m, dir * 5))
            XCTAssertEqual(centre.x, 0, accuracy: 1e-4)
            XCTAssertEqual(centre.y, 0, accuracy: 1e-4)
            let side = abs(dir.y) > 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
            let rim = (dir * cos(halfAngle) + side * sin(halfAngle)) * 5
            let r = try XCTUnwrap(project(m, rim))
            XCTAssertLessThan(max(abs(r.x), abs(r.y)), 1, "rim stays inside the map")
        }
    }

    /// Slices go nearest-first; a point light that no longer fits is skipped, directional lights never get one.
    func testPlanAssignsSlicesWithinBudget() {
        var lights = [light(type: 0), light(type: 1), light(type: 2), light(type: 1, at: Vec3(5, 0, 0))]
        let slices = LocalShadowPlanner.plan(
            lights: &lights, candidates: [1, 2, 3, 0], budget: 8,
            resolution: 512, normalBias: 0.02)
        XCTAssertEqual(slices.count, 7)
        XCTAssertEqual(slices.prefix(6).map(\.face), Array(0..<6))
        XCTAssertTrue(slices.prefix(6).allSatisfy { $0.light == 1 })
        XCTAssertEqual(slices[6].light, 2)
        XCTAssertEqual(slices[6].face, 0)
        XCTAssertEqual(lights[1].extra.y, 0)
        XCTAssertEqual(lights[2].extra.y, 6)
        XCTAssertEqual(lights[3].extra.y, -1, "six more slices do not fit in the budget")
        XCTAssertEqual(lights[0].extra.y, -1)
        XCTAssertEqual(lights[1].extra.z, 1.0 / 512, accuracy: 1e-7)
        XCTAssertGreaterThan(lights[1].extra.w, 0)
        XCTAssertEqual(lights[2].extra.x, 1, "the inner cone is left alone")
    }

    /// A zero budget shadows nothing; a huge budget is capped at `maxSlices`; bad indices are ignored.
    func testPlanBudgetLimits() {
        var lights = (0..<20).map { light(type: 1, at: Vec3(Float($0), 0, 0)) }
        XCTAssertTrue(
            LocalShadowPlanner.plan(
                lights: &lights, candidates: Array(0..<20), budget: 0,
                resolution: 512, normalBias: 0
            ).isEmpty)
        XCTAssertTrue(lights.allSatisfy { $0.extra.y < 0 })
        let slices = LocalShadowPlanner.plan(
            lights: &lights, candidates: [-1, 99] + Array(0..<20), budget: 1000,
            resolution: 512, normalBias: 0)
        XCTAssertEqual(slices.count, 60, "ten point lights fit in 64 slices")
        XCTAssertLessThanOrEqual(slices.count, LocalShadowPlanner.maxSlices)
        XCTAssertEqual(lights.filter { $0.extra.y >= 0 }.count, 10)
    }
}

final class LocalShadowExtractionTests: XCTestCase {
    var world: World!
    var assets: AssetManager!
    let cube = AssetID("test.cube")

    override func setUp() {
        Engine.registerBuiltinComponents()
        world = World()
        assets = AssetManager(database: nil)
        assets.registerMesh(.cube(), id: cube)
        let cam = world.createEntity(named: "Camera", transform: Transform(position: Vec3(0, 0, 10)))
        world.add(Camera.perspective(), to: cam)
    }

    func extract() -> RenderFrameData {
        TransformSystem.update(world)
        return RenderSceneExtractor.extract(
            world: world, assets: assets, animations: nil, aspect: 16.0 / 9,
            options: ExtractionOptions())
    }

    func addLight(_ type: LightType, at p: Vec3, shadows: Bool) {
        let e = world.createEntity(named: "Light", transform: Transform(position: p))
        var l = Light(type: type, intensity: 1)
        l.range = 2
        l.castsShadows = shadows
        world.add(l, to: e)
    }

    /// Only shadow-casting point and spot lights are listed, nearest to the camera first.
    func testShadowedLightsAreNearestFirst() {
        addLight(.point, at: Vec3(0, 0, -5), shadows: true)
        addLight(.spot, at: Vec3(1, 0, 0), shadows: false)
        addLight(.spot, at: Vec3(0, 0, 0), shadows: true)
        let f = extract()
        XCTAssertEqual(f.shadowedLights.count, 2)
        let z = f.shadowedLights.map { f.lights[$0].positionRange.z }
        XCTAssertEqual(z, [0, -5])
        XCTAssertTrue(f.shadowedLights.allSatisfy { f.lights[$0].extra.y < 0 }, "slices are assigned by the renderer")
    }

    /// `receivesShadows = false` sets the instance flag the shader reads.
    func testReceivesShadowsFlagReachesInstances() {
        let a = world.createEntity(named: "Receiver", transform: Transform(position: .zero))
        world.add(MeshRenderer(mesh: cube), to: a)
        let b = world.createEntity(named: "Ignorer", transform: Transform(position: Vec3(2, 0, 0)))
        var r = MeshRenderer(mesh: cube)
        r.receivesShadows = false
        world.add(r, to: b)
        let flags = extract().instances.map(\.emissiveAdd.w).sorted()
        XCTAssertEqual(flags, [0, 1])
    }
}

final class ProbeAndViewportMathTests: XCTestCase {
    /// The shared probe face size is the largest request, rounded up to a power of two and clamped.
    func testProbeFaceSize() {
        XCTAssertEqual(RenderMath.probeFaceSize(requested: [100], current: 128), 128)
        XCTAssertEqual(RenderMath.probeFaceSize(requested: [64, 200], current: 128), 256)
        XCTAssertEqual(RenderMath.probeFaceSize(requested: [4096], current: 128), 256)
        XCTAssertEqual(RenderMath.probeFaceSize(requested: [1, 0, -5], current: 128), 32)
        XCTAssertEqual(RenderMath.probeFaceSize(requested: [64], current: 128), 64)
        XCTAssertEqual(RenderMath.probeFaceSize(requested: [], current: 64), 64, "no probes keeps the size")
    }

    /// Normalised viewports become whole pixels, clipped to the output and never empty.
    func testViewportPixels() {
        XCTAssertEqual(
            RenderMath.viewportPixels(.unit, outputWidth: 1920, outputHeight: 1080),
            PixelRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(
            RenderMath.viewportPixels(
                Rect(x: 0.5, y: 0, width: 0.5, height: 1),
                outputWidth: 1920, outputHeight: 1080),
            PixelRect(x: 960, y: 0, width: 960, height: 1080))
        XCTAssertEqual(
            RenderMath.viewportPixels(
                Rect(x: -1, y: -1, width: 3, height: 3),
                outputWidth: 800, outputHeight: 600),
            PixelRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(
            RenderMath.viewportPixels(
                Rect(x: 2, y: 2, width: 1, height: 1),
                outputWidth: 800, outputHeight: 600),
            PixelRect(x: 799, y: 599, width: 1, height: 1))
        XCTAssertEqual(
            RenderMath.viewportPixels(
                Rect(x: .nan, y: 0, width: .nan, height: 0),
                outputWidth: 800, outputHeight: 600),
            PixelRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(
            RenderMath.viewportPixels(.unit, outputWidth: 0, outputHeight: 0),
            PixelRect(x: 0, y: 0, width: 1, height: 1))
    }
}
