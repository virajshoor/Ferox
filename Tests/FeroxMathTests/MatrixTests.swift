/// Tests for the matrix types in FeroxMath: Mat3 and Mat4 construction and algebra, inverses,
/// normal matrices, projection and view matrices (including reverse-Z depth), and Affine2D.
import Foundation
import XCTest

@testable import FeroxMath

private func assertVec3(
    _ a: Vec3, _ b: Vec3, accuracy: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
}

final class MatrixTests: XCTestCase {
    // The identity matrix maps points and directions to themselves.
    func testIdentityIsNeutral() {
        let p = Vec3(4, -2, 7)
        assertVec3(Mat4.identity.transformPoint(p), p, accuracy: 0)
        assertVec3(Mat4.identity.transformDirection(p), p, accuracy: 0)
    }

    // A translation moves points but leaves directions unchanged.
    func testTranslationMovesPointsNotDirections() {
        let m = Mat4.translation(Vec3(1, 2, 3))
        assertVec3(m.transformPoint(.zero), Vec3(1, 2, 3), accuracy: 0)
        assertVec3(m.transformDirection(Vec3(1, 0, 0)), Vec3(1, 0, 0), accuracy: 0)
    }

    // Multiplying two translations adds their offsets.
    func testTranslationsCompose() {
        let a = Vec3(1, 2, 3)
        let b = Vec3(-4, 0, 5)
        XCTAssertTrue((Mat4.translation(a) * Mat4.translation(b)).isApproximatelyEqual(to: .translation(a + b)))
    }

    // In a product, the right-hand matrix is applied first: translate(t) * scale(s) maps p to t + s * p.
    func testMultiplicationOrderIsRightThenLeft() {
        let m = Mat4.translation(Vec3(10, 0, 0)) * Mat4.scale(Vec3(2, 2, 2))
        assertVec3(m.transformPoint(Vec3(1, 1, 1)), Vec3(12, 2, 2), accuracy: 0)
    }

    // Inverting a general TRS matrix gives its inverse, both via inverse and affineInverse.
    func testInverseRoundTripForTRS() {
        let m = Mat4(
            translation: Vec3(3, -1, 2), rotation: Quat(angle: 0.8, axis: Vec3(1, 2, 0.5)), scale: Vec3(2, 0.5, 3))
        XCTAssertTrue((m * m.inverse).isApproximatelyEqual(to: .identity, tolerance: 1e-3))
        XCTAssertTrue(m.inverse.isApproximatelyEqual(to: m.affineInverse, tolerance: 1e-3))
    }

    // A singular matrix has no inverse, so inverse returns the zero matrix.
    func testSingularMatrixInverseIsZero() {
        let singular = Mat4(diagonal: Vec4(1, 0, 1, 1))
        XCTAssertEqual(singular.inverse, Mat4(diagonal: .zero))
    }

    // Transposing twice returns the original matrix exactly.
    func testDoubleTransposeIsIdentityOperation() {
        let m = Mat4(
            translation: Vec3(1, 2, 3), rotation: Quat(angle: 0.4, axis: Vec3(0, 0, 1)), scale: Vec3(1, 2, 3))
        XCTAssertEqual(m.transposed.transposed, m)
    }

    // The skew matrix of a vector multiplied by b equals the cross product a x b.
    func testSkewMatrixMatchesCrossProduct() {
        let a = Vec3(1, -2, 0.5)
        let b = Vec3(3, 4, -1)
        assertVec3(Mat3.skew(a) * b, a.cross(b))
    }

    // Mat3 determinant and inverse for a diagonal matrix.
    func testMat3DeterminantAndInverse() {
        let m = Mat3(diagonal: Vec3(2, 4, 8))
        XCTAssertEqual(m.determinant, 64, accuracy: 1e-4)
        assertVec3(m.inverse * Vec3(2, 4, 8), Vec3(1, 1, 1))
    }

