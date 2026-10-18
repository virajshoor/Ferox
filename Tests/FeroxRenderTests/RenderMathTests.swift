/// Tests for the platform-independent rendering maths in `RenderMath`: temporal jitter,
/// cascade splits and stable shadow matrices, exposure, white balance, clustered slices,
/// LOD screen size, bounding spheres and dispatch helpers.
import XCTest
import Ferox
@testable import FeroxRender

final class RenderMathTests: XCTestCase {
    // The Halton sequence matches its textbook values and stays in [0, 1).
    func testHaltonKnownValues() {
        XCTAssertEqual(RenderMath.halton(0, base: 2), 0)
        XCTAssertEqual(RenderMath.halton(1, base: 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RenderMath.halton(2, base: 2), 0.25, accuracy: 1e-6)
        XCTAssertEqual(RenderMath.halton(3, base: 2), 0.75, accuracy: 1e-6)
        XCTAssertEqual(RenderMath.halton(1, base: 3), 1.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(RenderMath.halton(2, base: 3), 2.0 / 3, accuracy: 1e-6)
        for i in 0..<256 {
            let v = RenderMath.halton(i, base: 3)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }

    // Jitter stays within half a pixel, cycles with the phase count and is never all zero.
    func testJitterIsSubPixelAndPeriodic() {
        let w = 1920, h = 1080, phases = 8
        var seen: [Vec2] = []
        for frame in UInt64(0)..<UInt64(phases) {
            let j = RenderMath.jitter(frame: frame, phases: phases, renderWidth: w, renderHeight: h)
            XCTAssertLessThanOrEqual(abs(j.x), 1 / Float(w) + 1e-7, "at most half a pixel in clip units")
            XCTAssertLessThanOrEqual(abs(j.y), 1 / Float(h) + 1e-7)
            seen.append(j)
        }
        let again = RenderMath.jitter(frame: UInt64(phases), phases: phases, renderWidth: w, renderHeight: h)
        XCTAssertEqual(again, seen[0])
        XCTAssertEqual(Set(seen.map { "\($0.x),\($0.y)" }).count, phases, "every phase is distinct")
    }

    // Degenerate jitter inputs do not divide by zero.
    func testJitterDegenerateInputs() {
        let j = RenderMath.jitter(frame: 3, phases: 0, renderWidth: 0, renderHeight: 0)
        XCTAssertTrue(j.x.isFinite && j.y.isFinite)
    }

    // Splits start at near, end exactly at far and increase monotonically.
    func testCascadeSplits() {
        for count in 1...4 {
            let s = RenderMath.cascadeSplits(near: 0.1, far: 200, count: count)
            XCTAssertEqual(s.count, count + 1)
            XCTAssertEqual(s.first!, 0.1, accuracy: 1e-6)
            XCTAssertEqual(s.last!, 200)
            for i in 1..<s.count { XCTAssertGreaterThan(s[i], s[i - 1]) }
        }
        // lambda 0 is uniform, lambda 1 is logarithmic.
        let uniform = RenderMath.cascadeSplits(near: 1, far: 101, count: 2, lambda: 0)
        XCTAssertEqual(uniform[1], 51, accuracy: 1e-3)
        let logarithmic = RenderMath.cascadeSplits(near: 1, far: 100, count: 2, lambda: 1)
        XCTAssertEqual(logarithmic[1], 10, accuracy: 1e-3)
    }

    // Counts outside 1...4 and inverted ranges are clamped.
    func testCascadeSplitsClamp() {
        XCTAssertEqual(RenderMath.cascadeSplits(near: 0.1, far: 100, count: 9).count, 5)
        XCTAssertEqual(RenderMath.cascadeSplits(near: 0.1, far: 100, count: 0).count, 2)
        let inverted = RenderMath.cascadeSplits(near: 10, far: 1, count: 2)
        XCTAssertGreaterThan(inverted.last!, inverted.first!)
    }

    // Slice corners at the camera's near and far distances are the frustum corners.
    func testFrustumSliceCornersMatchFrustum() {
        let cam = Camera.perspective(fov: 60, near: 0.5, far: 50)
        let rc = RenderCamera(entity: .null, camera: cam, worldMatrix: .identity, aspect: 16.0 / 9)
        let inv = rc.viewProjection.inverse
        let corners = RenderMath.frustumSliceCorners(inverseViewProjection: inv, near: 0.5, far: 50, from: 0.5, to: 50)
        XCTAssertEqual(corners.count, 8)
        // Camera at the origin looking down -Z: near corners at z = -0.5, far at z = -50.
        let zs = corners.map(\.z).sorted()
        XCTAssertEqual(zs.first!, -50, accuracy: 1e-2)
        XCTAssertEqual(zs.last!, -0.5, accuracy: 1e-3)
        // A mid slice lies between them.
        let mid = RenderMath.frustumSliceCorners(inverseViewProjection: inv, near: 0.5, far: 50, from: 5, to: 10)
        for c in mid { XCTAssertTrue((-10.01)...(-4.99) ~= c.z, "z \(c.z)") }
    }

    // Every slice corner projects inside the light's clip volume.
    func testStableCascadeMatrixCoversCorners() {
        let corners = [Vec3(-1, -1, -1), Vec3(1, -1, -1), Vec3(-1, 1, -1), Vec3(1, 1, -1),
                       Vec3(-2, -2, -5), Vec3(2, -2, -5), Vec3(-2, 2, -5), Vec3(2, 2, -5)]
        let towardsLight = Vec3(0.3, 1, 0.2).normalized
        let m = RenderMath.stableCascadeMatrix(corners: corners, towardsLight: towardsLight, resolution: 2048)
        for c in corners {
            let p = m * Vec4(c, 1)
            XCTAssertTrue(abs(p.x / p.w) <= 1.001 && abs(p.y / p.w) <= 1.001, "corner \(c) outside xy")
            XCTAssertTrue((-0.001...1.001) ~= p.z / p.w, "corner \(c) outside depth range")
        }
    }

    // Translating the slice by a fraction of a texel moves the projection by whole texels.
    func testStableCascadeMatrixSnapsToTexels() {
        let base: [Vec3] = [Vec3(-4, -4, -4), Vec3(4, 4, 4)]
        let res = 1024
        let a = RenderMath.stableCascadeMatrix(corners: base, towardsLight: .up, resolution: res)
        let shifted = base.map { $0 + Vec3(0.0031, 0, 0.0017) }
        let b = RenderMath.stableCascadeMatrix(corners: shifted, towardsLight: .up, resolution: res)
        // The origin's projection lands on the texel grid in both matrices.
        for m in [a, b] {
            let o = m * Vec4(0, 0, 0, 1)
            let tx = o.x * Float(res) * 0.5, ty = o.y * Float(res) * 0.5
            XCTAssertEqual(tx, tx.rounded(), accuracy: 2e-2)
            XCTAssertEqual(ty, ty.rounded(), accuracy: 2e-2)
        }
    }

    // A vertical light direction (parallel to the default up vector) still yields a matrix.
    func testStableCascadeMatrixHandlesDegenerateInput() {
        XCTAssertEqual(RenderMath.stableCascadeMatrix(corners: [], towardsLight: .up, resolution: 512), .identity)
        let m = RenderMath.stableCascadeMatrix(corners: [Vec3(0, 0, 0), Vec3(1, 1, 1)], towardsLight: Vec3(0, 1, 0),
                                               resolution: 512)
        XCTAssertTrue(m.c0.x.isFinite && m.c3.w.isFinite)
        let z = RenderMath.stableCascadeMatrix(corners: [Vec3(0, 0, 0)], towardsLight: .zero, resolution: 512)
        XCTAssertTrue(z.c0.x.isFinite)
    }

    // EV100 0 gives 1/1.2; each EV step halves the exposure.
    func testExposure() {
        XCTAssertEqual(RenderMath.exposure(ev100: 0), 1 / 1.2, accuracy: 1e-6)
        XCTAssertEqual(RenderMath.exposure(ev100: 1) * 2, RenderMath.exposure(ev100: 0), accuracy: 1e-6)
    }

    // Neutral white balance is (approximately) the identity; warming boosts long cones.
    func testWhiteBalance() {
        let neutral = RenderMath.whiteBalanceLMS(temperature: 0, tint: 0)
        XCTAssertEqual(neutral.x, 1, accuracy: 0.02)
        XCTAssertEqual(neutral.y, 1, accuracy: 0.02)
        XCTAssertEqual(neutral.z, 1, accuracy: 0.02)
        let warm = RenderMath.whiteBalanceLMS(temperature: 50, tint: 0)
        XCTAssertGreaterThan(warm.x / warm.z, neutral.x / neutral.z)
        // Out-of-range inputs are clamped, so the result stays finite.
        let extreme = RenderMath.whiteBalanceLMS(temperature: 1e6, tint: -1e6)
        XCTAssertTrue(extreme.x.isFinite && extreme.y.isFinite && extreme.z.isFinite)
    }

    // Depths at near and far map to the first and last cluster slice; slices are monotonic.
    func testClusterSlices() {
        let slices = 24
        let p = RenderMath.clusterParams(near: 0.1, far: 500, slices: slices)
        XCTAssertEqual(RenderMath.clusterSlice(viewDepth: 0.1, params: p, slices: slices), 0)
        XCTAssertEqual(RenderMath.clusterSlice(viewDepth: 500, params: p, slices: slices), slices - 1)
        XCTAssertEqual(RenderMath.clusterSlice(viewDepth: 1e6, params: p, slices: slices), slices - 1)
        XCTAssertEqual(RenderMath.clusterSlice(viewDepth: 0, params: p, slices: slices), 0)
        var last = 0
        for d in stride(from: Float(0.1), through: 500, by: 0.5) {
            let s = RenderMath.clusterSlice(viewDepth: d, params: p, slices: slices)
            XCTAssertGreaterThanOrEqual(s, last)
            last = s
        }
    }

    // Screen fraction halves when the distance doubles; orthographic ignores distance.
    func testScreenHeightFraction() {
        let fov: Float = .pi / 2
        let near = RenderMath.screenHeightFraction(radius: 1, distance: 10, fovY: fov)
        let far = RenderMath.screenHeightFraction(radius: 1, distance: 20, fovY: fov)
        XCTAssertEqual(near, far * 2, accuracy: 1e-5)
        XCTAssertEqual(RenderMath.screenHeightFraction(radius: 1, distance: 1000, fovY: fov, orthoSize: 4), 0.25)
        XCTAssertTrue(RenderMath.screenHeightFraction(radius: 1, distance: 0, fovY: fov).isFinite)
    }

    // Packed planes are unit length.
    func testPackedPlanesAreNormalised() {
        let rc = RenderCamera(entity: .null, camera: .perspective(), worldMatrix: .identity, aspect: 1.5)
        let p = RenderMath.packedPlanes(Frustum(viewProjection: rc.viewProjection))
        for v in [p.0, p.1, p.2, p.3, p.4, p.5] {
            XCTAssertEqual(Vec3(v.x, v.y, v.z).length, 1, accuracy: 1e-4)
        }
    }

    // The bounding sphere contains every transformed box corner.
    func testBoundingSphereContainsBox() {
        let box = AABB(min: Vec3(-1, -2, -0.5), max: Vec3(3, 1, 0.5))
        let m = Mat4(translation: Vec3(5, -3, 2), rotation: Quat(pitch: 0.3, yaw: 1.1, roll: -0.4), scale: Vec3(2, 0.5, 3))
        let s = RenderMath.boundingSphere(box, m)
        for x in [box.min.x, box.max.x] {
            for y in [box.min.y, box.max.y] {
                for z in [box.min.z, box.max.z] {
                    let p = m.transformPoint(Vec3(x, y, z))
                    XCTAssertLessThanOrEqual(p.distance(to: s.center), s.radius + 1e-4)
                }
            }
        }
        XCTAssertEqual(RenderMath.boundingSphere(.empty, m).radius, 0)
    }

    // Mip chains and dispatch counts.
    func testMipCountAndGroups() {
        XCTAssertEqual(RenderMath.mipCount(1, 1), 1)
        XCTAssertEqual(RenderMath.mipCount(256, 256), 9)
        XCTAssertEqual(RenderMath.mipCount(1920, 1080), 11)
        XCTAssertEqual(RenderMath.groups(0, 64), 0)
        XCTAssertEqual(RenderMath.groups(1, 64), 1)
        XCTAssertEqual(RenderMath.groups(64, 64), 1)
        XCTAssertEqual(RenderMath.groups(65, 64), 2)
        XCTAssertEqual(RenderMath.groups(-5, 64), 0)
        XCTAssertEqual(RenderMath.groups(10, 0), 10, "a zero group size is treated as one")
    }
}
