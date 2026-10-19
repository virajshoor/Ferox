import FeroxCore
import Foundation

/// Rigid pose used by the 3D narrowphase.
public struct Pose3D: Sendable, Hashable {
    public var position: Vec3
    public var rotation: Quat
    @inlinable public init(position: Vec3 = .zero, rotation: Quat = .identity) {
        self.position = position
        self.rotation = rotation
    }
    @inlinable public func apply(_ v: Vec3) -> Vec3 { rotation.act(v) + position }
    @inlinable public func rotate(_ v: Vec3) -> Vec3 { rotation.act(v) }
    @inlinable public func invApply(_ v: Vec3) -> Vec3 { rotation.conjugate.act(v - position) }
    @inlinable public func invRotate(_ v: Vec3) -> Vec3 { rotation.conjugate.act(v) }
    @inlinable public static func * (a: Pose3D, b: Pose3D) -> Pose3D {
        Pose3D(position: a.apply(b.position), rotation: (a.rotation * b.rotation).normalized)
    }
}

/// Static triangle mesh collider with a bounding-volume hierarchy.
public final class TriangleMesh: @unchecked Sendable, Hashable {
    public let vertices: [Vec3]
    public let indices: [UInt32]
    struct Node {
        var bounds: AABB
        /// Leaf: first triangle and count; interior: left child index and count = 0.
        var start: Int32
        var count: Int32
        var right: Int32
    }
    var nodes: [Node] = []
    var triOrder: [Int32] = []
    public let bounds: AABB

    public init(vertices: [Vec3], indices: [UInt32]) {
        self.vertices = vertices
        let trimmed = Array(indices.prefix(indices.count - indices.count % 3))
        if trimmed.allSatisfy({ Int($0) < vertices.count }) {
            self.indices = trimmed
        } else {
            Log.error("Physics", "TriangleMesh has out-of-range indices; collider will be empty")
            self.indices = []
        }
        var b = AABB.empty
        for v in vertices { b.expand(v) }
        bounds = b
        buildBVH()
    }

    public static func == (a: TriangleMesh, b: TriangleMesh) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    public var triangleCount: Int { indices.count / 3 }

    @inline(__always) func triangle(_ t: Int) -> (Vec3, Vec3, Vec3) {
        (vertices[Int(indices[t * 3])], vertices[Int(indices[t * 3 + 1])], vertices[Int(indices[t * 3 + 2])])
    }

    private func buildBVH() {
        let n = triangleCount
        triOrder = (0..<Int32(n)).map { $0 }
        guard n > 0 else { return }
        var centroids = [Vec3](repeating: .zero, count: n)
        var triBounds = [AABB](repeating: .empty, count: n)
        for t in 0..<n {
            let (a, b, c) = triangle(t)
            centroids[t] = (a + b + c) / 3
            var bb = AABB.empty
            bb.expand(a)
            bb.expand(b)
            bb.expand(c)
            triBounds[t] = bb
        }
        nodes.reserveCapacity(2 * n)
        func build(_ lo: Int, _ hi: Int) -> Int32 {
            var bb = AABB.empty
            var cb = AABB.empty
            for i in lo..<hi {
                bb.expand(triBounds[Int(triOrder[i])])
                cb.expand(centroids[Int(triOrder[i])])
            }
            let idx = nodes.count
            nodes.append(Node(bounds: bb, start: Int32(lo), count: Int32(hi - lo), right: -1))
            if hi - lo <= 4 { return Int32(idx) }
            let ext = cb.size
            let axis = ext.x > ext.y ? (ext.x > ext.z ? 0 : 2) : (ext.y > ext.z ? 1 : 2)
            let mid = (lo + hi) / 2
            var slice = Array(triOrder[lo..<hi])
            slice.sort { centroids[Int($0)][axis] < centroids[Int($1)][axis] }
            triOrder.replaceSubrange(lo..<hi, with: slice)
            _ = build(lo, mid)  // left child is idx + 1
            let right = build(mid, hi)
            nodes[idx].count = 0
            nodes[idx].start = Int32(idx + 1)
            nodes[idx].right = right
            return Int32(idx)
        }
        _ = build(0, n)
    }

