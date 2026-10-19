import FeroxAssets
import FeroxCore
import FeroxMath
import FeroxScene

/// Nearest hit of a ray against a mesh's triangles. `t` is distance along the ray, whose
/// direction is treated as a unit vector (the same convention as `Ray`).
public struct MeshHit: Equatable, Sendable {
    public var t: Float
    public var normal: Vec3
    public init(t: Float, normal: Vec3) {
        self.t = t
        self.normal = normal
    }
}

public enum MeshRaycast {
    public static func nearest(mesh: MeshData, model: Mat4, ray: Ray) -> MeshHit? {
        let indexCount = mesh.indices.count - mesh.indices.count % 3
        guard indexCount >= 3 else { return nil }
        var best: MeshHit?
        var i = 0
        while i < indexCount {
            let ia = Int(mesh.indices[i])
            let ib = Int(mesh.indices[i + 1])
            let ic = Int(mesh.indices[i + 2])
            i += 3
            guard ia < mesh.positions.count, ib < mesh.positions.count, ic < mesh.positions.count else { continue }
            let a = model.transformPoint(mesh.positions[ia])
            let b = model.transformPoint(mesh.positions[ib])
            let c = model.transformPoint(mesh.positions[ic])
            guard let hit = triangle(ray, a, b, c) else { continue }
            if hit.t < best?.t ?? .infinity { best = hit }
        }
        return best
    }

    /// Möller–Trumbore. Returns nil for a back-facing or parallel triangle and for hits behind the origin.
    static func triangle(_ ray: Ray, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> MeshHit? {
        let ab = b - a
        let ac = c - a
        let p = ray.direction.cross(ac)
        let det = ab.dot(p)
        // Front faces only. A negative determinant is the back of the triangle.
        if det < 1e-8 { return nil }
        let inv = 1 / det
        let tvec = ray.origin - a
        let u = tvec.dot(p) * inv
        if u < 0 || u > 1 { return nil }
        let q = tvec.cross(ab)
        let v = ray.direction.dot(q) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = ac.dot(q) * inv
        if t < 0 { return nil }
        let n = ab.cross(ac)
        let normal = n.lengthSquared > 0 ? n.normalized : Vec3.up
        return MeshHit(t: t, normal: normal)
    }
}

/// Instance index → entity, parallel to `RenderFrameData.instances`. A GPU pick attachment
/// stores this index in `r32Uint`; `0xFFFFFFFF` is a miss.
public struct InstancePickMap: Equatable, Sendable {
    public static let miss: UInt32 = 0xFFFF_FFFF
    public var entities: [Entity]
    public init(entities: [Entity]) { self.entities = entities }

    public func entity(forInstance id: UInt32) -> Entity? {
        guard id != Self.miss else { return nil }
        let index = Int(id)
        guard index >= 0, index < entities.count else { return nil }
        return entities[index]
    }
}

/// Bytes of the shared staging buffer a pick blit writes. Texture-to-buffer copies
/// want a 256-byte row, and the instance id is the first word.
public enum InstancePickStaging {
    public static let byteCount = 256
    public static let wordOffset = 0

    public static func pixel(x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        (min(max(x, 0), max(width - 1, 0)), min(max(y, 0), max(height - 1, 0)))
    }

    /// Maps a point in the view into a pixel of the render target.
    public static func renderPixel(
        viewX: Int, viewY: Int, viewWidth: Int, viewHeight: Int, renderWidth: Int, renderHeight: Int
    ) -> (x: Int, y: Int) {
        let sx = viewWidth > 0 ? viewX * renderWidth / viewWidth : viewX
        let sy = viewHeight > 0 ? viewY * renderHeight / viewHeight : viewY
        return pixel(x: sx, y: sy, width: renderWidth, height: renderHeight)
    }
}

/// One in-flight instance-id read. The GPU writes a sample later; until `complete`
/// returns for that serial, the caller keeps the CPU raycast.
public struct InstancePickReadback: Equatable, Sendable {
    public struct Request: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var serial: UInt64
        public init(x: Int, y: Int, serial: UInt64) {
            self.x = x
            self.y = y
            self.serial = serial
        }
    }

    public struct Sample: Equatable, Sendable {
        public var serial: UInt64
        public var instance: UInt32
        public init(serial: UInt64, instance: UInt32) {
            self.serial = serial
            self.instance = instance
        }
    }

    public private(set) var pending: Request?
    public private(set) var sample: Sample?
    private var nextSerial: UInt64 = 1

    public init() {}

    public mutating func request(x: Int, y: Int) -> Request {
        let made = Request(x: max(x, 0), y: max(y, 0), serial: nextSerial)
        nextSerial += 1
        pending = made
        return made
    }

    /// Records the word the staging buffer held for `serial`. A stale serial is ignored.
    public mutating func complete(serial: UInt64, word: UInt32) {
        guard pending?.serial == serial else { return }
        sample = Sample(serial: serial, instance: word)
        pending = nil
    }

    public func entity(serial: UInt64, map: InstancePickMap) -> Entity? {
        guard let sample, sample.serial == serial else { return nil }
        return map.entity(forInstance: sample.instance)
    }
}

/// What the GPU wrote for one pick, plus the instance list from that frame.
public struct InstancePickSample: Equatable, Sendable {
    public var serial: UInt64
    public var instance: UInt32
    public var entities: [Entity]
    public init(serial: UInt64, instance: UInt32, entities: [Entity]) {
        self.serial = serial
        self.instance = instance
        self.entities = entities
    }
}
