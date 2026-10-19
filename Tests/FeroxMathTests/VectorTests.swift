/// Tests for the SIMD vector extensions in FeroxMath (arithmetic, dot and cross products,
/// length and normalisation, 2D helpers) and the scalar helpers on `Float`.
import Foundation
import XCTest

@testable import FeroxMath

private func assertVec3(
    _ a: Vec3, _ b: Vec3, accuracy: Float = 1e-5, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
}

final class VectorTests: XCTestCase {
    // Addition, subtraction and scalar multiplication act per component.
    func testArithmeticIsComponentWise() {
        let a = Vec3(1, 2, 3)
        let b = Vec3(4, 5, 6)
        XCTAssertEqual(a + b, Vec3(5, 7, 9))
        XCTAssertEqual(b - a, Vec3(3, 3, 3))
        XCTAssertEqual(a * 2, Vec3(2, 4, 6))
    }

    // The dot product sums component products.
    func testDotProductSumsComponentProducts() {
        XCTAssertEqual(Vec3(1, 2, 3).dot(Vec3(4, 5, 6)), 32)
    }

    // The cross product of right and up follows the right-hand rule and is anticommutative.
    func testCrossProductFollowsRightHandRule() {
        XCTAssertEqual(Vec3.right.cross(Vec3.up), Vec3(0, 0, 1))
        XCTAssertEqual(Vec3.up.cross(Vec3.right), Vec3(0, 0, -1))
    }

    // The cross product is orthogonal to both of its operands.
    func testCrossProductIsPerpendicularToOperands() {
        let a = Vec3(1, 2, 3)
        let b = Vec3(-2, 0, 5)
        let c = a.cross(b)
        XCTAssertEqual(c.dot(a), 0, accuracy: 1e-4)
        XCTAssertEqual(c.dot(b), 0, accuracy: 1e-4)
    }

    // A 3-4-0 vector has length 5 and normalises to a unit vector.
    func testLengthAndNormalisation() {
        let v = Vec3(3, 4, 0)
        XCTAssertEqual(v.length, 5, accuracy: 1e-6)
        assertVec3(v.normalized, Vec3(0.6, 0.8, 0))
        XCTAssertEqual(v.normalized.length, 1, accuracy: 1e-6)
    }

    // Normalising a degenerate (zero) vector returns zero rather than NaN.
    func testNormalisingZeroVectorReturnsZero() {
        XCTAssertEqual(Vec3.zero.normalized, Vec3.zero)
    }

    // Linear interpolation and distance behave as expected for collinear points.
    func testLerpAndDistance() {
        assertVec3(Vec3.zero.lerp(to: Vec3(10, 0, 0), 0.25), Vec3(2.5, 0, 0))
        XCTAssertEqual(Vec3.zero.distance(to: Vec3(0, 3, 4)), 5, accuracy: 1e-6)
    }

    // Absolute value and tolerance-based comparison respect the per-component tolerance.
    func testAbsoluteAndApproximateEquality() {
        XCTAssertEqual(Vec3(-1, 2, -3).absolute, Vec3(1, 2, 3))
        XCTAssertTrue(Vec3(1.0005, 2, 3).isApproximatelyEqual(to: Vec3(1, 2, 3), tolerance: 1e-3))
        XCTAssertFalse(Vec3(1.002, 2, 3).isApproximatelyEqual(to: Vec3(1, 2, 3), tolerance: 1e-3))
    }

    // Vec2.perpendicular is the +90 degree rotation, and rotated(by:) agrees with it at pi/2.
    func testVec2PerpendicularAndRotation() {
        XCTAssertEqual(Vec2(1, 0).perpendicular, Vec2(0, 1))
        let r = Vec2(1, 0).rotated(by: .pi / 2)
        XCTAssertEqual(r.x, 0, accuracy: 1e-6)
        XCTAssertEqual(r.y, 1, accuracy: 1e-6)
    }

    // The 2D cross product is positive for a counter-clockwise pair.
    func testVec2CrossIsSignedArea() {
        XCTAssertEqual(Vec2(1, 0).cross(Vec2(0, 1)), 1)
        XCTAssertEqual(Vec2(0, 1).cross(Vec2(1, 0)), -1)
    }

    // anyPerpendicular returns a unit vector orthogonal to its input for each principal axis.
    func testAnyPerpendicularIsUnitAndOrthogonal() {
        for axis in [Vec3.up, Vec3.right, Vec3(0, 0, 1)] {
            let p = axis.anyPerpendicular
            XCTAssertEqual(p.length, 1, accuracy: 1e-5)
            XCTAssertEqual(p.dot(axis), 0, accuracy: 1e-5)
        }
    }

    // The forward direction is the -Z axis (right-handed, glTF convention).
    func testForwardIsNegativeZ() {
        assertVec3(Vec3.forward, Vec3(0, 0, -1), accuracy: 0)
    }

    // Vec4 can be built from Vec3 plus w and exposes its xyz part.
    func testVec4ConstructionAndXYZ() {
        let v = Vec4(Vec3(1, 2, 3), 4)
        XCTAssertEqual(v, Vec4(1, 2, 3, 4))
        XCTAssertEqual(v.xyz, Vec3(1, 2, 3))
    }

    // Float helpers: lerp, clamping and saturation.
    func testScalarLerpAndClamping() {
        XCTAssertEqual(Float.lerp(0, 10, 0.3), 3, accuracy: 1e-5)
        XCTAssertEqual(Float(1.5).clamped(0, 1), 1)
        XCTAssertEqual(Float(-0.2).saturated, 0)
    }

    // Degree and radian conversions are inverses of each other at the usual reference angles.
    func testDegreeRadianConversion() {
        XCTAssertEqual(Float(180).radians, .pi, accuracy: 1e-5)
        XCTAssertEqual(Float.pi.degrees, 180, accuracy: 1e-3)
    }

    // Smoothstep is 0 and 1 at its edges, 0.5 at the midpoint, and clamped outside.
    func testSmoothstepEdgesAndMidpoint() {
        XCTAssertEqual(Float.smoothstep(0, 1, 0), 0)
        XCTAssertEqual(Float.smoothstep(0, 1, 1), 1)
        XCTAssertEqual(Float.smoothstep(0, 1, 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Float.smoothstep(0, 1, 2), 1)
    }

    // Damping gives 0 for a zero rate and 1 - e^-1 for unit rate over unit time.
    func testDampingFactor() {
        XCTAssertEqual(Float.damping(rate: 0, dt: 1), 0)
        XCTAssertEqual(Float.damping(rate: 1, dt: 1), 1 - Float(exp(-1.0)), accuracy: 1e-6)
    }
}
