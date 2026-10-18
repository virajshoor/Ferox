import Foundation

/// Column-major 3×3 matrix.
@frozen
public struct Mat3: Hashable, Codable, Sendable {
    public var c0: Vec3, c1: Vec3, c2: Vec3

    @inlinable public init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) { self.c0 = c0; self.c1 = c1; self.c2 = c2 }
    @inlinable public init(diagonal d: Vec3) {
        self.init(columns: Vec3(d.x, 0, 0), Vec3(0, d.y, 0), Vec3(0, 0, d.z))
    }
    public static let identity = Mat3(diagonal: Vec3(1, 1, 1))
    public static let zero = Mat3(diagonal: .zero)

    /// Rotation matrix from a quaternion.
    @inlinable public init(_ q: Quat) {
        let x2 = q.x + q.x, y2 = q.y + q.y, z2 = q.z + q.z
        let xx = q.x * x2, xy = q.x * y2, xz = q.x * z2
        let yy = q.y * y2, yz = q.y * z2, zz = q.z * z2
        let wx = q.w * x2, wy = q.w * y2, wz = q.w * z2
        self.init(
            columns: Vec3(1 - (yy + zz), xy + wz, xz - wy),
            Vec3(xy - wz, 1 - (xx + zz), yz + wx),
            Vec3(xz + wy, yz - wx, 1 - (xx + yy))
        )
    }

    @inlinable public subscript(column: Int) -> Vec3 {
        get { column == 0 ? c0 : (column == 1 ? c1 : c2) }
        set {
            switch column {
            case 0: c0 = newValue
            case 1: c1 = newValue
            default: c2 = newValue
            }
        }
    }

    @inlinable public var transposed: Mat3 {
        Mat3(columns: Vec3(c0.x, c1.x, c2.x), Vec3(c0.y, c1.y, c2.y), Vec3(c0.z, c1.z, c2.z))
    }

    @inlinable public var determinant: Float { c0.dot(c1.cross(c2)) }

    public var inverse: Mat3 {
        let det = determinant
        guard Swift.abs(det) > 1e-20 else { return .zero }
        let r0 = c1.cross(c2), r1 = c2.cross(c0), r2 = c0.cross(c1)
        return Mat3(columns: r0, r1, r2).transposed * (1 / det)
    }

    @inlinable public static func * (m: Mat3, v: Vec3) -> Vec3 { m.c0 * v.x + m.c1 * v.y + m.c2 * v.z }
    @inlinable public static func * (a: Mat3, b: Mat3) -> Mat3 { Mat3(columns: a * b.c0, a * b.c1, a * b.c2) }
    @inlinable public static func * (m: Mat3, s: Float) -> Mat3 { Mat3(columns: m.c0 * s, m.c1 * s, m.c2 * s) }
    @inlinable public static func + (a: Mat3, b: Mat3) -> Mat3 { Mat3(columns: a.c0 + b.c0, a.c1 + b.c1, a.c2 + b.c2) }

    /// Skew-symmetric cross-product matrix: `skew(a) * b == a.cross(b)`.
    @inlinable public static func skew(_ a: Vec3) -> Mat3 {
        Mat3(columns: Vec3(0, a.z, -a.y), Vec3(-a.z, 0, a.x), Vec3(a.y, -a.x, 0))
    }
}

/// Column-major 4×4 matrix, layout-compatible with Metal's `float4x4`.
@frozen
public struct Mat4: Hashable, Codable, Sendable {
    public var c0: Vec4, c1: Vec4, c2: Vec4, c3: Vec4

    @inlinable public init(columns c0: Vec4, _ c1: Vec4, _ c2: Vec4, _ c3: Vec4) {
        self.c0 = c0; self.c1 = c1; self.c2 = c2; self.c3 = c3
    }
    @inlinable public init(diagonal d: Vec4) {
        self.init(columns: Vec4(d.x, 0, 0, 0), Vec4(0, d.y, 0, 0), Vec4(0, 0, d.z, 0), Vec4(0, 0, 0, d.w))
    }
    @inlinable public init(_ m: Mat3, translation t: Vec3 = .zero) {
        self.init(columns: Vec4(m.c0, 0), Vec4(m.c1, 0), Vec4(m.c2, 0), Vec4(t, 1))
    }
    public static let identity = Mat4(diagonal: Vec4(1, 1, 1, 1))

    @inlinable public subscript(column: Int) -> Vec4 {
        get {
            switch column {
            case 0: return c0
            case 1: return c1
            case 2: return c2
            default: return c3
            }
        }
        set {
            switch column {
            case 0: c0 = newValue
            case 1: c1 = newValue
            case 2: c2 = newValue
            default: c3 = newValue
            }
        }
    }

    @inlinable public var upperLeft: Mat3 { Mat3(columns: c0.xyz, c1.xyz, c2.xyz) }
    @inlinable public var translation: Vec3 { c3.xyz }

    // MARK: Construction

