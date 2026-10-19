import FeroxMath

/// A convex polyhedron in shape-local space. `build` returns nil when the points do not
/// span a volume (fewer than four points, or all of them coplanar / collinear).
public struct ConvexHull3D: Sendable, Hashable {
    public var vertices: [Vec3]
    /// Triangle list, three indices per face, wound so the normal points outwards.
    public var indices: [UInt32]

    public init(vertices: [Vec3], indices: [UInt32]) {
        self.vertices = vertices
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }

    public var centroid: Vec3 {
        guard !vertices.isEmpty else { return .zero }
        var sum = Vec3.zero
        for v in vertices { sum = sum + v }
        return sum / Float(vertices.count)
    }

    public var bounds: AABB {
        var box = AABB.empty
        for v in vertices { box.expand(v) }
        return box
    }

    /// Absolute volume. Zero when the hull is degenerate.
    public var volume: Float {
        var signed: Float = 0
        let n = triangleCount
        for t in 0..<n {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            signed += a.dot(b.cross(c))
        }
        return abs(signed) / 6
    }

    public static func build(_ points: [Vec3]) -> ConvexHull3D? {
        let unique = dedupe(points)
        guard unique.count >= 4, let seed = initialTetrahedron(unique) else { return nil }
        var faces: [Face] = seed.faces
        var interior = Vec3.zero
        for i in seed.corners { interior = interior + unique[i] }
        interior = interior / 4
        var assigned = Set(seed.corners)
        for face in faces.indices {
            for (index, point) in unique.enumerated() where !assigned.contains(index) {
                if faces[face].distance(point) > epsilon {
                    faces[face].outside.append(index)
                }
            }
        }
        var guardSteps = unique.count * unique.count + 8
        while guardSteps > 0,
            let index = faces.indices.max(by: { furthest(unique, faces[$0]) < furthest(unique, faces[$1]) }),
            let pointIndex = faces[index].outside.max(by: {
                faces[index].distance(unique[$0]) < faces[index].distance(unique[$1])
            })
        {
            guardSteps -= 1
            let eye = unique[pointIndex]
            var visible = Set<Int>()
            for (fi, face) in faces.enumerated() where face.distance(eye) > epsilon { visible.insert(fi) }
            if visible.isEmpty { break }
            var orphans: [Int] = []
            var directed = Set<Edge>()
            for fi in visible {
                orphans.append(contentsOf: faces[fi].outside)
                let tri = faces[fi].indices
                directed.insert(Edge(tri.0, tri.1))
                directed.insert(Edge(tri.1, tri.2))
                directed.insert(Edge(tri.2, tri.0))
            }
            // A horizon edge borders exactly one visible face, so its reverse is not visible.
            let horizon = directed.filter { !directed.contains(Edge($0.b, $0.a)) }
            faces = faces.enumerated().filter { !visible.contains($0.offset) }.map(\.element)
            for edge in horizon {
                guard var face = Face(unique, edge.a, edge.b, pointIndex, interior: interior) else { continue }
                for candidate in orphans where candidate != pointIndex && face.distance(unique[candidate]) > epsilon {
                    face.outside.append(candidate)
                }
                faces.append(face)
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(faces.count * 3)
        for face in faces {
            indices.append(UInt32(face.indices.0))
            indices.append(UInt32(face.indices.1))
            indices.append(UInt32(face.indices.2))
        }
        let hull = ConvexHull3D(vertices: unique, indices: indices)
        guard hull.volume > 1e-8 else { return nil }
        return hull
    }

    public func raycast(origin: Vec3, direction: Vec3, maxT: Float) -> (Float, Vec3)? {
        let dir = direction
        var best: (Float, Vec3)?
        let n = triangleCount
        for t in 0..<n {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            let ab = b - a
            let ac = c - a
            let p = dir.cross(ac)
            let det = ab.dot(p)
            if abs(det) < 1e-8 { continue }
            let inv = 1 / det
            let tvec = origin - a
            let u = tvec.dot(p) * inv
            if u < 0 || u > 1 { continue }
            let q = tvec.cross(ab)
            let v = dir.dot(q) * inv
            if v < 0 || u + v > 1 { continue }
            let hit = ac.dot(q) * inv
            if hit < 0 || hit > maxT { continue }
            if hit < best?.0 ?? .infinity {
                let normal = ab.cross(ac).normalized
                best = (hit, det < 0 ? -normal : normal)
            }
        }
        return best
    }

    /// Closest point on the hull surface and the outward normal of the face that owns it.
    public func closestPoint(_ point: Vec3) -> (point: Vec3, normal: Vec3) {
        var best = vertices.first ?? .zero
        var bestDistance = Float.infinity
        var normal = Vec3.up
        let n = triangleCount
        for t in 0..<n {
            let a = vertices[Int(indices[t * 3])]
            let b = vertices[Int(indices[t * 3 + 1])]
            let c = vertices[Int(indices[t * 3 + 2])]
            let q = Self.closestOnTriangle(point, a, b, c)
            let d = (point - q).lengthSquared
            if d < bestDistance {
                bestDistance = d
                best = q
                let nrm = (b - a).cross(c - a)
                normal = nrm.lengthSquared > 0 ? nrm.normalized : normal
            }
        }
        return (best, normal)
    }

    public func support(_ direction: Vec3) -> Vec3 {
        var best = vertices[0]
        var bestDot = best.dot(direction)
        for v in vertices.dropFirst() {
            let d = v.dot(direction)
            if d > bestDot {
                bestDot = d
                best = v
            }
        }
        return best
    }

    private static let epsilon: Float = 1e-5

    private struct Edge: Hashable {
        var a: Int
        var b: Int
        init(_ a: Int, _ b: Int) {
            self.a = a
            self.b = b
        }
    }

    private struct Face {
        var indices: (Int, Int, Int)
        var normal: Vec3
        var offset: Float
        var outside: [Int] = []

        init?(_ points: [Vec3], _ i: Int, _ j: Int, _ k: Int, interior: Vec3) {
            let a = points[i]
            let b = points[j]
            let c = points[k]
            let n = (b - a).cross(c - a)
            let len = n.length
            guard len > 1e-8 else { return nil }
            var normal = n / len
            var offset = normal.dot(a)
            if normal.dot(interior) - offset > 0 {
                normal = -normal
                offset = -offset
                indices = (i, k, j)
            } else {
                indices = (i, j, k)
            }
            self.normal = normal
            self.offset = offset
        }

        func distance(_ point: Vec3) -> Float { normal.dot(point) - offset }
    }

    private static func furthest(_ points: [Vec3], _ face: Face) -> Float {
        face.outside.reduce(0) { max($0, face.distance(points[$1])) }
    }

    private static func dedupe(_ points: [Vec3]) -> [Vec3] {
        var out: [Vec3] = []
        for p in points where !out.contains(where: { ($0 - p).lengthSquared < 1e-10 }) {
            out.append(p)
        }
        return out
    }

    private static func initialTetrahedron(_ points: [Vec3]) -> (corners: [Int], faces: [Face])? {
        var minX = 0
        var maxX = 0
        for i in points.indices {
            if points[i].x < points[minX].x { minX = i }
            if points[i].x > points[maxX].x { maxX = i }
        }
        if minX == maxX { return nil }
        let axis = points[maxX] - points[minX]
        var farLine = -1
        var farLineDist: Float = 0
        for i in points.indices where i != minX && i != maxX {
            let d = (points[i] - points[minX]).cross(axis).lengthSquared
            if d > farLineDist {
                farLineDist = d
                farLine = i
            }
        }
        guard farLine >= 0, farLineDist > 1e-10 else { return nil }
        let ab = points[farLine] - points[minX]
        let acRef = axis
        let normal = ab.cross(acRef)
        var farPlane = -1
        var farPlaneDist: Float = 0
        for i in points.indices where i != minX && i != maxX && i != farLine {
            let d = abs(normal.dot(points[i] - points[minX]))
            if d > farPlaneDist {
                farPlaneDist = d
                farPlane = i
            }
        }
        guard farPlane >= 0, farPlaneDist > 1e-8 else { return nil }
        let corners = [minX, maxX, farLine, farPlane]
        var interior = Vec3.zero
        for i in corners { interior = interior + points[i] }
        interior = interior / 4
        let tris = [(0, 1, 2), (0, 2, 3), (0, 3, 1), (1, 3, 2)]
        var faces: [Face] = []
        for tri in tris {
            guard let face = Face(points, corners[tri.0], corners[tri.1], corners[tri.2], interior: interior) else {
                return nil
            }
            faces.append(face)
        }
        return (corners, faces)
    }

    private static func closestOnTriangle(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3 {
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
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
        }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }
}

/// Face-SAT and closest-point contact for convex shapes. Sphere and capsule queries use the
/// hull surface directly. Hull and box pairs use the face normals of whichever shape has
/// faces; edge-edge axes are not searched.
enum ConvexContact {
    struct Point {
        var a: Vec3
        var b: Vec3
        var delta: Vec3
    }

    static func isConvex(_ g: ShapeGeometry3D) -> Bool {
        switch g {
        case .sphere, .box, .capsule, .convex: return true
        case .plane, .mesh: return false
        }
    }

    static func support(_ shape: Shape3D, _ pose: Pose3D, _ direction: Vec3) -> Vec3 {
        let dir = direction.lengthSquared > 0 ? direction.normalized : Vec3.up
        switch shape.geometry {
        case .sphere(let radius):
            return pose.position + dir * radius
        case .box(let half):
            let local = pose.invRotate(dir)
            let corner = Vec3(
                local.x >= 0 ? half.x : -half.x, local.y >= 0 ? half.y : -half.y, local.z >= 0 ? half.z : -half.z)
            return pose.apply(corner)
        case .capsule(let halfHeight, let radius):
            let axis = pose.rotate(Vec3(0, 1, 0))
            let end = pose.position + axis * (dir.dot(axis) >= 0 ? halfHeight : -halfHeight)
            return end + dir * radius
        case .convex(let hull):
            return pose.apply(hull.support(pose.invRotate(dir)))
        case .plane, .mesh:
            return pose.position
        }
    }

    static func manifold(_ a: Shape3D, _ pa: Pose3D, _ b: Shape3D, _ pb: Pose3D, margin: Float) -> Manifold3D {
        if case .sphere(let radius) = a.geometry, case .convex(let hull) = b.geometry {
            return sphereHull(pa.position, radius, hull, pb, margin)
        }
        if case .convex(let hull) = a.geometry, case .sphere(let radius) = b.geometry {
            return Collide3D.flip(sphereHull(pb.position, radius, hull, pa, margin))
        }
        if case .capsule(let halfHeight, let radius) = a.geometry, case .convex(let hull) = b.geometry {
            let (s0, s1) = Collide3D.segment(halfHeight, pa)
            return sphereHull(closestSegmentPoint(s0, s1, hull, pb), radius, hull, pb, margin)
        }
        if case .convex(let hull) = a.geometry, case .capsule(let halfHeight, let radius) = b.geometry {
            let (s0, s1) = Collide3D.segment(halfHeight, pb)
            return Collide3D.flip(sphereHull(closestSegmentPoint(s0, s1, hull, pa), radius, hull, pa, margin))
        }
        return sat(a, pa, b, pb, margin)
    }

    /// Normal points from the sphere centre toward the hull.
    private static func sphereHull(
        _ center: Vec3, _ radius: Float, _ hull: ConvexHull3D, _ pose: Pose3D, _ margin: Float
    ) -> Manifold3D {
        let closest = hull.closestPoint(pose.invApply(center))
        let worldPoint = pose.apply(closest.point)
        let worldNormal = pose.rotate(closest.normal)
        let delta = worldPoint - center
        let dist = delta.length
        let separation = dist - radius
        guard separation <= margin else { return Manifold3D() }
        let normal = dist > 1e-6 ? delta / dist : -worldNormal
        let surface = center + normal * radius
        let mid = (surface + worldPoint) * 0.5
        return Manifold3D(normal: normal, points: [ContactPoint3D(point: mid, separation: separation, id: 0)])
    }

    private static func closestSegmentPoint(_ a: Vec3, _ b: Vec3, _ hull: ConvexHull3D, _ pose: Pose3D) -> Vec3 {
        var p = (a + b) * 0.5
        for _ in 0..<4 {
            let onHull = pose.apply(hull.closestPoint(pose.invApply(p)).point)
            let ab = b - a
            let l2 = ab.lengthSquared
            let t = l2 > 1e-12 ? ((onHull - a).dot(ab) / l2).saturated : 0
            p = a + ab * t
        }
        return p
    }

    /// Face axes of boxes and hulls. `separation` is the support of B behind A's outward plane
    /// (negative when penetrating). The axis with the greatest separation is the contact axis.
    private static func sat(_ a: Shape3D, _ pa: Pose3D, _ b: Shape3D, _ pb: Pose3D, _ margin: Float) -> Manifold3D {
        var best = -Float.greatestFiniteMagnitude
        var normal = Vec3.up
        var sawAxis = false
        func consider(_ shape: Shape3D, _ pose: Pose3D, _ other: Shape3D, _ otherPose: Pose3D, _ sign: Float) -> Bool {
            for axis in faceAxes(shape, pose) {
                sawAxis = true
                let supportPoint = support(other, otherPose, -axis.normal)
                let separation = axis.normal.dot(supportPoint - axis.point)
                if separation > margin { return true }
                if separation > best {
                    best = separation
                    normal = axis.normal * sign
                }
            }
            return false
        }
        if consider(a, pa, b, pb, 1) || consider(b, pb, a, pa, -1) || !sawAxis || best > margin {
            return Manifold3D()
        }
        let point = support(b, pb, -normal)
        return Manifold3D(normal: normal, points: [ContactPoint3D(point: point, separation: best, id: 0)])
    }

    private struct Axis {
        var normal: Vec3
        var point: Vec3
    }

    private static func faceAxes(_ shape: Shape3D, _ pose: Pose3D) -> [Axis] {
        switch shape.geometry {
        case .convex(let hull):
            var axes: [Axis] = []
            let count = hull.triangleCount
            for t in 0..<count {
                let a = pose.apply(hull.vertices[Int(hull.indices[t * 3])])
                let b = pose.apply(hull.vertices[Int(hull.indices[t * 3 + 1])])
                let c = pose.apply(hull.vertices[Int(hull.indices[t * 3 + 2])])
                let n = (b - a).cross(c - a)
                if n.lengthSquared < 1e-10 { continue }
                axes.append(Axis(normal: n.normalized, point: a))
            }
            return axes
        case .box(let half):
            let r = Mat3(pose.rotation)
            return [
                Axis(normal: r.c0, point: pose.position + r.c0 * half.x),
                Axis(normal: -r.c0, point: pose.position - r.c0 * half.x),
                Axis(normal: r.c1, point: pose.position + r.c1 * half.y),
                Axis(normal: -r.c1, point: pose.position - r.c1 * half.y),
                Axis(normal: r.c2, point: pose.position + r.c2 * half.z),
                Axis(normal: -r.c2, point: pose.position - r.c2 * half.z),
            ]
        default:
            return []
        }
    }
}
