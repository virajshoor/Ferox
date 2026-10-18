import Foundation

/// A unit quaternion representing a 3D rotation. Stored as `(x, y, z, w)` with `w` the
/// scalar part, matching glTF and Metal shader conventions.
@frozen
public struct Quat: Hashable, Codable, Sendable {
    public var x: Float, y: Float, z: Float, w: Float

    @inlinable public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    @inlinable public init(_ v: Vec4) { self.init(x: v.x, y: v.y, z: v.z, w: v.w) }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    @inlinable public var vector: Vec4 { Vec4(x, y, z, w) }
    @inlinable public var imaginary: Vec3 { Vec3(x, y, z) }

    /// Rotation of `angle` radians around the (normalised) `axis`.
    @inlinable public init(angle: Float, axis: Vec3) {
        let a = axis.normalized
        let s = sin(angle * 0.5)
        self.init(x: a.x * s, y: a.y * s, z: a.z * s, w: cos(angle * 0.5))
    }

    /// Euler angles in radians, applied in Y (yaw) → X (pitch) → Z (roll) order,
    /// the convention used by the editor and first-person cameras.
    @inlinable public init(pitch: Float, yaw: Float, roll: Float) {
        self = Quat(angle: yaw, axis: .up) * Quat(angle: pitch, axis: .right) * Quat(angle: roll, axis: Vec3(0, 0, 1))
    }

    /// Shortest rotation taking unit vector `from` onto unit vector `to`.
    public init(from: Vec3, to: Vec3) {
        let f = from.normalized, t = to.normalized
        let d = f.dot(t)
        if d >= 1 - 1e-6 { self = .identity; return }
        if d <= -1 + 1e-6 { self = Quat(angle: .pi, axis: f.anyPerpendicular); return }
        let c = f.cross(t)
        self = Quat(x: c.x, y: c.y, z: c.z, w: 1 + d).normalized
    }

    /// Rotation whose -Z axis points along `forward` with the given `up` hint.
    public static func lookRotation(forward: Vec3, up: Vec3 = .up) -> Quat {
        let f = forward.normalized
        guard f.lengthSquared > 0 else { return .identity }
        var r = up.cross(-f)
        if r.lengthSquared < 1e-8 { r = f.anyPerpendicular }
        r = r.normalized
        let u = (-f).cross(r)
        return Quat(rotationMatrix: Mat3(columns: r, u, -f))
    }

    /// Extracts a quaternion from an orthonormal rotation matrix.
    public init(rotationMatrix m: Mat3) {
        let trace = m.c0.x + m.c1.y + m.c2.z
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            self.init(x: (m.c1.z - m.c2.y) / s, y: (m.c2.x - m.c0.z) / s, z: (m.c0.y - m.c1.x) / s, w: 0.25 * s)
        } else if m.c0.x > m.c1.y && m.c0.x > m.c2.z {
            let s = (1 + m.c0.x - m.c1.y - m.c2.z).squareRoot() * 2
            self.init(x: 0.25 * s, y: (m.c1.x + m.c0.y) / s, z: (m.c2.x + m.c0.z) / s, w: (m.c1.z - m.c2.y) / s)
        } else if m.c1.y > m.c2.z {
            let s = (1 + m.c1.y - m.c0.x - m.c2.z).squareRoot() * 2
            self.init(x: (m.c1.x + m.c0.y) / s, y: 0.25 * s, z: (m.c2.y + m.c1.z) / s, w: (m.c2.x - m.c0.z) / s)
        } else {
            let s = (1 + m.c2.z - m.c0.x - m.c1.y).squareRoot() * 2
            self.init(x: (m.c2.x + m.c0.z) / s, y: (m.c2.y + m.c1.z) / s, z: 0.25 * s, w: (m.c0.y - m.c1.x) / s)
        }
        self = normalized
    }

    @inlinable public var lengthSquared: Float { vector.lengthSquared }
    @inlinable public var normalized: Quat {
        let l = lengthSquared
        return l > 1e-20 ? Quat(vector / l.squareRoot()) : .identity
    }
    @inlinable public var conjugate: Quat { Quat(x: -x, y: -y, z: -z, w: w) }
    @inlinable public var inverse: Quat {
        let l = lengthSquared
        return l > 0 ? Quat(conjugate.vector / l) : .identity
    }

    @inlinable public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    /// Rotates a vector.
    @inlinable public func act(_ v: Vec3) -> Vec3 {
        let u = imaginary
        let t = 2 * u.cross(v)
        return v + w * t + u.cross(t)
    }

    @inlinable public static func * (q: Quat, v: Vec3) -> Vec3 { q.act(v) }

    @inlinable public func dot(_ o: Quat) -> Float { vector.dot(o.vector) }

    /// Spherical linear interpolation along the shortest arc.
    public func slerp(to target: Quat, _ t: Float) -> Quat {
        var b = target
        var cosTheta = dot(b)
        if cosTheta < 0 { b = Quat(-b.vector); cosTheta = -cosTheta }
        if cosTheta > 0.9995 { return nlerp(to: b, t) }
        let theta = acos(cosTheta)
        let s = sin(theta)
        let wa = sin((1 - t) * theta) / s
        let wb = sin(t * theta) / s
        return Quat(vector * wa + b.vector * wb).normalized
    }

    /// Normalised linear interpolation (fast; adequate for small angles and blending).
    @inlinable public func nlerp(to target: Quat, _ t: Float) -> Quat {
        let b = dot(target) < 0 ? Quat(-target.vector) : target
        return Quat(vector.lerp(to: b.vector, t)).normalized
    }

    /// Angle in radians between two rotations.
    public func angle(to other: Quat) -> Float {
        let d = Swift.min(Swift.abs(dot(other)), 1)
        return 2 * acos(d)
    }

    /// Euler angles (pitch, yaw, roll) using the same convention as `init(pitch:yaw:roll:)`.
    public var eulerAngles: Vec3 {
        let m = Mat3(self)
        // R = Ry * Rx * Rz ; m.c2.y = -sin(pitch)
        let sp = (-m.c2.y).clamped(-1, 1)
        let pitch = asin(sp)
        if Swift.abs(sp) < 0.9999 {
            let yaw = atan2(m.c2.x, m.c2.z)
            let roll = atan2(m.c0.y, m.c1.y)
            return Vec3(pitch, yaw, roll)
        }
        // Gimbal lock: attribute all rotation to yaw.
        let yaw = atan2(-m.c0.z, m.c0.x)
        return Vec3(pitch, yaw, 0)
    }

    @inlinable public func isApproximatelyEqual(to o: Quat, tolerance: Float = 1e-4) -> Bool {
        Swift.abs(Swift.abs(dot(o)) - 1) < tolerance
    }
}
