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
        let assigned = Set(seed.corners)
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

/// SAT contact for convex shapes. Sphere and capsule queries use the hull surface directly.
/// Hull and box pairs test face normals and edge-edge axes, then build a clipped manifold
/// (one point when the winning axis is an edge cross).
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

    /// World-space polygon. `normal` points outwards.
    private struct FacePoly {
        var normal: Vec3
        var points: [Vec3]
    }

    /// Face normals, then edge-edge crosses. The greatest separation (least penetration) wins.
    /// Face axes are preferred by a small bias so a flat resting contact does not flicker onto
    /// an edge. ponytail: O(edges²) crosses; switch to EPA if hulls grow past a few dozen edges.
    private static func sat(_ a: Shape3D, _ pa: Pose3D, _ b: Shape3D, _ pb: Pose3D, _ margin: Float) -> Manifold3D {
        let facesA = faces(a, pa)
        let facesB = faces(b, pb)
        guard !facesA.isEmpty || !facesB.isEmpty else { return Manifold3D() }
        var best = -Float.greatestFiniteMagnitude
        var normal = Vec3.up
        var kind = 0
        var faceIndex = 0
        var edgePair: ((Vec3, Vec3), (Vec3, Vec3))?
        func considerFace(_ face: FacePoly, ownerIsA: Bool, index: Int) -> Bool {
            let n = face.normal
            let other: Shape3D = ownerIsA ? b : a
            let otherPose: Pose3D = ownerIsA ? pb : pa
            let supportPoint = support(other, otherPose, -n)
            let separation = n.dot(supportPoint - face.points[0])
            if separation > margin { return true }
            if separation > best {
                best = separation
                normal = ownerIsA ? n : -n
                kind = ownerIsA ? 0 : 1
                faceIndex = index
                edgePair = nil
            }
            return false
        }
        for (i, face) in facesA.enumerated() where considerFace(face, ownerIsA: true, index: i) {
            return Manifold3D()
        }
        for (i, face) in facesB.enumerated() where considerFace(face, ownerIsA: false, index: i) {
            return Manifold3D()
        }
        let edgesA = edges(a, pa)
        let edgesB = edges(b, pb)
        let towardB = pb.position - pa.position
        for ea in edgesA {
            let da = ea.1 - ea.0
            for eb in edgesB {
                var axis = da.cross(eb.1 - eb.0)
                let lengthSquared = axis.lengthSquared
                if lengthSquared < 1e-10 { continue }
                axis = axis / lengthSquared.squareRoot()
                if axis.dot(towardB) < 0 { axis = -axis }
                let separation = axis.dot(support(b, pb, -axis) - support(a, pa, axis))
                if separation > margin { return Manifold3D() }
                // Edges must beat the best face by more than the bias.
                if separation - 0.001 > best {
                    best = separation - 0.001
                    normal = axis
                    kind = 2
                    edgePair = (ea, eb)
                }
            }
        }
        if kind == 2, let (ea, eb) = edgePair {
            let (ca, cb) = Collide3D.closestSegmentSegment(ea.0, ea.1, eb.0, eb.1)
            let separation = (cb - ca).dot(normal)
            guard separation <= margin else { return Manifold3D() }
            return Manifold3D(
                normal: normal,
                points: [ContactPoint3D(point: (ca + cb) * 0.5, separation: separation, id: 0xE000)])
        }
        return clipFaces(
            refIsA: kind == 0, facesA: facesA, facesB: facesB, faceIndex: faceIndex,
            normal: normal, margin: margin, fallback: best)
    }

    /// One triangle of a mesh against a hull. The triangle is a two-sided face plus three edges.
    static func triangle(
        _ a: Vec3, _ b: Vec3, _ c: Vec3, _ hull: ConvexHull3D, _ pose: Pose3D, _ margin: Float
    ) -> Manifold3D {
        let raw = (b - a).cross(c - a)
        guard raw.lengthSquared > 1e-12 else { return Manifold3D() }
        let n = raw.normalized
        let tri = Shape3D(.convex(hull))
        let facesA = [FacePoly(normal: n, points: [a, b, c]), FacePoly(normal: -n, points: [a, c, b])]
        let facesB = faces(tri, pose)
        var best = -Float.greatestFiniteMagnitude
        var normal = n
        var kind = 0
        var faceIndex = 0
        var edgePair: ((Vec3, Vec3), (Vec3, Vec3))?
        func triSupport(_ dir: Vec3) -> Vec3 {
            let da = dir.dot(a)
            let db = dir.dot(b)
            let dc = dir.dot(c)
            if da >= db && da >= dc { return a }
            return db >= dc ? b : c
        }
        for (i, face) in facesA.enumerated() {
            let supportPoint = support(tri, pose, -face.normal)
            let separation = face.normal.dot(supportPoint - a)
            if separation > margin { return Manifold3D() }
            if separation > best {
                best = separation
                normal = face.normal
                kind = 0
                faceIndex = i
                edgePair = nil
            }
        }
        for (i, face) in facesB.enumerated() {
            let separation = face.normal.dot(triSupport(-face.normal) - face.points[0])
            if separation > margin { return Manifold3D() }
            if separation > best {
                best = separation
                normal = -face.normal
                kind = 1
                faceIndex = i
                edgePair = nil
            }
        }
        let triEdges = [(a, b), (b, c), (c, a)]
        let hullEdges = edges(tri, pose)
        let center = (a + b + c) / 3
        for ea in triEdges {
            let da = ea.1 - ea.0
            for eb in hullEdges {
                var axis = da.cross(eb.1 - eb.0)
                let lengthSquared = axis.lengthSquared
                if lengthSquared < 1e-10 { continue }
                axis = axis / lengthSquared.squareRoot()
                if axis.dot(pose.position - center) < 0 { axis = -axis }
                let separation = axis.dot(support(tri, pose, -axis) - triSupport(axis))
                if separation > margin { return Manifold3D() }
                if separation - 0.001 > best {
                    best = separation - 0.001
                    normal = axis
                    kind = 2
                    edgePair = (ea, eb)
                }
            }
        }
        if kind == 2, let (ea, eb) = edgePair {
            let (ca, cb) = Collide3D.closestSegmentSegment(ea.0, ea.1, eb.0, eb.1)
            let separation = (cb - ca).dot(normal)
            guard separation <= margin else { return Manifold3D() }
            return Manifold3D(
                normal: normal,
                points: [ContactPoint3D(point: (ca + cb) * 0.5, separation: separation, id: 0xE100)])
        }
        return clipFaces(
            refIsA: kind == 0, facesA: facesA, facesB: facesB, faceIndex: faceIndex,
            normal: normal, margin: margin, fallback: best)
    }

    private static func clipFaces(
        refIsA: Bool, facesA: [FacePoly], facesB: [FacePoly], faceIndex: Int, normal: Vec3, margin: Float,
        fallback: Float
    ) -> Manifold3D {
        let refFaces = refIsA ? facesA : facesB
        let incFaces = refIsA ? facesB : facesA
        guard faceIndex < refFaces.count,
            let incident = incFaces.min(by: {
                $0.normal.dot(refIsA ? normal : -normal) < $1.normal.dot(refIsA ? normal : -normal)
            })
        else {
            return Manifold3D(normal: normal, points: [ContactPoint3D(point: .zero, separation: fallback, id: 0)])
        }
        let ref = refFaces[faceIndex]
        let refN = refIsA ? normal : -normal
        var poly = incident.points
        let count = ref.points.count
        guard count >= 3 else { return Manifold3D() }
        let centroid = ref.points.reduce(Vec3.zero, +) / Float(count)
        for i in 0..<count {
            let p0 = ref.points[i]
            let p1 = ref.points[(i + 1) % count]
            var side = (p1 - p0).cross(ref.normal)
            let length = side.length
            if length < 1e-8 { continue }
            side = side / length
            if side.dot(centroid - p0) > 0 { side = -side }
            poly = Collide3D.clipPolygon(poly, side, side.dot(p0))
            if poly.isEmpty { return Manifold3D() }
        }
        var manifold = Manifold3D(normal: normal)
        let plane = refN.dot(ref.points[0])
        for (k, p) in poly.enumerated() {
            let separation = refN.dot(p) - plane
            guard separation <= margin else { continue }
            manifold.points.append(
                ContactPoint3D(point: p - refN * (separation * 0.5), separation: separation, id: UInt32(k)))
        }
        if manifold.points.count > 4 { manifold.points = Collide3D.reduceTo4(manifold.points, normal: normal) }
        if manifold.points.isEmpty {
            manifold.points = [ContactPoint3D(point: ref.points[0], separation: fallback, id: 0)]
        }
        return manifold
    }

    private static func faces(_ shape: Shape3D, _ pose: Pose3D) -> [FacePoly] {
        switch shape.geometry {
        case .convex(let hull):
            var polys: [FacePoly] = []
            let count = hull.triangleCount
            for t in 0..<count {
                let a = pose.apply(hull.vertices[Int(hull.indices[t * 3])])
                let b = pose.apply(hull.vertices[Int(hull.indices[t * 3 + 1])])
                let c = pose.apply(hull.vertices[Int(hull.indices[t * 3 + 2])])
                let n = (b - a).cross(c - a)
                if n.lengthSquared < 1e-10 { continue }
                polys.append(FacePoly(normal: n.normalized, points: [a, b, c]))
            }
            return polys
        case .box(let half):
            let r = Mat3(pose.rotation)
            let axes = [r.c0, r.c1, r.c2]
            let extents = [half.x, half.y, half.z]
            var polys: [FacePoly] = []
            for i in 0..<3 {
                for sign in [Float(1), Float(-1)] {
                    let n = axes[i] * sign
                    let center = pose.position + n * extents[i]
                    let u = axes[(i + 1) % 3]
                    let v = axes[(i + 2) % 3]
                    let hu = extents[(i + 1) % 3]
                    let hv = extents[(i + 2) % 3]
                    polys.append(
                        FacePoly(
                            normal: n,
                            points: [
                                center + u * hu + v * hv,
                                center - u * hu + v * hv,
                                center - u * hu - v * hv,
                                center + u * hu - v * hv,
                            ]))
                }
            }
            return polys
        default:
            return []
        }
    }

    private static func edges(_ shape: Shape3D, _ pose: Pose3D) -> [(Vec3, Vec3)] {
        switch shape.geometry {
        case .convex(let hull):
            var seen = Set<UInt64>()
            var result: [(Vec3, Vec3)] = []
            let count = hull.triangleCount
            for t in 0..<count {
                let i0 = Int(hull.indices[t * 3])
                let i1 = Int(hull.indices[t * 3 + 1])
                let i2 = Int(hull.indices[t * 3 + 2])
                for (u, v) in [(i0, i1), (i1, i2), (i2, i0)] {
                    let lo = min(u, v)
                    let hi = max(u, v)
                    let key = (UInt64(lo) << 32) | UInt64(hi)
                    guard seen.insert(key).inserted else { continue }
                    result.append((pose.apply(hull.vertices[lo]), pose.apply(hull.vertices[hi])))
                }
            }
            return result
        case .box(let half):
            let r = Mat3(pose.rotation)
            let axes = [r.c0, r.c1, r.c2]
            let extents = [half.x, half.y, half.z]
            var result: [(Vec3, Vec3)] = []
            for axis in 0..<3 {
                let dir = axes[axis] * extents[axis]
                let u = (axis + 1) % 3
                let v = (axis + 2) % 3
                for su in [Float(-1), Float(1)] {
                    for sv in [Float(-1), Float(1)] {
                        let center = pose.position + axes[u] * (extents[u] * su) + axes[v] * (extents[v] * sv)
                        result.append((center - dir, center + dir))
                    }
                }
            }
            return result
        default:
            return []
        }
    }
}