    /// Visits triangles whose bounds overlap `box` (mesh-local space).
    func query(_ box: AABB, _ visit: (Int) -> Void) {
        guard !nodes.isEmpty else { return }
        var stack: [Int32] = [0]
        while let ni = stack.popLast() {
            let node = nodes[Int(ni)]
            guard node.bounds.intersects(box) else { continue }
            if node.count > 0 {
                for i in Int(node.start)..<Int(node.start + node.count) { visit(Int(triOrder[i])) }
            } else {
                stack.append(node.start)
                stack.append(node.right)
            }
        }
    }

    /// Closest ray hit in mesh-local space: (t, normal).
    func raycast(origin o: Vec3, direction d: Vec3, maxT: Float) -> (Float, Vec3)? {
        guard !nodes.isEmpty else { return nil }
        var best: (Float, Vec3)?
        var stack: [Int32] = [0]
        let ray = Ray(origin: o, direction: d)
        while let ni = stack.popLast() {
            let node = nodes[Int(ni)]
            guard node.bounds.intersect(ray, maxDistance: best?.0 ?? maxT) != nil else { continue }
            if node.count > 0 {
                for i in Int(node.start)..<Int(node.start + node.count) {
                    let (a, b, c) = triangle(Int(triOrder[i]))
                    if let t = Collide3D.rayTriangle(o, ray.direction, a, b, c), t <= (best?.0 ?? maxT) {
                        best = (t, (b - a).cross(c - a).normalized)
                    }
                }
            } else {
                stack.append(node.start)
                stack.append(node.right)
            }
        }
        if let b = best, b.1.dot(ray.direction) > 0 { return (b.0, -b.1) }
        return best
    }
}

/// Geometry of a 3D collision shape (in shape-local space).
public enum ShapeGeometry3D: Sendable, Hashable {
    case sphere(radius: Float)
    case box(halfExtents: Vec3)
    /// Capsule along local Y with the given half height of the core segment.
    case capsule(halfHeight: Float, radius: Float)
    /// Infinite plane `n · x = d` (static bodies only).
    case plane(normal: Vec3, distance: Float)
    /// Static triangle mesh.
    case mesh(TriangleMesh)
}

/// A collision shape attached to a 3D body with a local offset.
public struct Shape3D: Sendable, Hashable {
    public var geometry: ShapeGeometry3D
    public var localPose: Pose3D
    public var material: PhysicsMaterial
    public var filter: CollisionFilter
    public var isTrigger: Bool

    public init(
        _ geometry: ShapeGeometry3D, localPose: Pose3D = Pose3D(), material: PhysicsMaterial = .default,
        filter: CollisionFilter = .default, isTrigger: Bool = false
    ) {
        self.geometry = geometry
        self.localPose = localPose
        self.material = material
        self.filter = filter
        self.isTrigger = isTrigger
    }

    public static func sphere(_ r: Float) -> Shape3D { Shape3D(.sphere(radius: r)) }
    public static func box(_ halfExtents: Vec3) -> Shape3D { Shape3D(.box(halfExtents: halfExtents)) }
    public static func capsule(height: Float, radius: Float) -> Shape3D {
        Shape3D(.capsule(halfHeight: max(0, height * 0.5 - radius), radius: radius))
    }
    public static func plane(normal: Vec3 = .up, distance: Float = 0) -> Shape3D {
        Shape3D(.plane(normal: normal.normalized, distance: distance))
    }

    /// Mass, local centre and inertia tensor (about the body origin) for the shape's density.
    func massData() -> (mass: Float, center: Vec3, inertia: Mat3) {
        let d = material.density
        var m: Float = 0
        var diag = Vec3.zero
        switch geometry {
        case .sphere(let r):
            m = d * 4 / 3 * .pi * r * r * r
            let i = 0.4 * m * r * r
            diag = Vec3(i, i, i)
        case .box(let h):
            m = d * 8 * h.x * h.y * h.z
            let s = h * 2
            diag = Vec3(s.y * s.y + s.z * s.z, s.x * s.x + s.z * s.z, s.x * s.x + s.y * s.y) * (m / 12)
        case .capsule(let hh, let r):
            let cylM = d * .pi * r * r * 2 * hh
            let hemiM = d * 4 / 3 * .pi * r * r * r
            m = cylM + hemiM
            let h = 2 * hh
            let iy = cylM * r * r / 2 + hemiM * 2 * r * r / 5
            let ix = cylM * (h * h / 12 + r * r / 4) + hemiM * (2 * r * r / 5 + h * h / 4 + 3 * h * r / 8)
            diag = Vec3(ix, iy, ix)
        case .plane, .mesh:
            return (0, .zero, .zero)
        }
        // Rotate the principal tensor into body space and shift with the parallel-axis theorem.
        let r = Mat3(localPose.rotation)
        var inertia = r * Mat3(diagonal: diag) * r.transposed
        let c = localPose.position
        let shift = Mat3(diagonal: Vec3(repeating: c.lengthSquared)) + Mat3(columns: c * -c.x, c * -c.y, c * -c.z)
        inertia = inertia + shift * m
        return (m, c, inertia)
    }

