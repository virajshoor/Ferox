import FeroxCore
import Foundation

/// Immediate-mode debug lines (gizmos, bounds, physics shapes). Lines are collected during
/// the frame and drawn on top of the scene by the debug pass, then cleared. Capacity is
/// bounded so a runaway loop cannot exhaust memory. Main-thread only.
public final class DebugDraw {
    public private(set) var vertices: [LineVertex] = []
    /// Maximum line segments kept per frame; further lines are dropped and counted.
    public var maxLines: Int
    public private(set) var droppedLines = 0
    /// Draw through geometry (no depth test) instead of being occluded by it.
    public var alwaysOnTop = true

    public init(maxLines: Int = 200_000) { self.maxLines = max(maxLines, 0) }

    public var lineCount: Int { vertices.count / 2 }

    public func clear() {
        vertices.removeAll(keepingCapacity: true)
        droppedLines = 0
    }

    public func line(_ a: Vec3, _ b: Vec3, _ color: Color = .white) {
        guard lineCount < maxLines else {
            droppedLines += 1
            return
        }
        vertices.append(LineVertex(a, color))
        vertices.append(LineVertex(b, color))
    }

    public func line2D(_ a: Vec2, _ b: Vec2, _ color: Color = .white, z: Float = 0) {
        line(Vec3(a.x, a.y, z), Vec3(b.x, b.y, z), color)
    }

    public func polyline(_ points: [Vec3], closed: Bool = false, _ color: Color = .white) {
        guard points.count >= 2 else { return }
        for i in 1..<points.count { line(points[i - 1], points[i], color) }
        if closed, points.count > 2 { line(points[points.count - 1], points[0], color) }
    }

    /// Box edges of `box` transformed by `m`.
    public func box(_ box: AABB, transform m: Mat4 = .identity, _ color: Color = .green) {
        guard !box.isEmpty else { return }
        let lo = box.min
        let hi = box.max
        var c: [Vec3] = []
        c.reserveCapacity(8)
        for i in 0..<8 {
            c.append(
                m.transformPoint(Vec3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)))
        }
        for (a, b) in [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)] {
            line(c[a], c[b], color)
        }
    }

    public func circle(center: Vec3, normal: Vec3, radius: Float, segments: Int = 32, _ color: Color = .white) {
        let n = normal.lengthSquared > 1e-8 ? normal.normalized : Vec3.up
        let helper = abs(n.y) < 0.99 ? Vec3.up : Vec3(1, 0, 0)
        let u = n.cross(helper).normalized
        let v = n.cross(u)
        let s = min(max(segments, 3), 256)
        var prev = center + u * radius
        for i in 1...s {
            let a = Float(i) / Float(s) * 2 * .pi
            let p = center + (u * cos(a) + v * sin(a)) * radius
            line(prev, p, color)
            prev = p
        }
    }

    public func sphere(_ s: Sphere, _ color: Color = .yellow) {
        circle(center: s.center, normal: Vec3(1, 0, 0), radius: s.radius, segments: 24, color)
        circle(center: s.center, normal: Vec3(0, 1, 0), radius: s.radius, segments: 24, color)
        circle(center: s.center, normal: Vec3(0, 0, 1), radius: s.radius, segments: 24, color)
    }

    public func cross(_ p: Vec3, size: Float = 0.25, _ color: Color = .white) {
        line(p - Vec3(size, 0, 0), p + Vec3(size, 0, 0), color)
        line(p - Vec3(0, size, 0), p + Vec3(0, size, 0), color)
        line(p - Vec3(0, 0, size), p + Vec3(0, 0, size), color)
    }

    public func arrow(from a: Vec3, to b: Vec3, headSize: Float = 0.15, _ color: Color = .white) {
        line(a, b, color)
        let d = b - a
        guard d.lengthSquared > 1e-10 else { return }
        let dir = d.normalized
        let side = abs(dir.y) < 0.99 ? dir.cross(.up).normalized : Vec3(1, 0, 0)
        let up = side.cross(dir)
        line(b, b - dir * headSize + side * headSize * 0.5, color)
        line(b, b - dir * headSize - side * headSize * 0.5, color)
        line(b, b - dir * headSize + up * headSize * 0.5, color)
        line(b, b - dir * headSize - up * headSize * 0.5, color)
    }

    /// RGB axes of a transform (X red, Y green, Z blue).
    public func axes(_ m: Mat4, length: Float = 1) {
        let o = m.translation
        line(o, o + m.transformDirection(Vec3(1, 0, 0)).normalized * length, Color(1, 0.2, 0.2))
        line(o, o + m.transformDirection(Vec3(0, 1, 0)).normalized * length, Color(0.2, 1, 0.2))
        line(o, o + m.transformDirection(Vec3(0, 0, 1)).normalized * length, Color(0.3, 0.5, 1))
    }

    /// Grid on the XZ plane centred on the origin.
    public func grid(size: Float = 10, step: Float = 1, _ color: Color = Color(0.4, 0.4, 0.45, 0.6)) {
        let st = max(step, 1e-3)
        let n = min(Int(size / st), 1000)
        for i in -n...n {
            let t = Float(i) * st
            line(Vec3(t, 0, -size), Vec3(t, 0, size), color)
            line(Vec3(-size, 0, t), Vec3(size, 0, t), color)
        }
    }

    /// Edges of the frustum described by an inverse view-projection (reverse-Z).
    public func frustum(inverseViewProjection inv: Mat4, _ color: Color = .white) {
        var c: [Vec3] = []
        for z in [Float(1), 0] {
            for (x, y) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                c.append(inv.transformPoint(Vec3(x, y, z)))
            }
        }
        for i in 0..<4 {
            line(c[i], c[(i + 1) % 4], color)
            line(c[4 + i], c[4 + (i + 1) % 4], color)
            line(c[i], c[4 + i], color)
        }
    }
}
