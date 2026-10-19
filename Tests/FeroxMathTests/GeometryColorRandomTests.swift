/// Tests for FeroxMath geometry (AABB, rays, spheres, planes, frustum), colour conversions
/// (sRGB, hex, HSV) and the deterministic random number generators (PCG32 and Halton).
import Foundation
import XCTest

@testable import FeroxMath

final class GeometryTests: XCTestCase {
    // AABB(center:extents:) builds the min/max corners, with size and surface area derived from them.
    func testAABBFromCenterAndExtents() {
        let box = AABB(center: .zero, extents: Vec3(1, 2, 3))
        XCTAssertEqual(box.min, Vec3(-1, -2, -3))
        XCTAssertEqual(box.size, Vec3(2, 4, 6))
        XCTAssertEqual(box.surfaceArea, 88, accuracy: 1e-4)
    }

    // Expanding the empty box by points grows it to the bounds of those points.
    func testEmptyBoxExpandsToCoverPoints() {
        XCTAssertTrue(AABB.empty.isEmpty)
        var box = AABB.empty
        box.expand(Vec3(1, 2, 3))
        box.expand(Vec3(-1, 0, 5))
        XCTAssertEqual(box.min, Vec3(-1, 0, 3))
        XCTAssertEqual(box.max, Vec3(1, 2, 5))
        XCTAssertFalse(box.isEmpty)
    }

    // Containment is inclusive of the faces, and boxes that merely touch still intersect.
    func testContainsAndIntersects() {
        let a = AABB(min: .zero, max: Vec3(1, 1, 1))
        XCTAssertTrue(a.contains(Vec3(0.5, 0.5, 0.5)))
        XCTAssertFalse(a.contains(Vec3(1.5, 0.5, 0.5)))
        XCTAssertTrue(a.intersects(AABB(min: Vec3(1, 0, 0), max: Vec3(2, 1, 1))))
        XCTAssertFalse(a.intersects(AABB(min: Vec3(1.1, 0, 0), max: Vec3(2, 1, 1))))
    }

    // Transforming a box by a translation moves its centre and keeps its extents.
    func testTransformedByTranslation() {
        let box = AABB(center: .zero, extents: Vec3(1, 1, 1)).transformed(by: .translation(Vec3(5, 0, 0)))
        XCTAssertEqual(box.center.x, 5, accuracy: 1e-5)
        XCTAssertEqual(box.extents.x, 1, accuracy: 1e-5)
    }

    // A box rotated a quarter turn about +Z has its x and y extents swapped.
    func testTransformedByRotationEnclosesRotatedBox() {
        let box = AABB(center: .zero, extents: Vec3(2, 1, 1))
        let m = Mat4.rotation(Quat(angle: .pi / 2, axis: Vec3(0, 0, 1)))
        let e = box.transformed(by: m).extents
        XCTAssertEqual(e.x, 1, accuracy: 1e-4)
        XCTAssertEqual(e.y, 2, accuracy: 1e-4)
        XCTAssertEqual(e.z, 1, accuracy: 1e-4)
    }

    // A ray from outside the box returns its entry distance; a ray pointing away misses.
    func testRayHitsAABBAtEntryDistance() {
        let box = AABB(min: Vec3(-1, -1, -1), max: Vec3(1, 1, 1))
        let hit = box.intersect(Ray(origin: Vec3(-5, 0, 0), direction: Vec3(1, 0, 0)))
        XCTAssertEqual(hit ?? -1, 4, accuracy: 1e-5)
        XCTAssertNil(box.intersect(Ray(origin: Vec3(-5, 0, 0), direction: Vec3(-1, 0, 0))))
        XCTAssertNil(box.intersect(Ray(origin: Vec3(-5, 0, 0), direction: Vec3(1, 0, 0)), maxDistance: 3))
    }

    // Ray construction normalises the direction vector.
    func testRayDirectionIsNormalised() {
        let ray = Ray(origin: .zero, direction: Vec3(0, 0, -10))
        XCTAssertEqual(ray.direction, Vec3(0, 0, -1))
        XCTAssertEqual(ray.point(at: 3), Vec3(0, 0, -3))
    }

    // A ray hits a sphere at the near surface, misses when offset, and reports zero when starting inside.
    func testRaySphereIntersection() {
        let sphere = Sphere(center: Vec3(0, 0, -5), radius: 1)
        let forward = Ray(origin: .zero, direction: Vec3(0, 0, -1))
        XCTAssertEqual(sphere.intersect(forward) ?? -1, 4, accuracy: 1e-5)
        XCTAssertNil(sphere.intersect(Ray(origin: .zero, direction: Vec3(0, 1, 0))))
        XCTAssertEqual(Sphere(center: .zero, radius: 2).intersect(forward) ?? -1, 0, accuracy: 1e-6)
    }

