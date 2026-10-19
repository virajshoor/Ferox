import Foundation

/// Axis-aligned bounding box.
@frozen
public struct AABB: Hashable, Codable, Sendable {
    public var min: Vec3
    public var max: Vec3

    @inlinable public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }
    @inlinable public init(center: Vec3, extents: Vec3) { self.init(min: center - extents, max: center + extents) }

    /// An inverted box that any `expand` call will overwrite.
    public static let empty = AABB(min: Vec3(repeating: .infinity), max: Vec3(repeating: -.infinity))

    @inlinable public var center: Vec3 { (min + max) * 0.5 }
    @inlinable public var extents: Vec3 { (max - min) * 0.5 }
    @inlinable public var size: Vec3 { max - min }
    @inlinable public var isEmpty: Bool { min.x > max.x || min.y > max.y || min.z > max.z }
    @inlinable public var surfaceArea: Float {
        let d = size
        return 2 * (d.x * d.y + d.y * d.z + d.z * d.x)
    }

    @inlinable public mutating func expand(_ p: Vec3) {
        min = pointwiseMin(min, p)
        max = pointwiseMax(max, p)
    }
    @inlinable public mutating func expand(_ b: AABB) {
        min = pointwiseMin(min, b.min)
        max = pointwiseMax(max, b.max)
    }
    @inlinable public func union(_ b: AABB) -> AABB {
        var r = self
        r.expand(b)
        return r
    }
    @inlinable public func intersects(_ b: AABB) -> Bool {
        !(b.min.x > max.x || b.max.x < min.x || b.min.y > max.y || b.max.y < min.y || b.min.z > max.z
            || b.max.z < min.z)
    }
    @inlinable public func contains(_ p: Vec3) -> Bool {
        p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y && p.z >= min.z && p.z <= max.z
    }
    @inlinable public func inflated(by r: Float) -> AABB { AABB(min: min - r, max: max + r) }

    /// Transforms the box by an affine matrix, returning the enclosing AABB (Arvo's method).
    public func transformed(by m: Mat4) -> AABB {
        let c = m.transformAffine(center)
        let e = extents
        let r = m.upperLeft
        let ex = r.c0.absolute * e.x + r.c1.absolute * e.y + r.c2.absolute * e.z
        return AABB(center: c, extents: ex)
    }

    /// Slab test. Returns the entry distance along the ray, if any, within `maxDistance`.
    public func intersect(_ ray: Ray, maxDistance: Float = .infinity) -> Float? {
        var tmin: Float = 0
        var tmax = maxDistance
        for i in 0..<3 {
            let o = ray.origin[i]
            let d = ray.direction[i]
            if Swift.abs(d) < 1e-12 {
                if o < min[i] || o > max[i] { return nil }
            } else {
                let inv = 1 / d
                var t0 = (min[i] - o) * inv
                var t1 = (max[i] - o) * inv
                if t0 > t1 { swap(&t0, &t1) }
                tmin = Swift.max(tmin, t0)
                tmax = Swift.min(tmax, t1)
                if tmin > tmax { return nil }
            }
        }
        return tmin
    }
}

@inlinable public func pointwiseMin<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable {
    var r = a
    for i in r.indices where b[i] < r[i] { r[i] = b[i] }
    return r
}
@inlinable public func pointwiseMax<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable {
    var r = a
    for i in r.indices where b[i] > r[i] { r[i] = b[i] }
    return r
}

/// 2D axis-aligned rectangle (origin at the minimum corner).
@frozen
public struct Rect: Hashable, Codable, Sendable {
    public var origin: Vec2
    public var size: Vec2

    @inlinable public init(origin: Vec2, size: Vec2) {
        self.origin = origin
        self.size = size
    }
    @inlinable public init(x: Float, y: Float, width: Float, height: Float) {
        self.init(origin: Vec2(x, y), size: Vec2(width, height))
    }
    public static let zero = Rect(origin: .zero, size: .zero)
    public static let unit = Rect(origin: .zero, size: Vec2(1, 1))

    @inlinable public var minX: Float { origin.x }
    @inlinable public var minY: Float { origin.y }
    @inlinable public var maxX: Float { origin.x + size.x }
    @inlinable public var maxY: Float { origin.y + size.y }
    @inlinable public var width: Float { size.x }
    @inlinable public var height: Float { size.y }
    @inlinable public var center: Vec2 { origin + size * 0.5 }
    @inlinable public var max: Vec2 { origin + size }

