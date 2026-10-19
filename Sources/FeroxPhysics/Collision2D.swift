import FeroxCore
import Foundation

/// 2D rigid transform (rotation stored as cos/sin to avoid repeated trig).
public struct Transform2D: Sendable, Hashable {
    public var p: Vec2
    public var c: Float
    public var s: Float
    @inlinable public init(position: Vec2, angle: Float) {
        p = position
        c = cos(angle)
        s = sin(angle)
    }
    @inlinable public func apply(_ v: Vec2) -> Vec2 { Vec2(c * v.x - s * v.y, s * v.x + c * v.y) + p }
    @inlinable public func rotate(_ v: Vec2) -> Vec2 { Vec2(c * v.x - s * v.y, s * v.x + c * v.y) }
    @inlinable public func invRotate(_ v: Vec2) -> Vec2 { Vec2(c * v.x + s * v.y, -s * v.x + c * v.y) }
    @inlinable public func invApply(_ v: Vec2) -> Vec2 { invRotate(v - p) }
}

/// Convex polygon in body-local space (counter-clockwise winding, ≤ 16 vertices).
public struct Polygon2D: Codable, Sendable, Hashable {
    public private(set) var vertices: [Vec2]
    public private(set) var normals: [Vec2]
    public private(set) var centroid: Vec2

    public static let maxVertices = 16

    /// Builds a polygon from points by computing their convex hull (gift wrapping).
    /// Returns nil for degenerate input (< 3 non-collinear points).
    public init?(points: [Vec2]) {
        let hull = Polygon2D.convexHull(points)
        guard hull.count >= 3, hull.count <= Polygon2D.maxVertices else { return nil }
        vertices = hull
        normals = (0..<hull.count).map { i in
            let e = hull[(i + 1) % hull.count] - hull[i]
            return Vec2(e.y, -e.x).normalized
        }
        centroid = Polygon2D.computeCentroid(hull)
    }

    public static func box(halfExtents h: Vec2, center: Vec2 = .zero, angle: Float = 0) -> Polygon2D {
        let t = Transform2D(position: center, angle: angle)
        let pts = [Vec2(-h.x, -h.y), Vec2(h.x, -h.y), Vec2(h.x, h.y), Vec2(-h.x, h.y)].map(t.apply)
        return Polygon2D(points: pts)!
    }