    func aabb(_ bodyPose: Pose3D) -> AABB {
        let pose = bodyPose * localPose
        switch geometry {
        case .sphere(let r): return AABB(center: pose.position, extents: Vec3(repeating: r))
        case .box(let h):
            let m = Mat3(pose.rotation)
            let e = m.c0.absolute * h.x + m.c1.absolute * h.y + m.c2.absolute * h.z
            return AABB(center: pose.position, extents: e)
        case .capsule(let hh, let r):
            let a = pose.apply(Vec3(0, -hh, 0))
            let b = pose.apply(Vec3(0, hh, 0))
            return AABB(min: pointwiseMin(a, b) - r, max: pointwiseMax(a, b) + r)
        case .plane:
            return AABB(min: Vec3(repeating: -1e9), max: Vec3(repeating: 1e9))
        case .mesh(let mesh):
            return mesh.bounds.transformed(
                by: Mat4(translation: pose.position, rotation: pose.rotation, scale: Vec3(1, 1, 1)))
        }
    }
}

struct ContactPoint3D {
    var point: Vec3
    var separation: Float
    var id: UInt32
}

struct Manifold3D {
    /// Normal from A to B.
    var normal: Vec3 = .zero
    var points: [ContactPoint3D] = []
}

/// Narrow-phase routines (world space).
enum Collide3D {
    static func manifold(_ a: Shape3D, _ pa: Pose3D, _ b: Shape3D, _ pb: Pose3D, margin: Float) -> Manifold3D {
        let wa = pa * a.localPose
        let wb = pb * b.localPose
        switch (a.geometry, b.geometry) {
        case (.sphere(let ra), .sphere(let rb)):
            return spheres(wa.position, ra, wb.position, rb, margin)
        case (.sphere(let ra), .box(let hb)):
            return flip(boxSphere(hb, wb, wa.position, ra, margin))
        case (.box(let ha), .sphere(let rb)):
            return boxSphere(ha, wa, wb.position, rb, margin)
        case (.box(let ha), .box(let hb)):
            return boxes(ha, wa, hb, wb, margin)
        case (.capsule(let hh, let r), .sphere(let rb)):
            let (s0, s1) = segment(hh, wa)
            return spheres(closestOnSegment(s0, s1, wb.position), r, wb.position, rb, margin)
        case (.sphere(let ra), .capsule(let hh, let r)):
            let (s0, s1) = segment(hh, wb)
            return spheres(wa.position, ra, closestOnSegment(s0, s1, wa.position), r, margin)
        case (.capsule(let ha, let ra), .capsule(let hb, let rb)):
            return capsules(segment(ha, wa), ra, segment(hb, wb), rb, margin)
        case (.capsule(let hh, let r), .box(let hb)):
            return flip(boxCapsule(hb, wb, segment(hh, wa), r, margin))
        case (.box(let ha), .capsule(let hh, let r)):
            return boxCapsule(ha, wa, segment(hh, wb), r, margin)
        case (.plane(let n, let d), _):
            let wn = pa.rotate(n)
            let wd = d + wn.dot(pa.position)
            return planeShape(wn, wd, b, wb, margin)
        case (_, .plane(let n, let d)):
            let wn = pb.rotate(n)
            let wd = d + wn.dot(pb.position)
            return flip(planeShape(wn, wd, a, wa, margin))
        case (.mesh(let mesh), _):
            return meshShape(mesh, wa, b, wb, margin)
        case (_, .mesh(let mesh)):
            return flip(meshShape(mesh, wb, a, wa, margin))
        }
    }

    static func flip(_ m: Manifold3D) -> Manifold3D {
        var r = m
        r.normal = -m.normal
        return r
    }

    @inline(__always) static func segment(_ hh: Float, _ pose: Pose3D) -> (Vec3, Vec3) {
        (pose.apply(Vec3(0, -hh, 0)), pose.apply(Vec3(0, hh, 0)))
    }

