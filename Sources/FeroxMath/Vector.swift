// FeroxMath is built purely on the Swift standard library's SIMD types so that it
// compiles on every platform Swift supports. On Apple platforms `SIMD4<Float>` and
// `Mat4` have the same size, stride and alignment as Metal's `float4` and `float4x4`,
// which lets GPU-facing structs embed them directly.
//
// Vector operations are exposed as methods rather than free functions to avoid
// overload ambiguity with Apple's `simd` module (`dot`, `length`, `cross`, …) in
// files that import both.

import Foundation

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>
public typealias Vec4 = SIMD4<Float>
public typealias IVec2 = SIMD2<Int32>
public typealias UVec2 = SIMD2<UInt32>

extension SIMD where Scalar == Float {
    /// Dot product.
    @inlinable public func dot(_ other: Self) -> Float { (self * other).sum() }
    /// Squared Euclidean length (cheaper than `length`).
    @inlinable public var lengthSquared: Float { dot(self) }
    /// Euclidean length.
    @inlinable public var length: Float { lengthSquared.squareRoot() }
    /// Unit-length copy, or zero when the vector is degenerate.
    @inlinable public var normalized: Self {
        let l2 = lengthSquared
        return l2 > 1e-24 ? self / l2.squareRoot() : .zero
    }
    /// Linear interpolation towards `other`.
    @inlinable public func lerp(to other: Self, _ t: Float) -> Self { self + (other - self) * t }
    /// Distance to another point.
    @inlinable public func distance(to other: Self) -> Float { (other - self).length }
    /// Component-wise absolute value.
    @inlinable public var absolute: Self {
        var r = self
        for i in r.indices { r[i] = Swift.abs(r[i]) }
        return r
    }
    /// Approximate equality with an absolute tolerance per component.
    @inlinable public func isApproximatelyEqual(to other: Self, tolerance: Float = 1e-5) -> Bool {
        for i in indices where Swift.abs(self[i] - other[i]) > tolerance { return false }
        return true
    }
    /// True when every component is finite.
    @inlinable public var isFinite: Bool {
        for i in indices where !self[i].isFinite { return false }
        return true
    }
}

extension SIMD3 where Scalar == Float {
    @inlinable public func cross(_ b: Self) -> Self {
        Self(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    @inlinable public var xy: Vec2 { Vec2(x, y) }
    public static let up = Vec3(0, 1, 0)
    public static let right = Vec3(1, 0, 0)
    /// Ferox is right-handed with -Z forward (matching glTF).
    public static let forward = Vec3(0, 0, -1)

    /// Returns any unit vector perpendicular to `self` (which must be normalised).
    @inlinable public var anyPerpendicular: Vec3 {
        let a: Vec3 = Swift.abs(x) < 0.57735 ? .right : .up
        return cross(a).normalized
    }
}

extension SIMD2 where Scalar == Float {
    /// 2D scalar cross product (z-component of the 3D cross product).
    @inlinable public func cross(_ b: Self) -> Float { x * b.y - y * b.x }
    /// Perpendicular vector rotated +90°.
    @inlinable public var perpendicular: Self { Self(-y, x) }
    /// Rotates by `angle` radians counter-clockwise.
    @inlinable public func rotated(by angle: Float) -> Self {
        let c = cos(angle), s = sin(angle)
        return Self(c * x - s * y, s * x + c * y)
    }
}

extension SIMD4 where Scalar == Float {
    @inlinable public var xyz: Vec3 {
        get { Vec3(x, y, z) }
        set { x = newValue.x; y = newValue.y; z = newValue.z }
    }
    @inlinable public init(_ v: Vec3, _ w: Float) { self.init(v.x, v.y, v.z, w) }
}

extension Float {
    @inlinable public static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inlinable public func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(self, lo), hi) }
    @inlinable public var saturated: Float { clamped(0, 1) }
    @inlinable public var radians: Float { self * .pi / 180 }
    @inlinable public var degrees: Float { self * 180 / .pi }
    /// Hermite smoothstep.
    @inlinable public static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = ((x - e0) / (e1 - e0)).saturated
        return t * t * (3 - 2 * t)
    }
    /// Frame-rate independent exponential smoothing factor: `1 - exp(-rate * dt)`.
    @inlinable public static func damping(rate: Float, dt: Float) -> Float { 1 - exp(-rate * dt) }
}