    static func convexHull(_ input: [Vec2]) -> [Vec2] {
        // Weld near-duplicates.
        var pts: [Vec2] = []
        for p in input where !pts.contains(where: { ($0 - p).lengthSquared < 1e-8 }) { pts.append(p) }
        guard pts.count >= 3 else { return [] }
        // Andrew's monotone chain → CCW hull.
        pts.sort { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        var lower: [Vec2] = []
        var upper: [Vec2] = []
        for p in pts {
            while lower.count >= 2
                && (lower[lower.count - 1] - lower[lower.count - 2]).cross(p - lower[lower.count - 2]) <= 1e-9
            {
                lower.removeLast()
            }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2
                && (upper[upper.count - 1] - upper[upper.count - 2]).cross(p - upper[upper.count - 2]) <= 1e-9
            {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    static func computeCentroid(_ v: [Vec2]) -> Vec2 {
        var c = Vec2.zero
        var area: Float = 0
        let o = v[0]
        for i in 1..<(v.count - 1) {
            let e1 = v[i] - o
            let e2 = v[i + 1] - o
            let a = 0.5 * e1.cross(e2)
            c += a * (e1 + e2) / 3
            area += a
        }
        return o + c / area
    }

    /// Mass properties for unit density: (area, centroid, rotational inertia about the centroid).
    public func massProperties() -> (area: Float, centroid: Vec2, inertia: Float) {
        let o = centroid
        var area: Float = 0
        var inertia: Float = 0
        for i in 0..<vertices.count {
            let e1 = vertices[i] - o
            let e2 = vertices[(i + 1) % vertices.count] - o
            let d = e1.cross(e2)
            let triArea = 0.5 * d
            area += triArea
            let intx2 = e1.x * e1.x + e2.x * e1.x + e2.x * e2.x
            let inty2 = e1.y * e1.y + e2.y * e1.y + e2.y * e2.y
            inertia += (0.25 / 3 * d) * (intx2 + inty2)
        }
        return (area, o, inertia)
    }
}

/// Geometry of a 2D collision shape.
public enum ShapeGeometry2D: Codable, Sendable, Hashable {
    case circle(center: Vec2, radius: Float)
    case polygon(Polygon2D)
    /// Capsule between two local points.
    case capsule(a: Vec2, b: Vec2, radius: Float)
}

/// A collision shape attached to a 2D body.
public struct Shape2D: Codable, Sendable, Hashable {
    public var geometry: ShapeGeometry2D
    public var material: PhysicsMaterial
    public var filter: CollisionFilter
    public var isTrigger: Bool
    public init(
        _ geometry: ShapeGeometry2D, material: PhysicsMaterial = .default, filter: CollisionFilter = .default,
        isTrigger: Bool = false
    ) {
        self.geometry = geometry
        self.material = material
        self.filter = filter
        self.isTrigger = isTrigger
    }

    public static func circle(radius: Float, center: Vec2 = .zero) -> Shape2D {
        Shape2D(.circle(center: center, radius: radius))
    }
    public static func box(halfExtents: Vec2, center: Vec2 = .zero, angle: Float = 0) -> Shape2D {
        Shape2D(.polygon(.box(halfExtents: halfExtents, center: center, angle: angle)))
    }
    public static func capsule(height: Float, radius: Float) -> Shape2D {
        let h = max(0, height * 0.5 - radius)
        return Shape2D(.capsule(a: Vec2(0, -h), b: Vec2(0, h), radius: radius))
    }

    func massData() -> (mass: Float, center: Vec2, inertia: Float) {
        let d = material.density
        switch geometry {
        case .circle(let c, let r):
            let m = d * .pi * r * r
            return (m, c, m * (0.5 * r * r + c.lengthSquared))
        case .polygon(let poly):
            let mp = poly.massProperties()
            let m = d * mp.area
            return (m, mp.centroid, d * mp.inertia + m * mp.centroid.lengthSquared)
        case .capsule(let a, let b, let r):
            let len = (b - a).length
            let rectM = d * 2 * r * len
            let circM = d * .pi * r * r
            let m = rectM + circM
            let center = (a + b) * 0.5
            let rectI = rectM * (len * len + 4 * r * r) / 12
            let circI = circM * (0.5 * r * r + len * len * 0.25)
            return (m, center, rectI + circI + m * center.lengthSquared)
        }
    }

    func aabb(_ xf: Transform2D) -> (Vec2, Vec2) {
        switch geometry {
        case .circle(let c, let r):
            let p = xf.apply(c)
            return (p - r, p + r)
        case .polygon(let poly):
            var lo = Vec2(repeating: .infinity)
            var hi = Vec2(repeating: -.infinity)
            for v in poly.vertices {
                let w = xf.apply(v)
                lo = pointwiseMin(lo, w)
                hi = pointwiseMax(hi, w)
            }
            return (lo, hi)
        case .capsule(let a, let b, let r):
            let wa = xf.apply(a)
            let wb = xf.apply(b)
            return (pointwiseMin(wa, wb) - r, pointwiseMax(wa, wb) + r)
        }
    }
}

/// Contact point in a 2D manifold.
struct ManifoldPoint2D {
    var point: Vec2
    var separation: Float
    var id: UInt32
}

struct Manifold2D {
    /// Normal from shape A to shape B.
    var normal: Vec2 = .zero
    var points: [ManifoldPoint2D] = []
}

/// Narrow-phase collision routines. All inputs are in world space.
enum Collide2D {
    static func manifold(_ a: Shape2D, _ xa: Transform2D, _ b: Shape2D, _ xb: Transform2D, margin: Float) -> Manifold2D
    {
        switch (a.geometry, b.geometry) {
        case (.circle(let ca, let ra), .circle(let cb, let rb)):
            return circles(xa.apply(ca), ra, xb.apply(cb), rb, margin: margin)
        case (.polygon(let pa), .circle(let cb, let rb)):
            return polygonCircle(pa, xa, xb.apply(cb), rb, margin: margin)
        case (.circle(let ca, let ra), .polygon(let pb)):
            var m = polygonCircle(pb, xb, xa.apply(ca), ra, margin: margin)
            m.normal = -m.normal
            return m
        case (.polygon(let pa), .polygon(let pb)):
            return polygons(pa, xa, pb, xb, margin: margin)
        case (.capsule(let a0, let a1, let ra), .circle(let cb, let rb)):
            return segmentCircle(xa.apply(a0), xa.apply(a1), ra, xb.apply(cb), rb, margin: margin)
        case (.circle(let ca, let ra), .capsule(let b0, let b1, let rb)):
            var m = segmentCircle(xb.apply(b0), xb.apply(b1), rb, xa.apply(ca), ra, margin: margin)
            m.normal = -m.normal
            return m
        case (.capsule(let a0, let a1, let ra), .capsule(let b0, let b1, let rb)):
            return capsules(xa.apply(a0), xa.apply(a1), ra, xb.apply(b0), xb.apply(b1), rb, margin: margin)
        case (.polygon(let pa), .capsule(let b0, let b1, let rb)):
            return polygonCapsule(pa, xa, xb.apply(b0), xb.apply(b1), rb, margin: margin)
        case (.capsule(let a0, let a1, let ra), .polygon(let pb)):
            var m = polygonCapsule(pb, xb, xa.apply(a0), xa.apply(a1), ra, margin: margin)
            m.normal = -m.normal
            return m
        }
    }

    static func circles(_ pa: Vec2, _ ra: Float, _ pb: Vec2, _ rb: Float, margin: Float) -> Manifold2D {
        let d = pb - pa
        let dist = d.length
        let sep = dist - ra - rb
        guard sep <= margin else { return Manifold2D() }
        let n = dist > 1e-6 ? d / dist : Vec2(0, 1)
        let point = pa + n * (ra + sep * 0.5)
        return Manifold2D(normal: n, points: [ManifoldPoint2D(point: point, separation: sep, id: 0)])
    }

    static func closestOnSegment(_ a: Vec2, _ b: Vec2, _ p: Vec2) -> Vec2 {
        let ab = b - a
        let t = ab.lengthSquared > 1e-12 ? ((p - a).dot(ab) / ab.lengthSquared).saturated : 0
        return a + ab * t
    }

    static func segmentCircle(_ a: Vec2, _ b: Vec2, _ ra: Float, _ c: Vec2, _ rc: Float, margin: Float) -> Manifold2D {
        circles(closestOnSegment(a, b, c), ra, c, rc, margin: margin)
    }

    /// Closest points between segments p1q1 and p2q2 (Ericson, RTCD 5.1.9).
    static func closestSegmentSegment(_ p1: Vec2, _ q1: Vec2, _ p2: Vec2, _ q2: Vec2) -> (Vec2, Vec2) {
        let d1 = q1 - p1
        let d2 = q2 - p2
        let r = p1 - p2
        let a = d1.dot(d1)
        let e = d2.dot(d2)
        let f = d2.dot(r)
        var s: Float = 0
        var t: Float = 0
        if a <= 1e-12 && e <= 1e-12 { return (p1, p2) }
        if a <= 1e-12 {
            t = (f / e).saturated
        } else {
            let c = d1.dot(r)
            if e <= 1e-12 {
                s = (-c / a).saturated
            } else {
                let b = d1.dot(d2)
                let denom = a * e - b * b
                s = denom != 0 ? ((b * f - c * e) / denom).saturated : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0
                    s = (-c / a).saturated
                } else if t > 1 {
                    t = 1
                    s = ((b - c) / a).saturated
                }
            }
        }
        return (p1 + d1 * s, p2 + d2 * t)
    }

    static func capsules(_ a0: Vec2, _ a1: Vec2, _ ra: Float, _ b0: Vec2, _ b1: Vec2, _ rb: Float, margin: Float)
        -> Manifold2D
    {
        // Parallel overlapping capsules need two points for stability.
        let da = a1 - a0
        let db = b1 - b0
        if Swift.abs(da.normalized.cross(db.normalized)) < 0.05 && da.lengthSquared > 1e-8 && db.lengthSquared > 1e-8 {
            var m = Manifold2D()
            var pts: [ManifoldPoint2D] = []
            for (i, p) in [b0, b1].enumerated() {
                let c = closestOnSegment(a0, a1, p)
                let sub = circles(c, ra, p, rb, margin: margin)
                if let sp = sub.points.first {
                    m.normal = sub.normal
                    pts.append(ManifoldPoint2D(point: sp.point, separation: sp.separation, id: UInt32(i)))
                }
            }
            if !pts.isEmpty {
                m.points = pts
                return m
            }
        }
        let (ca, cb) = closestSegmentSegment(a0, a1, b0, b1)
        return circles(ca, ra, cb, rb, margin: margin)
    }

    static func polygonCircle(_ poly: Polygon2D, _ xf: Transform2D, _ center: Vec2, _ r: Float, margin: Float)
        -> Manifold2D
    {
        let c = xf.invApply(center)
        var bestSep = -Float.infinity
        var best = 0
        let v = poly.vertices
        let n = poly.normals
        for i in v.indices {
            let s = n[i].dot(c - v[i])
            if s > r + margin { return Manifold2D() }
            if s > bestSep {
                bestSep = s
                best = i
            }
        }
        let v1 = v[best]
        let v2 = v[(best + 1) % v.count]
        var localNormal: Vec2
        var localPoint: Vec2
        var sep: Float
        if bestSep < 1e-6 {
            // Centre inside polygon.
            localNormal = n[best]
            sep = bestSep - r
            localPoint = c - localNormal * (r + sep * 0.5)
        } else {
            let closest = closestOnSegment(v1, v2, c)
            let d = c - closest
            let dist = d.length
            sep = dist - r
            if sep > margin { return Manifold2D() }
            localNormal = dist > 1e-6 ? d / dist : n[best]
            localPoint = closest + localNormal * (sep * 0.5)
        }
        return Manifold2D(
            normal: xf.rotate(localNormal),
            points: [ManifoldPoint2D(point: xf.apply(localPoint), separation: sep, id: UInt32(best))])
    }

    static func polygonCapsule(_ poly: Polygon2D, _ xf: Transform2D, _ s0: Vec2, _ s1: Vec2, _ r: Float, margin: Float)
        -> Manifold2D
    {
        // Treat the capsule's core segment as a degenerate polygon with radius.
        guard let seg = Polygon2D(points: [s0, s1, s0 + (s1 - s0).perpendicular.normalized * 1e-4]) else {
            return polygonCircle(poly, xf, s0, r, margin: margin)
        }
        var m = polygons(poly, xf, seg, Transform2D(position: .zero, angle: 0), margin: margin + r)
        for i in m.points.indices {
            m.points[i].separation -= r
            m.points[i].point -= m.normal * (r * 0.5)
        }
        m.points.removeAll { $0.separation > margin }
        return m
    }

    /// Polygon-polygon via SAT with reference-face clipping (Box2D style).
    static func polygons(_ pa: Polygon2D, _ xa: Transform2D, _ pb: Polygon2D, _ xb: Transform2D, margin: Float)
        -> Manifold2D
    {
        let va = pa.vertices.map(xa.apply)
        let na = pa.normals.map(xa.rotate)
        let vb = pb.vertices.map(xb.apply)
        let nb = pb.normals.map(xb.rotate)

        func maxSeparation(_ v1: [Vec2], _ n1: [Vec2], _ v2: [Vec2]) -> (Int, Float) {
            var bestI = 0
            var best = -Float.infinity
            for i in v1.indices {
                var minD = Float.infinity
                for p in v2 { minD = Swift.min(minD, n1[i].dot(p - v1[i])) }
                if minD > best {
                    best = minD
                    bestI = i
                }
            }
            return (bestI, best)
        }

        let (edgeA, sepA) = maxSeparation(va, na, vb)
        if sepA > margin { return Manifold2D() }
        let (edgeB, sepB) = maxSeparation(vb, nb, va)
        if sepB > margin { return Manifold2D() }

        let flip: Bool
        let refV: [Vec2]
        let refN: [Vec2]
        let incV: [Vec2]
        let incN: [Vec2]
        let refEdge: Int
        if sepB > sepA + 0.1 * 0.005 {
            flip = true
            refV = vb
            refN = nb
            incV = va
            incN = na
            refEdge = edgeB
        } else {
            flip = false
            refV = va
            refN = na
            incV = vb
            incN = nb
            refEdge = edgeA
        }

        // Incident edge: most anti-parallel to the reference normal.
        let rn = refN[refEdge]
        var incEdge = 0
        var minDot = Float.infinity
        for i in incN.indices {
            let d = rn.dot(incN[i])
            if d < minDot {
                minDot = d
                incEdge = i
            }
        }
        let i1 = incEdge
        let i2 = (incEdge + 1) % incV.count
        var clip: [(Vec2, UInt32)] = [(incV[i1], UInt32(i1)), (incV[i2], UInt32(i2))]

        let r1 = refV[refEdge]
        let r2 = refV[(refEdge + 1) % refV.count]
        let tangent = (r2 - r1).normalized

        func clipSegment(_ pts: [(Vec2, UInt32)], _ n: Vec2, _ offset: Float, _ clipID: UInt32) -> [(Vec2, UInt32)] {
            var out: [(Vec2, UInt32)] = []
            let d0 = n.dot(pts[0].0) - offset
            let d1 = n.dot(pts[1].0) - offset
            if d0 <= 0 { out.append(pts[0]) }
            if d1 <= 0 { out.append(pts[1]) }
            if d0 * d1 < 0 {
                let t = d0 / (d0 - d1)
                out.append((pts[0].0 + (pts[1].0 - pts[0].0) * t, clipID))
            }
            return out
        }

        clip = clipSegment(clip, -tangent, -tangent.dot(r1), 0x100)
        if clip.count < 2 { return Manifold2D() }
        clip = clipSegment(clip, tangent, tangent.dot(r2), 0x200)
        if clip.count < 2 { return Manifold2D() }

        var m = Manifold2D()
        m.normal = flip ? -rn : rn
        let refOffset = rn.dot(r1)
        for (p, id) in clip {
            let sep = rn.dot(p) - refOffset
            if sep <= margin {
                // Midpoint between the two surfaces.
                let point = p - rn * (sep * 0.5)
                let fid = (UInt32(refEdge) << 16) | (flip ? 0x8000 : 0) | id
                m.points.append(ManifoldPoint2D(point: point, separation: sep, id: fid))
            }
        }
        return m
    }

    // MARK: Ray casts

    /// Ray cast against a shape; returns (fraction along `d`, normal).
    static func raycast(_ shape: Shape2D, _ xf: Transform2D, origin o: Vec2, delta d: Vec2, inflate: Float = 0) -> (
        Float, Vec2
    )? {
        switch shape.geometry {
        case .circle(let c, let r):
            return rayCircle(o, d, xf.apply(c), r + inflate)
        case .capsule(let a, let b, let r):
            return rayCapsule(o, d, xf.apply(a), xf.apply(b), r + inflate)
        case .polygon(let poly):
            if inflate > 0 {
                // Minkowski sum of polygon and circle: offset edges + vertex circles.
                var best: (Float, Vec2)?
                let v = poly.vertices.map(xf.apply)
                for i in v.indices {
                    let j = (i + 1) % v.count
                    if let hit = rayCapsule(o, d, v[i], v[j], inflate), hit.0 < (best?.0 ?? .infinity) { best = hit }
                }
                if let inside = rayPolygon(o, d, poly, xf), inside.0 == 0 { return inside }
                return best
            }
            return rayPolygon(o, d, poly, xf)
        }
    }

    static func rayCircle(_ o: Vec2, _ d: Vec2, _ c: Vec2, _ r: Float) -> (Float, Vec2)? {
        let s = o - c
        let b = s.dot(d)
        let cc = s.lengthSquared - r * r
        if cc <= 0 { return (0, s.normalized) }  // starts inside
        let a = d.lengthSquared
        let disc = b * b - a * cc
        if disc < 0 || a < 1e-12 { return nil }
        let t = (-b - disc.squareRoot()) / a
        guard t >= 0 && t <= 1 else { return nil }
        return (t, (s + d * t).normalized)
    }

    static func rayCapsule(_ o: Vec2, _ d: Vec2, _ a: Vec2, _ b: Vec2, _ r: Float) -> (Float, Vec2)? {
        var best: (Float, Vec2)?
        for c in [a, b] {
            if let h = rayCircle(o, d, c, r), h.0 < (best?.0 ?? .infinity) { best = h }
        }
        // Side rectangles.
        let e = b - a
        let len = e.length
        if len > 1e-6 {
            let t = e / len
            let n = Vec2(t.y, -t.x)
            for side in [n, -n] {
                let p0 = a + side * r
                let denom = side.dot(d)
                if denom >= 0 { continue }
                let tt = side.dot(p0 - o) / denom
                if tt < 0 || tt > 1 { continue }
                let hit = o + d * tt
                let proj = (hit - a).dot(t)
                if proj >= 0 && proj <= len && tt < (best?.0 ?? .infinity) { best = (tt, side) }
            }
        }
        return best
    }

    static func rayPolygon(_ o: Vec2, _ d: Vec2, _ poly: Polygon2D, _ xf: Transform2D) -> (Float, Vec2)? {
        let lo = xf.invApply(o)
        let ld = xf.invRotate(d)
        var lower: Float = 0
        var upper: Float = 1
        var index = -1
        for i in poly.vertices.indices {
            let num = poly.normals[i].dot(poly.vertices[i] - lo)
            let den = poly.normals[i].dot(ld)
            if den == 0 {
                if num < 0 { return nil }
            } else if den < 0 && num < lower * den {
                lower = num / den
                index = i
            } else if den > 0 && num < upper * den {
                upper = num / den
            }
            if upper < lower { return nil }
        }
        if index >= 0 { return (lower, xf.rotate(poly.normals[index])) }
        return (0, Vec2(0, 0))  // origin inside
    }

    /// Point containment test.
    static func contains(_ shape: Shape2D, _ xf: Transform2D, _ p: Vec2) -> Bool {
        switch shape.geometry {
        case .circle(let c, let r): return (p - xf.apply(c)).lengthSquared <= r * r
        case .capsule(let a, let b, let r):
            return (p - closestOnSegment(xf.apply(a), xf.apply(b), p)).lengthSquared <= r * r
        case .polygon(let poly):
            let lp = xf.invApply(p)
            for i in poly.vertices.indices where poly.normals[i].dot(lp - poly.vertices[i]) > 0 { return false }
            return true
        }
    }
}