    // The normal matrix is the inverse transpose, so normals stay perpendicular to a non-uniformly scaled surface.
    func testNormalMatrixUnderNonUniformScale() {
        let m = Mat4.scale(Vec3(2, 1, 1))
        // Tangent (1,-1,0) becomes (2,-1,0); the transformed normal (0.5,1,0) must stay perpendicular to it.
        let n = m.normalMatrix * Vec3(1, 1, 0)
        assertVec3(n, Vec3(0.5, 1, 0))
        XCTAssertEqual(n.dot(Vec3(2, -1, 0)), 0, accuracy: 1e-5)
    }

    // Reverse-Z perspective maps the near plane to depth 1 and the far plane to depth 0.
    func testReverseZPerspectiveDepthMapping() {
        let m = Mat4.perspective(fovY: .pi / 2, aspect: 1, near: 1, far: 100, reverseZ: true)
        XCTAssertEqual(m.transformPoint(Vec3(0, 0, -1)).z, 1, accuracy: 1e-4)
        XCTAssertEqual(m.transformPoint(Vec3(0, 0, -100)).z, 0, accuracy: 1e-4)
    }

    // Conventional perspective maps the near plane to depth 0 and the far plane to depth 1.
    func testConventionalPerspectiveDepthMapping() {
        let m = Mat4.perspective(fovY: .pi / 2, aspect: 1, near: 1, far: 100, reverseZ: false)
        XCTAssertEqual(m.transformPoint(Vec3(0, 0, -1)).z, 0, accuracy: 1e-4)
        XCTAssertEqual(m.transformPoint(Vec3(0, 0, -100)).z, 1, accuracy: 1e-4)
    }

    // A point on the view axis projects to the centre of the screen, and aspect ratio scales x.
    func testPerspectiveCentreAndAspectScaling() {
        let m = Mat4.perspective(fovY: .pi / 2, aspect: 2, near: 0.1, far: 100)
        let centre = m.transformPoint(Vec3(0, 0, -10))
        XCTAssertEqual(centre.x, 0, accuracy: 1e-5)
        XCTAssertEqual(centre.y, 0, accuracy: 1e-5)
        // With a 90 degree vertical fov and aspect 2, x is halved relative to y.
        XCTAssertEqual(m.transformPoint(Vec3(1, 0, -1)).x, 0.5, accuracy: 1e-4)
    }

    // lookAt puts the eye at the origin and the target on the negative Z axis in view space.
    func testLookAtPlacesEyeAtOriginAndTargetInFront() {
        let view = Mat4.lookAt(eye: Vec3(0, 0, 5), target: .zero)
        assertVec3(view.transformPoint(Vec3(0, 0, 5)), .zero)
        assertVec3(view.transformPoint(.zero), Vec3(0, 0, -5))
    }

    // lookAt works for an off-axis eye: the target is 5 units straight ahead in view space.
    func testLookAtOffAxisTargetLiesAhead() {
        let view = Mat4.lookAt(eye: Vec3(3, 4, 5), target: Vec3(3, 4, 0))
        assertVec3(view.transformPoint(Vec3(3, 4, 0)), Vec3(0, 0, -5))
    }

    // An orthographic projection maps a corner of its box to the corresponding corner of clip space.
    func testOrthographicMapsBoxCornerToClipCorner() {
        let m = Mat4.orthographic(
            left: -2, right: 2, bottom: -1, top: 1, near: 1, far: 11, reverseZ: false)
        // The near-plane corner (2, 1, -1) maps to the top-right of clip space at depth 0.
        assertVec3(m.transformPoint(Vec3(2, 1, -1)), Vec3(1, 1, 0))
    }

    // A 2D affine transform with a rotation maps the x-axis point onto the y-axis, shifted by its translation.
    func testAffine2DRotationAndTranslation() {
        let t = Affine2D(translation: Vec2(1, 0), rotation: .pi / 2, scale: Vec2(1, 1))
        let p = t.apply(Vec2(1, 0))
        XCTAssertEqual(p.x, 1, accuracy: 1e-5)
        XCTAssertEqual(p.y, 1, accuracy: 1e-5)
        let back = t.inverse.apply(p)
        XCTAssertEqual(back.x, 1, accuracy: 1e-5)
        XCTAssertEqual(back.y, 0, accuracy: 1e-5)
    }
}