    // A ray hits a horizontal plane at the expected distance, and misses when parallel or pointing away.
    func testRayPlaneIntersection() {
        let ground = Plane(normal: Vec3.up, d: 0)
        XCTAssertEqual(ground.intersect(Ray(origin: Vec3(0, 5, 0), direction: Vec3(0, -1, 0))) ?? -1, 5, accuracy: 1e-5)
        XCTAssertNil(ground.intersect(Ray(origin: Vec3(0, 5, 0), direction: Vec3(1, 0, 0))))
        XCTAssertNil(ground.intersect(Ray(origin: Vec3(0, 5, 0), direction: Vec3(0, 1, 0))))
    }

    // Signed distance is positive on the normal side of a plane built from a point.
    func testPlaneSignedDistance() {
        let plane = Plane(normal: Vec3(0, 2, 0), point: Vec3(0, 1, 0))
        XCTAssertEqual(plane.signedDistance(Vec3(0, 4, 0)), 3, accuracy: 1e-5)
        XCTAssertEqual(Plane(coefficients: Vec4(0, 2, 0, -4)).signedDistance(Vec3(0, 2, 0)), 0, accuracy: 1e-5)
    }

    // A frustum built from a camera projection contains points in front of it and rejects points behind it.
    func testFrustumContainsSphereInFrontAndRejectsBehind() {
        let proj = Mat4.perspective(fovY: .pi / 2, aspect: 1, near: 0.1, far: 100)
        let frustum = Frustum(viewProjection: proj)
        XCTAssertTrue(frustum.contains(Sphere(center: Vec3(0, 0, -10), radius: 1)))
        XCTAssertFalse(frustum.contains(Sphere(center: Vec3(0, 0, 10), radius: 1)))
        XCTAssertFalse(frustum.contains(Sphere(center: Vec3(100, 0, -1), radius: 0.5)))
    }

    // The frustum AABB test accepts boxes in view and rejects boxes behind the camera.
    func testFrustumIntersectsAABB() {
        let frustum = Frustum(viewProjection: Mat4.perspective(fovY: .pi / 2, aspect: 1, near: 0.1, far: 100))
        XCTAssertTrue(frustum.intersects(AABB(center: Vec3(0, 0, -10), extents: Vec3(1, 1, 1))))
        XCTAssertFalse(frustum.intersects(AABB(center: Vec3(0, 0, 10), extents: Vec3(1, 1, 1))))
    }
}

final class ColorTests: XCTestCase {
    // Converting sRGB to linear and back recovers the original component.
    func testSRGBRoundTrip() {
        for c: Float in [0, 0.25, 0.5, 0.8, 1] {
            XCTAssertEqual(Color.linearToSrgb(Color.srgbToLinear(c)), c, accuracy: 1e-5)
        }
        XCTAssertEqual(Color.srgbToLinear(1), 1, accuracy: 1e-6)
    }

    // A hex colour decodes to the matching sRGB components, with opaque alpha by default.
    func testHexDecodesToSRGBComponents() {
        let s = Color(hex: 0x3366CC).srgb
        XCTAssertEqual(s.x, Float(0x33) / 255, accuracy: 1e-5)
        XCTAssertEqual(s.y, Float(0x66) / 255, accuracy: 1e-5)
        XCTAssertEqual(s.z, Float(0xCC) / 255, accuracy: 1e-5)
        XCTAssertEqual(s.w, 1)
    }

    // An RRGGBBAA hex value keeps its alpha channel when hasAlpha is set.
    func testHexWithAlpha() {
        let c = Color(hex: 0x1122_3380, hasAlpha: true)
        XCTAssertEqual(c.a, Float(0x80) / 255, accuracy: 1e-5)
    }

    // The Ferox accent is the sRGB value #FF5A1F, stored in linear space.
    func testFeroxAccentMatchesBrandHex() {
        let s = Color.feroxAccent.srgb
        XCTAssertEqual(s.x, 1, accuracy: 1e-5)
        XCTAssertEqual(s.y, Float(0x5A) / 255, accuracy: 1e-5)
        XCTAssertEqual(s.z, Float(0x1F) / 255, accuracy: 1e-5)
    }