    @inlinable public static func translation(_ t: Vec3) -> Mat4 {
        Mat4(columns: Vec4(1, 0, 0, 0), Vec4(0, 1, 0, 0), Vec4(0, 0, 1, 0), Vec4(t, 1))
    }
    @inlinable public static func scale(_ s: Vec3) -> Mat4 { Mat4(diagonal: Vec4(s, 1)) }
    @inlinable public static func rotation(_ q: Quat) -> Mat4 { Mat4(Mat3(q)) }

    /// Translation · Rotation · Scale.
    @inlinable public init(translation t: Vec3, rotation q: Quat, scale s: Vec3) {
        let r = Mat3(q)
        self.init(columns: Vec4(r.c0 * s.x, 0), Vec4(r.c1 * s.y, 0), Vec4(r.c2 * s.z, 0), Vec4(t, 1))
    }

    /// Right-handed perspective projection for Metal's [0, 1] clip-space depth.
    ///
    /// With `reverseZ` (the Ferox default) the near plane maps to depth 1 and the far
    /// plane to 0, which distributes floating-point depth precision far more evenly.
    /// Depth tests must then use `greater` and the depth buffer must be cleared to 0.
    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float, reverseZ: Bool = true) -> Mat4 {
        let f = 1 / tan(fovY * 0.5)
        let a: Float, b: Float
        if reverseZ {
            a = near / (far - near)
            b = far * near / (far - near)
        } else {
            a = far / (near - far)
            b = far * near / (near - far)
        }
        return Mat4(columns: Vec4(f / aspect, 0, 0, 0), Vec4(0, f, 0, 0), Vec4(0, 0, a, -1), Vec4(0, 0, b, 0))
    }

    /// Right-handed orthographic projection for Metal's [0, 1] clip-space depth.
    public static func orthographic(
        left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float, reverseZ: Bool = true
    ) -> Mat4 {
        let rl = right - left, tb = top - bottom, fn = far - near
        let a: Float = reverseZ ? 1 / fn : -1 / fn
        let b: Float = reverseZ ? far / fn : -near / fn
        return Mat4(
            columns: Vec4(2 / rl, 0, 0, 0), Vec4(0, 2 / tb, 0, 0), Vec4(0, 0, a, 0),
            Vec4(-(right + left) / rl, -(top + bottom) / tb, b, 1)
        )
    }

    /// View matrix for a camera at `eye` looking at `target`.
    public static func lookAt(eye: Vec3, target: Vec3, up: Vec3 = .up) -> Mat4 {
        let f = (target - eye).normalized
        var s = f.cross(up)
        if s.lengthSquared < 1e-10 { s = f.anyPerpendicular }
        s = s.normalized
        let u = s.cross(f)
        return Mat4(
            columns: Vec4(s.x, u.x, -f.x, 0), Vec4(s.y, u.y, -f.y, 0), Vec4(s.z, u.z, -f.z, 0),
            Vec4(-s.dot(eye), -u.dot(eye), f.dot(eye), 1)
        )
    }

    // MARK: Operations

    @inlinable public static func * (m: Mat4, v: Vec4) -> Vec4 {
        m.c0 * v.x + m.c1 * v.y + m.c2 * v.z + m.c3 * v.w
    }
    @inlinable public static func * (a: Mat4, b: Mat4) -> Mat4 {
        Mat4(columns: a * b.c0, a * b.c1, a * b.c2, a * b.c3)
    }

    @inlinable public func transformPoint(_ p: Vec3) -> Vec3 {
        let r = self * Vec4(p, 1)
        return r.xyz / r.w
    }
    /// Affine point transform (ignores the projective row).
    @inlinable public func transformAffine(_ p: Vec3) -> Vec3 { (c0 * p.x + c1 * p.y + c2 * p.z + c3).xyz }
    @inlinable public func transformDirection(_ d: Vec3) -> Vec3 { (c0 * d.x + c1 * d.y + c2 * d.z).xyz }

    @inlinable public var transposed: Mat4 {
        Mat4(
            columns: Vec4(c0.x, c1.x, c2.x, c3.x), Vec4(c0.y, c1.y, c2.y, c3.y),
            Vec4(c0.z, c1.z, c2.z, c3.z), Vec4(c0.w, c1.w, c2.w, c3.w)
        )
    }

    /// General 4×4 inverse via cofactor expansion. Returns the zero matrix when singular.
    public var inverse: Mat4 {
        let a00 = c0.x, a01 = c0.y, a02 = c0.z, a03 = c0.w
        let a10 = c1.x, a11 = c1.y, a12 = c1.z, a13 = c1.w
        let a20 = c2.x, a21 = c2.y, a22 = c2.z, a23 = c2.w
        let a30 = c3.x, a31 = c3.y, a32 = c3.z, a33 = c3.w

        let b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10
        let b02 = a00 * a13 - a03 * a10, b03 = a01 * a12 - a02 * a11
        let b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12
        let b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30
        let b08 = a20 * a33 - a23 * a30, b09 = a21 * a32 - a22 * a31
        let b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32

        let detA: Float = b00 * b11 - b01 * b10 + b02 * b09
        let det: Float = detA + b03 * b08 - b04 * b07 + b05 * b06
        guard Swift.abs(det) > 1e-30 else { return Mat4(diagonal: .zero) }
        let id = 1 / det
        // Each term is computed separately to keep the expression type-checker fast.
        let o00: Float = a11 * b11 - a12 * b10 + a13 * b09
        let o01: Float = a02 * b10 - a01 * b11 - a03 * b09
        let o02: Float = a31 * b05 - a32 * b04 + a33 * b03
        let o03: Float = a22 * b04 - a21 * b05 - a23 * b03
        let o10: Float = a12 * b08 - a10 * b11 - a13 * b07
        let o11: Float = a00 * b11 - a02 * b08 + a03 * b07
        let o12: Float = a32 * b02 - a30 * b05 - a33 * b01
        let o13: Float = a20 * b05 - a22 * b02 + a23 * b01
        let o20: Float = a10 * b10 - a11 * b08 + a13 * b06
        let o21: Float = a01 * b08 - a00 * b10 - a03 * b06
        let o22: Float = a30 * b04 - a31 * b02 + a33 * b00
        let o23: Float = a21 * b02 - a20 * b04 - a23 * b00
        let o30: Float = a11 * b07 - a10 * b09 - a12 * b06
        let o31: Float = a00 * b09 - a01 * b07 + a02 * b06
        let o32: Float = a31 * b01 - a30 * b03 - a32 * b00
        let o33: Float = a20 * b03 - a21 * b01 + a22 * b00
        return Mat4(
            columns: Vec4(o00, o01, o02, o03) * id, Vec4(o10, o11, o12, o13) * id,
            Vec4(o20, o21, o22, o23) * id, Vec4(o30, o31, o32, o33) * id
        )
    }

    /// Fast inverse for rigid/affine transforms (rotation, uniform or non-uniform scale, translation).
    public var affineInverse: Mat4 {
        let inv = upperLeft.inverse
        return Mat4(inv, translation: -(inv * translation))
    }

    /// Inverse-transpose of the upper 3×3, used to transform normals.
    @inlinable public var normalMatrix: Mat3 { upperLeft.inverse.transposed }

    /// Decomposes an affine TRS matrix. Shear is discarded.
    public func decompose() -> (translation: Vec3, rotation: Quat, scale: Vec3) {
        let t = translation
        var sx = c0.xyz.length
        let sy = c1.xyz.length
        let sz = c2.xyz.length
        if upperLeft.determinant < 0 { sx = -sx }
        let r = Mat3(
            columns: sx != 0 ? c0.xyz / sx : .right, sy != 0 ? c1.xyz / sy : .up, sz != 0 ? c2.xyz / sz : Vec3(0, 0, 1))
        return (t, Quat(rotationMatrix: r), Vec3(sx, sy, sz))
    }

    public func isApproximatelyEqual(to o: Mat4, tolerance: Float = 1e-4) -> Bool {
        c0.isApproximatelyEqual(to: o.c0, tolerance: tolerance) && c1.isApproximatelyEqual(to: o.c1, tolerance: tolerance)
            && c2.isApproximatelyEqual(to: o.c2, tolerance: tolerance)
            && c3.isApproximatelyEqual(to: o.c3, tolerance: tolerance)
    }
}

