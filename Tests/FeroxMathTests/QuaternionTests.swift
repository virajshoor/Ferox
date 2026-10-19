/// Tests for rotations in FeroxMath: quaternion construction, composition, rotation of
/// vectors, look-rotations, slerp/nlerp, Euler angles, and the TRS transform value type.
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

final class QuaternionTests: XCTestCase {
    // The identity quaternion leaves vectors unchanged.
    func testIdentityLeavesVectorsUnchanged() {
        assertVec3(Quat.identity.act(Vec3(1, 2, 3)), Vec3(1, 2, 3))
    }

    // A quarter turn about +Y takes +X to -Z (right-handed rotation).
    func testQuarterTurnAboutYMapsXToNegativeZ() {
        assertVec3(Quat(angle: .pi / 2, axis: Vec3(0, 1, 0)).act(Vec3(1, 0, 0)), Vec3(0, 0, -1))
    }

    // The axis passed to the axis-angle initialiser is normalised internally.
    func testAxisIsNormalisedByInitialiser() {
        assertVec3(Quat(angle: .pi / 2, axis: Vec3(0, 0, 5)).act(Vec3(1, 0, 0)), Vec3(0, 1, 0))
    }

    // Quaternion multiplication composes rotations: (a * b) applied to v equals a applied to (b applied to v).
    func testMultiplicationComposesRightToLeft() {
        let a = Quat(angle: .pi / 2, axis: Vec3(0, 0, 1))
        let b = Quat(angle: .pi / 2, axis: Vec3(0, 1, 0))
        let v = Vec3(1, 0.5, -2)
        assertVec3((a * b).act(v), a.act(b.act(v)))
    }

    // A rotation followed by its inverse returns the original vector.
    func testInverseUndoesRotation() {
        let q = Quat(angle: 0.7, axis: Vec3(1, 2, 3))
        XCTAssertTrue((q.inverse * q).isApproximatelyEqual(to: .identity))
        assertVec3(q.inverse.act(q.act(Vec3(0.3, -1, 2))), Vec3(0.3, -1, 2))
    }

    // normalized restores unit length, and a zero quaternion degrades to identity.
    func testNormalisation() {
        let q = Quat(x: 0, y: 0, z: 0, w: 2).normalized
        XCTAssertEqual(q.w, 1, accuracy: 1e-6)
        XCTAssertEqual(Quat(x: 0, y: 0, z: 0, w: 0).normalized, .identity)
    }

    // The angle between two rotations about the same axis equals the difference of their angles.
    func testAngleBetweenRotations() {
        let q = Quat(angle: 1.0, axis: Vec3(0, 1, 0))
        XCTAssertEqual(Quat.identity.angle(to: q), 1.0, accuracy: 1e-4)
    }

    // Quat(from:to:) produces the shortest rotation taking one unit vector onto another.
    func testFromToRotatesOneVectorOntoAnother() {
        let q = Quat(from: Vec3(1, 0, 0), to: Vec3(0, 1, 0))
        assertVec3(q.act(Vec3(1, 0, 0)), Vec3(0, 1, 0))
    }

    // Opposite vectors are handled by a half turn around a perpendicular axis.
    func testFromToOppositeVectorsIsHalfTurn() {
        let q = Quat(from: Vec3(0, 0, -1), to: Vec3(0, 0, 1))
        assertVec3(q.act(Vec3(0, 0, -1)), Vec3(0, 0, 1))
    }

    // lookRotation makes the rotated forward axis point at the requested direction.
    func testLookRotationAimsForwardAxis() {
        let f = Vec3(1, 0, 0)
        assertVec3(Quat.lookRotation(forward: f).act(Vec3.forward), f)
    }

    // Converting a rotation to a matrix and back yields the same rotation.
    func testRotationMatrixRoundTrip() {
        let q = Quat(angle: 0.9, axis: Vec3(1, 1, 0))
        let back = Quat(rotationMatrix: Mat3(q))
        XCTAssertTrue(back.isApproximatelyEqual(to: q))
    }

