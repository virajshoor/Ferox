import FeroxCore
import Foundation

/// CPU tessellation of 2D shapes into indexed triangles. Portable and unit-tested.
public enum Tessellator {
    /// Signed area (positive for counter-clockwise winding).
    public static func signedArea(_ p: [Vec2]) -> Float {
        guard p.count >= 3 else { return 0 }
        var a: Float = 0
        for i in 0..<p.count {
            let j = (i + 1) % p.count
            a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return a * 0.5
    }

    /// Triangulates a simple polygon (no self-intersections, either winding) by ear
    /// clipping. Returns indices into `points`. Degenerate input yields no triangles;
    /// if clipping stalls (e.g. a self-intersecting outline) the remainder is fanned.
    public static func triangulate(_ points: [Vec2]) -> [UInt32] {
        let n = points.count
        guard n >= 3 else { return [] }
        let area = signedArea(points)
        guard abs(area) > 1e-12 else { return [] }
        let ccw = area > 0
        var remaining = Array(0..<n)
        var out: [UInt32] = []
        out.reserveCapacity((n - 2) * 3)

        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func inside(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
            let d1 = cross(a, b, p)
            let d2 = cross(b, c, p)
            let d3 = cross(c, a, p)
            let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
            let hasPos = d1 > 0 || d2 > 0 || d3 > 0
            return !(hasNeg && hasPos)
        }

        var guardCounter = 0
        var i = 0
        while remaining.count > 3 && guardCounter < remaining.count * 2 {
            let m = remaining.count
            let ia = remaining[(i + m - 1) % m]
            let ib = remaining[i % m]
            let ic = remaining[(i + 1) % m]
            let a = points[ia]
            let b = points[ib]
            let c = points[ic]
            let turn = cross(a, b, c)
            var isEar = ccw ? turn > 1e-12 : turn < -1e-12
            if isEar {
                for k in remaining where k != ia && k != ib && k != ic {
                    if inside(points[k], a, b, c) {
                        isEar = false
                        break
                    }
                }
            }
            if isEar {
                out += [UInt32(ia), UInt32(ib), UInt32(ic)]
                remaining.remove(at: i % m)
                guardCounter = 0
                if i >= remaining.count { i = 0 }
            } else {
                i = (i + 1) % m
                guardCounter += 1
            }
        }
        if remaining.count == 3 {
            out += remaining.map { UInt32($0) }
        } else if remaining.count > 3 {
            for k in 1..<(remaining.count - 1) {
                out += [UInt32(remaining[0]), UInt32(remaining[k]), UInt32(remaining[k + 1])]
            }
        }
        return out
    }

    /// Outline of a circle (counter-clockwise).
    public static func circle(radius: Float, segments: Int) -> [Vec2] {
        let s = min(max(segments, 3), 256)
        return (0..<s).map { i in
            let a = Float(i) / Float(s) * 2 * .pi
            return Vec2(cos(a), sin(a)) * radius
        }
    }

    /// Outline of a rectangle centred on the origin with rounded corners (counter-clockwise).
    public static func roundedRect(size: Vec2, cornerRadius: Float, segmentsPerCorner: Int = 6) -> [Vec2] {
        let h = size * 0.5
        let r = min(max(cornerRadius, 0), min(h.x, h.y))
        if r <= 1e-6 {
            return [Vec2(-h.x, -h.y), Vec2(h.x, -h.y), Vec2(h.x, h.y), Vec2(-h.x, h.y)]
        }
        let seg = max(segmentsPerCorner, 1)
        let centres = [
            Vec2(h.x - r, -h.y + r), Vec2(h.x - r, h.y - r), Vec2(-h.x + r, h.y - r), Vec2(-h.x + r, -h.y + r),
        ]
        let starts: [Float] = [-.pi / 2, 0, .pi / 2, .pi]
        var out: [Vec2] = []
        out.reserveCapacity(4 * (seg + 1))
        for c in 0..<4 {
            for k in 0...seg {
                let a = starts[c] + Float(k) / Float(seg) * (.pi / 2)
                out.append(centres[c] + Vec2(cos(a), sin(a)) * r)
            }
        }
        return out
    }

    /// Thick line strip as quads (one per segment, with mitred joins clamped to avoid
    /// spikes). Returns the vertex positions and indices.
    public static func stroke(_ points: [Vec2], width: Float, closed: Bool) -> (positions: [Vec2], indices: [UInt32]) {
        // Drop consecutive duplicates; they have no direction.
        var pts: [Vec2] = []
        pts.reserveCapacity(points.count)
        for p in points where pts.last.map({ (p - $0).lengthSquared > 1e-12 }) ?? true { pts.append(p) }
        if closed, pts.count > 2, let f = pts.first, let l = pts.last, (f - l).lengthSquared <= 1e-12 {
            pts.removeLast()
        }
        let n = pts.count
        guard n >= 2, width > 0 else { return ([], []) }
        let hw = width * 0.5

        func normal(_ a: Vec2, _ b: Vec2) -> Vec2 {
            let d = (b - a).normalized
            return Vec2(-d.y, d.x)
        }
        var positions: [Vec2] = []
        positions.reserveCapacity(n * 2)
        for i in 0..<n {
            let hasPrev = closed || i > 0
            let hasNext = closed || i < n - 1
            let prev = pts[(i + n - 1) % n]
            let cur = pts[i]
            let next = pts[(i + 1) % n]
            var offset: Vec2
            if hasPrev && hasNext {
                let n0 = normal(prev, cur)
                let n1 = normal(cur, next)
                let sum = n0 + n1
                if sum.lengthSquared < 1e-8 {
                    offset = n0 * hw  // 180° turn: no meaningful miter
                } else {
                    let miter = sum.normalized
                    let denom = max(miter.dot(n1), 0.25)  // clamp miter length to 4× half width
                    offset = miter * (hw / denom)
                }
            } else if hasNext {
                offset = normal(cur, next) * hw
            } else {
                offset = normal(prev, cur) * hw
            }
            positions.append(cur + offset)
            positions.append(cur - offset)
        }
        var indices: [UInt32] = []
        let segments = closed ? n : n - 1
        indices.reserveCapacity(segments * 6)
        for i in 0..<segments {
            let a = UInt32(i * 2)
            let b = UInt32(((i + 1) % n) * 2)
            indices += [a, a + 1, b + 1, a, b + 1, b]
        }
        return (positions, indices)
    }
}