/// Column-major 2D affine transform (3×2), used by the 2D renderer and UI.
@frozen
public struct Affine2D: Hashable, Codable, Sendable {
    /// Columns: x-axis, y-axis, translation.
    public var a: Vec2, b: Vec2, t: Vec2

    @inlinable public init(a: Vec2, b: Vec2, t: Vec2) { self.a = a; self.b = b; self.t = t }
    public static let identity = Affine2D(a: Vec2(1, 0), b: Vec2(0, 1), t: .zero)

    @inlinable public init(translation: Vec2 = .zero, rotation: Float = 0, scale: Vec2 = Vec2(1, 1)) {
        let c = cos(rotation), s = sin(rotation)
        self.init(a: Vec2(c, s) * scale.x, b: Vec2(-s, c) * scale.y, t: translation)
    }

    @inlinable public func apply(_ p: Vec2) -> Vec2 { a * p.x + b * p.y + t }
    @inlinable public func applyVector(_ v: Vec2) -> Vec2 { a * v.x + b * v.y }
    @inlinable public static func * (l: Affine2D, r: Affine2D) -> Affine2D {
        Affine2D(a: l.applyVector(r.a), b: l.applyVector(r.b), t: l.apply(r.t))
    }
    public var inverse: Affine2D {
        let det = a.x * b.y - b.x * a.y
        guard Swift.abs(det) > 1e-20 else { return .identity }
        let id = 1 / det
        let ia = Vec2(b.y, -a.y) * id
        let ib = Vec2(-b.x, a.x) * id
        return Affine2D(a: ia, b: ib, t: -(ia * t.x + ib * t.y))
    }
    /// Expands to a 4×4 matrix in the XY plane.
    @inlinable public var mat4: Mat4 {
        Mat4(columns: Vec4(a.x, a.y, 0, 0), Vec4(b.x, b.y, 0, 0), Vec4(0, 0, 1, 0), Vec4(t.x, t.y, 0, 1))
    }
}