    static func closestOnSegment(_ a: Vec3, _ b: Vec3, _ p: Vec3) -> Vec3 {
        let ab = b - a
        let l2 = ab.lengthSquared
        let t = l2 > 1e-12 ? ((p - a).dot(ab) / l2).saturated : 0
        return a + ab * t
    }

    static func spheres(_ ca: Vec3, _ ra: Float, _ cb: Vec3, _ rb: Float, _ margin: Float) -> Manifold3D {
        let d = cb - ca
        let dist = d.length
        let sep = dist - ra - rb
        guard sep <= margin else { return Manifold3D() }
        let n = dist > 1e-6 ? d / dist : Vec3.up
        return Manifold3D(normal: n, points: [ContactPoint3D(point: ca + n * (ra + sep * 0.5), separation: sep, id: 0)])
    }

    /// Box (A) against sphere (B).
    static func boxSphere(_ h: Vec3, _ pose: Pose3D, _ center: Vec3, _ r: Float, _ margin: Float) -> Manifold3D {
        let lc = pose.invApply(center)
        let clamped = pointwiseMax(-h, pointwiseMin(h, lc))
        var normalLocal: Vec3
        var sep: Float
        var surfaceLocal: Vec3
        if clamped == lc {
            // Centre inside the box: push out along the axis of least penetration.
            let dist = h - lc.absolute
            var axis = 0
            if dist.y < dist[axis] { axis = 1 }
            if dist.z < dist[axis] { axis = 2 }
            normalLocal = .zero
            normalLocal[axis] = lc[axis] >= 0 ? 1 : -1
            sep = -dist[axis] - r
            surfaceLocal = lc
            surfaceLocal[axis] = h[axis] * normalLocal[axis]
        } else {
            let d = lc - clamped
            let dist = d.length
            sep = dist - r
            if sep > margin { return Manifold3D() }
            normalLocal = d / dist
            surfaceLocal = clamped
        }
        let n = pose.rotate(normalLocal)
        let p = pose.apply(surfaceLocal) + n * (sep * 0.5)
        return Manifold3D(normal: n, points: [ContactPoint3D(point: p, separation: sep, id: 0)])
    }