    @inlinable public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }
    @inlinable public func intersects(_ r: Rect) -> Bool {
        r.minX < maxX && r.maxX > minX && r.minY < maxY && r.maxY > minY
    }
    public func intersection(_ r: Rect) -> Rect {
        let lo = pointwiseMax(origin, r.origin)
        let hi = pointwiseMin(max, r.max)
        if hi.x <= lo.x || hi.y <= lo.y { return Rect(origin: lo, size: .zero) }
        return Rect(origin: lo, size: hi - lo)
    }
    @inlinable public func insetBy(_ insets: EdgeInsets) -> Rect {
        Rect(
            x: minX + insets.left, y: minY + insets.top, width: Swift.max(0, width - insets.left - insets.right),
            height: Swift.max(0, height - insets.top - insets.bottom))
    }
}

/// Insets used by the UI layout system.
@frozen
public struct EdgeInsets: Hashable, Codable, Sendable {
    public var top: Float, left: Float, bottom: Float, right: Float
    @inlinable public init(top: Float = 0, left: Float = 0, bottom: Float = 0, right: Float = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
    @inlinable public init(all v: Float) { self.init(top: v, left: v, bottom: v, right: v) }
    @inlinable public init(horizontal h: Float, vertical v: Float) { self.init(top: v, left: h, bottom: v, right: h) }
    public static let zero = EdgeInsets()
    @inlinable public var horizontal: Float { left + right }
    @inlinable public var vertical: Float { top + bottom }
}

@frozen
public struct Ray: Hashable, Codable, Sendable {
    public var origin: Vec3
    /// Unit direction.
    public var direction: Vec3
    @inlinable public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = direction.normalized
    }
    @inlinable public func point(at t: Float) -> Vec3 { origin + direction * t }
}

@frozen
public struct Sphere: Hashable, Codable, Sendable {
    public var center: Vec3
    public var radius: Float
    @inlinable public init(center: Vec3, radius: Float) {
        self.center = center
        self.radius = radius
    }

    public func intersect(_ ray: Ray) -> Float? {
        let oc = ray.origin - center
        let b = oc.dot(ray.direction)
        let c = oc.lengthSquared - radius * radius
        let disc = b * b - c
        if disc < 0 { return nil }
        let s = disc.squareRoot()
        let t0 = -b - s
        if t0 >= 0 { return t0 }
        let t1 = -b + s
        return t1 >= 0 ? 0 : nil  // origin inside the sphere
    }
}

/// Plane `normal · p + d = 0` with unit normal.
@frozen
public struct Plane: Hashable, Codable, Sendable {
    public var normal: Vec3
    public var d: Float
    @inlinable public init(normal: Vec3, d: Float) {
        self.normal = normal
        self.d = d
    }
    @inlinable public init(normal: Vec3, point: Vec3) {
        let n = normal.normalized
        self.init(normal: n, d: -n.dot(point))
    }
    /// Normalises a plane given as raw coefficients `(a, b, c, d)`.
    @inlinable public init(coefficients v: Vec4) {
        let l = v.xyz.length
        self.init(normal: v.xyz / l, d: v.w / l)
    }
    @inlinable public func signedDistance(_ p: Vec3) -> Float { normal.dot(p) + d }

    public func intersect(_ ray: Ray) -> Float? {
        let denom = normal.dot(ray.direction)
        if Swift.abs(denom) < 1e-8 { return nil }
        let t = -(normal.dot(ray.origin) + d) / denom
        return t >= 0 ? t : nil
    }
}

/// Six-plane view frustum extracted from a view-projection matrix, with inward-facing normals.
public struct Frustum: Sendable {
    public var planes: [Plane]

    /// Extracts planes (Gribb–Hartmann) for Metal's [0, 1] depth range. Works for both
    /// conventional and reversed-Z projections since near/far are symmetric in the test.
    public init(viewProjection m: Mat4) {
        let t = m.transposed  // rows of m are columns of t
        let r0 = t.c0
        let r1 = t.c1
        let r2 = t.c2
        let r3 = t.c3
        planes = [
            Plane(coefficients: r3 + r0),  // left
            Plane(coefficients: r3 - r0),  // right
            Plane(coefficients: r3 + r1),  // bottom
            Plane(coefficients: r3 - r1),  // top
            Plane(coefficients: r2),  // z >= 0
            Plane(coefficients: r3 - r2),  // z <= w
        ]
    }

    @inlinable public func contains(_ s: Sphere) -> Bool {
        for p in planes where p.signedDistance(s.center) < -s.radius { return false }
        return true
    }

    /// Conservative AABB test using the "positive vertex" per plane.
    @inlinable public func intersects(_ b: AABB) -> Bool {
        let c = b.center
        let e = b.extents
        for p in planes {
            let r = e.dot(p.normal.absolute)
            if p.signedDistance(c) < -r { return false }
        }
        return true
    }
}