    // Slerp returns its endpoints at t = 0 and t = 1, and halfway through the angle at t = 0.5.
    func testSlerpEndpointsAndHalfway() {
        let q1 = Quat(angle: .pi / 2, axis: Vec3(0, 1, 0))
        XCTAssertTrue(Quat.identity.slerp(to: q1, 0).isApproximatelyEqual(to: .identity))
        XCTAssertTrue(Quat.identity.slerp(to: q1, 1).isApproximatelyEqual(to: q1))
        XCTAssertEqual(Quat.identity.slerp(to: q1, 0.5).angle(to: .identity), .pi / 4, accuracy: 1e-4)
    }

    // Slerp follows the shortest arc, so interpolating towards -q matches interpolating towards q.
    func testSlerpTakesShortestArc() {
        let q1 = Quat(angle: .pi / 2, axis: Vec3(0, 1, 0))
        let negated = Quat(x: -q1.x, y: -q1.y, z: -q1.z, w: -q1.w)
        XCTAssertTrue(
            Quat.identity.slerp(to: negated, 0.5).isApproximatelyEqual(to: Quat.identity.slerp(to: q1, 0.5)))
    }

    // Euler angles built with init(pitch:yaw:roll:) are recovered by eulerAngles.
    func testEulerAnglesRoundTrip() {
        let q = Quat(pitch: 0.3, yaw: 0.5, roll: 0.2)
        assertVec3(q.eulerAngles, Vec3(0.3, 0.5, 0.2))
    }

    // A TRS matrix scales first, then rotates, then translates a point.
    func testTRSMatrixAppliesScaleRotationThenTranslation() {
        let m = Mat4(
            translation: Vec3(1, 2, 3), rotation: Quat(angle: .pi / 2, axis: Vec3(0, 0, 1)), scale: Vec3(2, 1, 1))
        // (1,0,0) scales to (2,0,0), rotates to (0,2,0), then translates to (1,4,3).
        assertVec3(m.transformPoint(Vec3(1, 0, 0)), Vec3(1, 4, 3))
    }

    // Composing two TRS values with uniform scale matches multiplying their matrices.
    func testTRSCompositionMatchesMatrixProduct() {
        let p = TRS(position: Vec3(1, 0, 0), rotation: Quat(angle: .pi / 2, axis: Vec3(0, 1, 0)))
        let c = TRS(position: Vec3(0, 0, 2))
        XCTAssertTrue((p * c).matrix.isApproximatelyEqual(to: p.matrix * c.matrix))
    }

    // Decomposing a TRS matrix recovers its translation, rotation and scale.
    func testDecomposeRecoversTRSComponents() {
        let q = Quat(angle: 0.5, axis: Vec3(0, 1, 0))
        let m = Mat4(translation: Vec3(1, 2, 3), rotation: q, scale: Vec3(2, 3, 4))
        let d = m.decompose()
        assertVec3(d.translation, Vec3(1, 2, 3))
        assertVec3(d.scale, Vec3(2, 3, 4))
        XCTAssertTrue(d.rotation.isApproximatelyEqual(to: q))
    }

    // The forward vector of a TRS follows its rotation (a quarter turn about +Y maps -Z to -X).
    func testTRSForwardFollowsRotation() {
        let t = TRS(rotation: Quat(angle: .pi / 2, axis: Vec3(0, 1, 0)))
        assertVec3(t.forward, Vec3(-1, 0, 0))
    }

    // Interpolating TRS values lerps position and scale at the midpoint.
    func testTRSInterpolationMidpointPosition() {
        let a = TRS(position: .zero)
        let b = TRS(position: Vec3(4, 0, 0))
        assertVec3(a.interpolated(to: b, 0.5).position, Vec3(2, 0, 0))
    }
}