    /// Closest points between segments (Ericson RTCD 5.1.9).
    static func closestSegmentSegment(_ p1: Vec3, _ q1: Vec3, _ p2: Vec3, _ q2: Vec3) -> (Vec3, Vec3) {
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

    static func capsules(_ sa: (Vec3, Vec3), _ ra: Float, _ sb: (Vec3, Vec3), _ rb: Float, _ margin: Float)
        -> Manifold3D
    {
        let da = sa.1 - sa.0
        let db = sb.1 - sb.0
        if da.lengthSquared > 1e-8 && db.lengthSquared > 1e-8 && da.normalized.cross(db.normalized).length < 0.05 {
            // Near-parallel: up to two points from B's endpoints for stable resting contact.
            var m = Manifold3D()
            for (i, p) in [sb.0, sb.1].enumerated() {
                let sub = spheres(closestOnSegment(sa.0, sa.1, p), ra, p, rb, margin)
                if var cp = sub.points.first {
                    cp.id = UInt32(i)
                    m.normal = sub.normal
                    m.points.append(cp)
                }
            }
            if !m.points.isEmpty { return m }
        }
        let (ca, cb) = closestSegmentSegment(sa.0, sa.1, sb.0, sb.1)
        return spheres(ca, ra, cb, rb, margin)
    }

    /// Box (A) vs capsule (B): sphere tests at the segment endpoints and at the point of the
    /// segment closest to the box, keeping up to two deepest points.
    static func boxCapsule(_ h: Vec3, _ pose: Pose3D, _ seg: (Vec3, Vec3), _ r: Float, _ margin: Float) -> Manifold3D {
        // Iteratively find the segment point closest to the box (alternating projection).
        var p = (seg.0 + seg.1) * 0.5
        for _ in 0..<4 {
            let lp = pose.invApply(p)
            let onBox = pose.apply(pointwiseMax(-h, pointwiseMin(h, lp)))
            p = closestOnSegment(seg.0, seg.1, onBox)
        }
        var candidates: [(ContactPoint3D, Vec3)] = []
        for (i, q) in [seg.0, seg.1, p].enumerated() {
            let m = boxSphere(h, pose, q, r, margin)
            if var cp = m.points.first {
                cp.id = UInt32(i)
                candidates.append((cp, m.normal))
            }
        }
        guard !candidates.isEmpty else { return Manifold3D() }
        candidates.sort { $0.0.separation < $1.0.separation }
        var out = Manifold3D(normal: candidates[0].1, points: [candidates[0].0])
        // Add a second point when it shares the normal (flat resting capsule).
        for c in candidates.dropFirst()
        where c.1.dot(out.normal) > 0.95 && (c.0.point - out.points[0].point).lengthSquared > 1e-4 {
            out.points.append(c.0)
            break
        }
        return out
    }

    /// Plane (A, world normal n, offset d) vs any convex shape B.
    static func planeShape(_ n: Vec3, _ d: Float, _ b: Shape3D, _ pose: Pose3D, _ margin: Float) -> Manifold3D {
        var m = Manifold3D(normal: n)
        func add(_ p: Vec3, _ r: Float, _ id: UInt32) {
            let sep = n.dot(p) - d - r
            if sep <= margin {
                m.points.append(ContactPoint3D(point: p - n * (r + sep * 0.5), separation: sep, id: id))
            }
        }
        switch b.geometry {
        case .sphere(let r): add(pose.position, r, 0)
        case .capsule(let hh, let r):
            let (s0, s1) = segment(hh, pose)
            add(s0, r, 0)
            add(s1, r, 1)
        case .box(let h):
            var id: UInt32 = 0
            for sx in [Float(-1), 1] {
                for sy in [Float(-1), 1] {
                    for sz in [Float(-1), 1] {
                        add(pose.apply(Vec3(sx * h.x, sy * h.y, sz * h.z)), 0, id)
                        id += 1
                    }
                }
            }
            if m.points.count > 4 {
                m.points.sort { $0.separation < $1.separation }
                m.points = reduceTo4(m.points, normal: n)
            }
        case .plane, .mesh:
            break
        }
        return m
    }

    /// Keeps four well-spread points: deepest, farthest from it, and two maximising area.
    static func reduceTo4(_ pts: [ContactPoint3D], normal: Vec3) -> [ContactPoint3D] {
        guard pts.count > 4 else { return pts }
        var chosen: [ContactPoint3D] = []
        let a = pts.min { $0.separation < $1.separation }!
        chosen.append(a)
        let b = pts.max { ($0.point - a.point).lengthSquared < ($1.point - a.point).lengthSquared }!
        chosen.append(b)
        let c = pts.max {
            (($0.point - a.point).cross($0.point - b.point)).dot(normal)
                < (($1.point - a.point).cross($1.point - b.point)).dot(normal)
        }!
        chosen.append(c)
        let dPt = pts.min {
            (($0.point - a.point).cross($0.point - b.point)).dot(normal)
                < (($1.point - a.point).cross($1.point - b.point)).dot(normal)
        }!
        if !chosen.contains(where: { $0.id == dPt.id }) { chosen.append(dPt) }
        return chosen
    }

    // MARK: Box-box (SAT + clipping)

    static func boxes(_ ha: Vec3, _ pa: Pose3D, _ hb: Vec3, _ pb: Pose3D, _ margin: Float) -> Manifold3D {
        let ra = Mat3(pa.rotation)
        let rb = Mat3(pb.rotation)
        let axA = [ra.c0, ra.c1, ra.c2]
        let axB = [rb.c0, rb.c1, rb.c2]
        let t = pb.position - pa.position

        func projectedRadius(_ axes: [Vec3], _ h: Vec3, _ n: Vec3) -> Float {
            Swift.abs(axes[0].dot(n)) * h.x + Swift.abs(axes[1].dot(n)) * h.y + Swift.abs(axes[2].dot(n)) * h.z
        }

        var bestScore = -Float.infinity
        var bestAxis = Vec3.zero
        var bestType = 0  // 0: face A, 1: face B, 2: edge-edge
        var bestIndex = (0, 0)

        func test(_ axis: Vec3, _ type: Int, _ idx: (Int, Int)) -> Bool {
            let l2 = axis.lengthSquared
            if l2 < 1e-8 { return true }
            let n = axis / l2.squareRoot()
            let sep = Swift.abs(t.dot(n)) - projectedRadius(axA, ha, n) - projectedRadius(axB, hb, n)
            if sep > margin { return false }
            // Bias towards face axes for stable manifolds.
            let biased = type == 2 ? sep - 0.001 : sep
            if biased > bestScore {
                bestScore = biased
                bestAxis = t.dot(n) < 0 ? -n : n
                bestType = type
                bestIndex = idx
            }
            return true
        }

        for i in 0..<3 { if !test(axA[i], 0, (i, 0)) { return Manifold3D() } }
        for i in 0..<3 { if !test(axB[i], 1, (i, 0)) { return Manifold3D() } }
        for i in 0..<3 {
            for j in 0..<3 { if !test(axA[i].cross(axB[j]), 2, (i, j)) { return Manifold3D() } }
        }

        let n = bestAxis  // points from A to B
        if bestType == 2 {
            // Edge-edge: find the supporting edges and their closest points.
            let (i, j) = bestIndex
            func supportEdge(_ axes: [Vec3], _ h: Vec3, _ center: Vec3, _ dir: Vec3, _ edgeAxis: Int) -> (Vec3, Vec3) {
                var p = center
                for k in 0..<3 where k != edgeAxis {
                    p += axes[k] * (axes[k].dot(dir) > 0 ? h[k] : -h[k])
                }
                return (p - axes[edgeAxis] * h[edgeAxis], p + axes[edgeAxis] * h[edgeAxis])
            }
            let ea = supportEdge(axA, ha, pa.position, n, i)
            let eb = supportEdge(axB, hb, pb.position, -n, j)
            let (ca, cb) = closestSegmentSegment(ea.0, ea.1, eb.0, eb.1)
            let sep = (cb - ca).dot(n)
            return Manifold3D(
                normal: n,
                points: [ContactPoint3D(point: (ca + cb) * 0.5, separation: sep, id: 0xE000 | UInt32(i * 3 + j))])
        }

        // Face contact: reference box/face and incident box.
        let refIsA = bestType == 0
        let refAxes = refIsA ? axA : axB
        let incAxes = refIsA ? axB : axA
        let refH = refIsA ? ha : hb
        let incH = refIsA ? hb : ha
        let refC = refIsA ? pa.position : pb.position
        let incC = refIsA ? pb.position : pa.position
        let refN = refIsA ? n : -n  // reference face normal, pointing towards the incident box
        let fi = bestIndex.0

        // Incident face: the face of the incident box most anti-parallel to refN.
        var incAxis = 0
        var minDot = Float.infinity
        for k in 0..<3 {
            let d = incAxes[k].dot(refN)
            if -Swift.abs(d) < minDot {
                minDot = -Swift.abs(d)
                incAxis = k
            }
        }
        let incSign: Float = incAxes[incAxis].dot(refN) > 0 ? -1 : 1
        let incCenter = incC + incAxes[incAxis] * (incH[incAxis] * incSign)
        let u = (incAxis + 1) % 3
        let v = (incAxis + 2) % 3
        var poly: [Vec3] = [
            incCenter + incAxes[u] * incH[u] + incAxes[v] * incH[v],
            incCenter - incAxes[u] * incH[u] + incAxes[v] * incH[v],
            incCenter - incAxes[u] * incH[u] - incAxes[v] * incH[v],
            incCenter + incAxes[u] * incH[u] - incAxes[v] * incH[v],
        ]

        // Clip against the four side planes of the reference face.
        let ru = (fi + 1) % 3
        let rv = (fi + 2) % 3
        let refFaceCenter = refC + refN * refH[fi]
        for (axis, extent) in [(refAxes[ru], refH[ru]), (refAxes[rv], refH[rv])] {
            for s in [Float(1), -1] {
                let pn = axis * s
                let offset = pn.dot(refC) + extent
                poly = clipPolygon(poly, pn, offset)
                if poly.isEmpty { return Manifold3D() }
            }
        }

        var m = Manifold3D(normal: n)
        let faceOffset = refN.dot(refFaceCenter)
        for (k, p) in poly.enumerated() {
            let sep = refN.dot(p) - faceOffset
            if sep <= margin {
                let id = (refIsA ? 0 : 0x8000) | UInt32(fi << 8) | UInt32(incAxis << 4) | UInt32(k)
                m.points.append(ContactPoint3D(point: p - refN * (sep * 0.5), separation: sep, id: id))
            }
        }
        if m.points.count > 4 { m.points = reduceTo4(m.points, normal: n) }
        return m
    }

    /// Sutherland–Hodgman clipping keeping the side where `n · p <= offset`.
    static func clipPolygon(_ poly: [Vec3], _ n: Vec3, _ offset: Float) -> [Vec3] {
        var out: [Vec3] = []
        out.reserveCapacity(poly.count + 2)
        for i in poly.indices {
            let a = poly[i]
            let b = poly[(i + 1) % poly.count]
            let da = n.dot(a) - offset
            let db = n.dot(b) - offset
            if da <= 0 { out.append(a) }
            if da * db < 0 { out.append(a + (b - a) * (da / (da - db))) }
        }
        return out
    }

    // MARK: Mesh

    static func closestOnTriangle(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3 {
        // Ericson RTCD 5.1.5.
        let ab = b - a
        let ac = c - a
        let ap = p - a
        let d1 = ab.dot(ap)
        let d2 = ac.dot(ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = ab.dot(bp)
        let d4 = ac.dot(bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
        let cp = p - c
        let d5 = ab.dot(cp)
        let d6 = ac.dot(cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    /// Mesh (A) vs sphere or capsule (B). Box/mesh contact is not supported (see docs).
    static func meshShape(_ mesh: TriangleMesh, _ meshPose: Pose3D, _ b: Shape3D, _ pose: Pose3D, _ margin: Float)
        -> Manifold3D
    {
        let core: (Vec3, Vec3)
        let r: Float
        switch b.geometry {
        case .sphere(let rr):
            core = (pose.position, pose.position)
            r = rr
        case .capsule(let hh, let rr):
            core = segment(hh, pose)
            r = rr
        case .box(let h):
            // Boxes are approximated by an inscribed capsule along their longest axis
            // (documented limitation; prefer capsules/spheres for bodies touching meshes).
            let ax = h.x >= h.y ? (h.x >= h.z ? 0 : 2) : (h.y >= h.z ? 1 : 2)
            var dir = Vec3.zero
            dir[ax] = 1
            let rad = min(h[(ax + 1) % 3], h[(ax + 2) % 3])
            let half = max(0, h[ax] - rad)
            core = (pose.apply(-dir * half), pose.apply(dir * half))
            r = rad
        default:
            return Manifold3D()
        }
        let lc0 = meshPose.invApply(core.0)
        let lc1 = meshPose.invApply(core.1)
        let pad = Vec3(repeating: r + margin)
        let qb = AABB(min: pointwiseMin(lc0, lc1) - pad, max: pointwiseMax(lc0, lc1) + pad)
        var best: [(ContactPoint3D, Vec3)] = []
        mesh.query(qb) { t in
            let (a, bb, c) = mesh.triangle(t)
            // Closest point between the core segment and the triangle (sampled + refined).
            var sp = (lc0 + lc1) * 0.5
            var tp = closestOnTriangle(sp, a, bb, c)
            for _ in 0..<3 {
                sp = closestOnSegment(lc0, lc1, tp)
                tp = closestOnTriangle(sp, a, bb, c)
            }
            for q in [lc0, lc1] {
                let tq = closestOnTriangle(q, a, bb, c)
                if (q - tq).lengthSquared < (sp - tp).lengthSquared {
                    sp = q
                    tp = tq
                }
            }
            let d = sp - tp
            let dist = d.length
            let sep = dist - r
            guard sep <= margin else { return }
            let faceN = (bb - a).cross(c - a).normalized
            var nLocal = dist > 1e-6 ? d / dist : faceN
            if nLocal.dot(faceN) < 0 && dist < 1e-6 { nLocal = -nLocal }
            // Normal from mesh (A) to shape (B).
            let n = meshPose.rotate(nLocal)
            let p = meshPose.apply(tp + nLocal * (sep * 0.5))
            best.append((ContactPoint3D(point: p, separation: sep, id: UInt32(truncatingIfNeeded: t)), n))
        }
        guard !best.isEmpty else { return Manifold3D() }
        best.sort { $0.0.separation < $1.0.separation }
        // Average normal of the deepest contacts (smooths internal-edge bumps).
        var n = Vec3.zero
        for c in best.prefix(4) { n += c.1 }
        return Manifold3D(normal: n.normalized, points: best.prefix(4).map(\.0))
    }

    // MARK: Ray casts (world space): returns (t, normal) with t in [0, maxT]

    static func rayTriangle(_ o: Vec3, _ d: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Float? {
        // Möller–Trumbore, two-sided.
        let e1 = b - a
        let e2 = c - a
        let p = d.cross(e2)
        let det = e1.dot(p)
        if Swift.abs(det) < 1e-10 { return nil }
        let inv = 1 / det
        let s = o - a
        let u = s.dot(p) * inv
        if u < 0 || u > 1 { return nil }
        let q = s.cross(e1)
        let v = d.dot(q) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = e2.dot(q) * inv
        return t >= 0 ? t : nil
    }

    static func raySphere(_ o: Vec3, _ d: Vec3, _ c: Vec3, _ r: Float, _ maxT: Float) -> (Float, Vec3)? {
        let s = o - c
        let b = s.dot(d)
        let cc = s.lengthSquared - r * r
        if cc <= 0 { return (0, -d) }
        let disc = b * b - cc
        if disc < 0 { return nil }
        let t = -b - disc.squareRoot()
        guard t >= 0 && t <= maxT else { return nil }
        return (t, (s + d * t).normalized)
    }

    static func rayCapsule(_ o: Vec3, _ d: Vec3, _ a: Vec3, _ b: Vec3, _ r: Float, _ maxT: Float) -> (Float, Vec3)? {
        var best: (Float, Vec3)?
        for c in [a, b] { if let h = raySphere(o, d, c, r, maxT), h.0 < (best?.0 ?? .infinity) { best = h } }
        // Infinite cylinder around the segment, clipped to its length.
        let ab = b - a
        let len2 = ab.lengthSquared
        if len2 > 1e-10 {
            let ao = o - a
            let abd = ab.dot(d)
            let abao = ab.dot(ao)
            let qa = len2 - abd * abd
            let qb = len2 * ao.dot(d) - abao * abd
            let qc = len2 * ao.lengthSquared - abao * abao - r * r * len2
            let disc = qb * qb - qa * qc
            if qa > 1e-10 && disc >= 0 {
                let t = (-qb - disc.squareRoot()) / qa
                if t >= 0 && t <= maxT && t < (best?.0 ?? .infinity) {
                    let hit = o + d * t
                    let proj = (hit - a).dot(ab)
                    if proj >= 0 && proj <= len2 {
                        let axisPt = a + ab * (proj / len2)
                        best = (t, (hit - axisPt).normalized)
                    }
                }
            }
        }
        return best
    }

    static func rayShape(_ s: Shape3D, _ bodyPose: Pose3D, _ o: Vec3, _ d: Vec3, _ maxT: Float, inflate: Float) -> (
        Float, Vec3
    )? {
        let pose = bodyPose * s.localPose
        switch s.geometry {
        case .sphere(let r):
            return raySphere(o, d, pose.position, r + inflate, maxT)
        case .capsule(let hh, let r):
            let (a, b) = segment(hh, pose)
            return rayCapsule(o, d, a, b, r + inflate, maxT)
        case .box(let h):
            // Inflated boxes approximate rounded-box sweeps conservatively at the corners.
            let lo = pose.invApply(o)
            let ld = pose.invRotate(d)
            let box = AABB(center: .zero, extents: h + inflate)
            guard let t = box.intersect(Ray(origin: lo, direction: ld), maxDistance: maxT) else { return nil }
            let hit = lo + ld * t
            var nl = Vec3.zero
            let rel = hit / (h + inflate)
            let a = rel.absolute
            let axis = a.x > a.y ? (a.x > a.z ? 0 : 2) : (a.y > a.z ? 1 : 2)
            nl[axis] = rel[axis] >= 0 ? 1 : -1
            return (t, pose.rotate(nl))
        case .plane(let n, let dist):
            let wn = bodyPose.rotate(n)
            let wd = dist + wn.dot(bodyPose.position) + inflate
            let denom = wn.dot(d)
            if Swift.abs(denom) < 1e-8 { return nil }
            let t = (wd - wn.dot(o)) / denom
            guard t >= 0 && t <= maxT else { return nil }
            return (t, wn)
        case .mesh(let mesh):
            let lo = pose.invApply(o)
            let ld = pose.invRotate(d)
            guard let hit = mesh.raycast(origin: lo, direction: ld, maxT: maxT) else { return nil }
            let (t, nl) = hit
            // Sphere sweeps against meshes are approximated by pulling the hit back along the ray.
            let tt = max(0, t - inflate)
            return (tt, pose.rotate(nl))
        }
    }
}