    // HSV hue 0 gives red and hue 1/3 gives green at full saturation and value.
    func testHSVPrimaries() {
        XCTAssertEqual(Color.hsv(0, 1, 1).rgb, Vec3(1, 0, 0))
        let green = Color.hsv(1.0 / 3.0, 1, 1).rgb
        XCTAssertEqual(green.y, 1, accuracy: 1e-5)
        XCTAssertEqual(green.x, 0, accuracy: 1e-5)
        XCTAssertEqual(green.z, 0, accuracy: 1e-5)
    }

    // Premultiplied colour scales RGB by alpha and keeps alpha unchanged.
    func testPremultipliedScalesRGB() {
        XCTAssertEqual(Color(1, 1, 1, 0.5).premultiplied, Vec4(0.5, 0.5, 0.5, 0.5))
    }

    // Luminance uses Rec. 709 weights, so white has luminance 1 and black has 0.
    func testLuminanceWeights() {
        XCTAssertEqual(Color.white.luminance, 1, accuracy: 1e-6)
        XCTAssertEqual(Color.black.luminance, 0, accuracy: 1e-6)
    }

    // Linear interpolation between colours blends each channel, including alpha.
    func testLerpBlendsChannels() {
        let c = Color.black.lerp(to: Color.white.withAlpha(0), 0.25)
        XCTAssertEqual(c.r, 0.25, accuracy: 1e-6)
        XCTAssertEqual(c.a, 0.75, accuracy: 1e-6)
    }
}

final class RandomTests: XCTestCase {
    // Two generators with the same seed and stream produce identical sequences.
    func testSameSeedProducesSameSequence() {
        var a = PCG32(seed: 12345)
        var b = PCG32(seed: 12345)
        for _ in 0..<200 {
            XCTAssertEqual(a.nextUInt32(), b.nextUInt32())
        }
    }

    // A different seed or stream produces a different first value.
    func testDifferentSeedOrStreamDiffers() {
        var a = PCG32(seed: 1)
        var b = PCG32(seed: 2)
        var c = PCG32(seed: 1, stream: 99)
        let first = a.nextUInt32()
        XCTAssertNotEqual(first, b.nextUInt32())
        XCTAssertNotEqual(first, c.nextUInt32())
    }

    // Copying a generator forks an identical continuation of the sequence.
    func testCopiedGeneratorContinuesIdentically() {
        var original = PCG32(seed: 7)
        _ = original.nextUInt32()
        var copy = original
        for _ in 0..<50 {
            XCTAssertEqual(original.nextFloat(), copy.nextFloat())
        }
    }

    // nextFloat stays in the half-open interval [0, 1).
    func testNextFloatStaysInUnitInterval() {
        var rng = PCG32(seed: 99)
        for _ in 0..<1000 {
            let f = rng.nextFloat()
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThan(f, 1)
        }
    }

    // nextFloat(in:) stays within the requested closed range.
    func testNextFloatInRangeStaysInBounds() {
        var rng = PCG32(seed: 3)
        for _ in 0..<1000 {
            let f = rng.nextFloat(in: -2...3)
            XCTAssertGreaterThanOrEqual(f, -2)
            XCTAssertLessThanOrEqual(f, 3)
        }
    }

    // Random unit vectors have length one within floating-point tolerance.
    func testUnitVectorsAreNormalised() {
        var rng = PCG32(seed: 5)
        for _ in 0..<100 {
            XCTAssertEqual(rng.nextUnitVector().length, 1, accuracy: 1e-4)
        }
    }

    // The standard library's random API is deterministic when driven by a seeded PCG32.
    func testStandardLibraryRandomIsDeterministic() {
        var a = PCG32(seed: 42)
        var b = PCG32(seed: 42)
        XCTAssertEqual(Int.random(in: 0..<1_000_000, using: &a), Int.random(in: 0..<1_000_000, using: &b))
    }

    // The Halton sequence gives 0.5, 0.25 and 0.75 for the first three base-2 indices.
    func testHaltonBaseTwoValues() {
        XCTAssertEqual(Halton.value(index: 1, base: 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Halton.value(index: 2, base: 2), 0.25, accuracy: 1e-6)
        XCTAssertEqual(Halton.value(index: 3, base: 2), 0.75, accuracy: 1e-6)
    }

    // The first (2, 3) Halton jitter point is centred on zero in x and at -1/6 in y.
    func testHaltonJitterIsCentred() {
        let j = Halton.jitter(index: 0)
        XCTAssertEqual(j.x, 0, accuracy: 1e-6)
        XCTAssertEqual(j.y, -1.0 / 6.0, accuracy: 1e-5)
    }
}
