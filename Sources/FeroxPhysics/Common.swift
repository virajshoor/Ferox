import Foundation
import FeroxCore

/// Body simulation type.
public enum BodyType: String, Codable, Sendable, CaseIterable {
    /// Never moves; infinite mass.
    case `static`
    /// Simulated by forces, gravity and contacts.
    case dynamic
    /// Moved by setting velocity or target transforms; pushes dynamic bodies, ignores forces.
    case kinematic
}

/// Category/mask/group collision filtering (Box2D semantics).
///
/// Two shapes collide when `(a.category & b.mask) != 0 && (b.category & a.mask) != 0`.
/// A non-zero shared `group` overrides this: positive groups always collide, negative
/// groups never collide (useful for ragdoll limbs).
public struct CollisionFilter: Codable, Sendable, Hashable {
    public var category: UInt32
    public var mask: UInt32
    public var group: Int32

    public init(category: UInt32 = 1, mask: UInt32 = .max, group: Int32 = 0) {
        self.category = category
        self.mask = mask
        self.group = group
    }
    public static let `default` = CollisionFilter()

    @inlinable public func shouldCollide(with o: CollisionFilter) -> Bool {
        if group != 0 && group == o.group { return group > 0 }
        return (category & o.mask) != 0 && (o.category & mask) != 0
    }

    /// Builds a filter from layer indices.
    public static func layers(_ layer: Int, collidesWith mask: LayerMaskBits) -> CollisionFilter {
        CollisionFilter(category: 1 << UInt32(layer & 31), mask: mask.rawValue)
    }
}

/// Raw 32-bit mask (kept separate from FeroxScene.LayerMask to avoid a dependency cycle in tests).
public struct LayerMaskBits: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let all = LayerMaskBits(rawValue: .max)
}

/// Surface properties combined per contact (friction: geometric mean; restitution: max).
public struct PhysicsMaterial: Codable, Sendable, Hashable {
    public var friction: Float
    public var restitution: Float
    public var density: Float
    public init(friction: Float = 0.6, restitution: Float = 0, density: Float = 1) {
        self.friction = friction
        self.restitution = restitution
        self.density = density
    }
    public static let `default` = PhysicsMaterial()
    @inlinable public static func mixFriction(_ a: Float, _ b: Float) -> Float { (a * b).squareRoot() }
    @inlinable public static func mixRestitution(_ a: Float, _ b: Float) -> Float { Swift.max(a, b) }
}

/// Solver configuration shared by the 2D and 3D worlds.
public struct SolverSettings: Codable, Sendable, Hashable {
    public var velocityIterations = 8
    /// Fraction of penetration resolved per step (Baumgarte factor).
    public var baumgarte: Float = 0.2
    /// Allowed penetration before correction starts (world units).
    public var linearSlop: Float = 0.005
    /// Closing speed below which restitution is ignored (prevents jitter on resting contacts).
    public var restitutionThreshold: Float = 1
    /// Contacts are created this far before touching (speculative margin).
    public var speculativeDistance: Float = 0.02
    public var warmStarting = true
    public var allowSleep = true
    public var sleepLinearThreshold: Float = 0.05
    public var sleepAngularThreshold: Float = 0.05
    public var timeToSleep: Float = 0.5
    /// Hard cap on per-step translation to prevent tunnelling explosions.
    public var maxTranslation: Float = 4
    public var maxRotation: Float = 0.5 * .pi
    public init() {}
}

/// Identifies a body within a physics world.
public struct BodyID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let index: UInt32
    public let generation: UInt32
    public static let invalid = BodyID(index: .max, generation: 0)
    public var description: String { "Body(\(index)v\(generation))" }
}

/// Identifies a joint within a physics world.
public struct JointID: Hashable, Sendable, Codable {
    public let index: UInt32
    public let generation: UInt32
}

/// Begin/end of touching contact or trigger overlap between two bodies.
public struct ContactEvent<V: Sendable>: Sendable {
    public enum Phase: Sendable { case began, ended }
    public var phase: Phase
    public var bodyA: BodyID
    public var bodyB: BodyID
    public var shapeA: Int
    public var shapeB: Int
    public var userDataA: UInt64
    public var userDataB: UInt64
    public var isTrigger: Bool
    /// World-space contact points and normal (A → B) at the time of the event; empty for
    /// `ended` and trigger events.
    public var points: [V]
    public var normal: V
    /// Total normal impulse applied in the step (for impact sounds / damage).
    public var normalImpulse: Float
}

/// Line primitive emitted for debug visualisation.
public struct DebugLine<V: Sendable>: Sendable {
    public enum Kind: Sendable { case collider, sleeping, staticCollider, trigger, contact, contactNormal, joint, aabb }
    public var a: V
    public var b: V
    public var kind: Kind
}

/// Union-find used to build sleep islands.
struct UnionFind {
    var parent: [Int32]
    init(count: Int) { parent = (0..<Int32(count)).map { $0 } }
    mutating func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != Int32(r) { r = Int(parent[r]) }
        var c = x
        while parent[c] != Int32(r) {
            let n = Int(parent[c])
            parent[c] = Int32(r)
            c = n
        }
        return r
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = Int32(rb) }
    }
}

/// Sort-and-sweep broadphase over the x axis. Bodies are kept in a persistent array that
/// is re-sorted with insertion sort each step; temporal coherence makes this ~O(n).
struct SweepAndPrune {
    struct Proxy {
        var id: Int
        var minX: Float
        var maxX: Float
    }
    var proxies: [Proxy] = []

    /// Updates proxy bounds. Pass `rebuild` when bodies were added or removed.
    mutating func update(_ items: [(id: Int, minX: Float, maxX: Float)], rebuild: Bool) {
        if rebuild || items.count != proxies.count {
            proxies = items.map { Proxy(id: $0.id, minX: $0.minX, maxX: $0.maxX) }
            proxies.sort { $0.minX < $1.minX }
            return
        }
        var lookup: [Int: (Float, Float)] = [:]
        lookup.reserveCapacity(items.count)
        for it in items { lookup[it.id] = (it.minX, it.maxX) }
        for i in proxies.indices {
            if let b = lookup[proxies[i].id] {
                proxies[i].minX = b.0
                proxies[i].maxX = b.1
            }
        }
        // Insertion sort (nearly sorted input).
        if proxies.count > 1 {
            for i in 1..<proxies.count {
                let p = proxies[i]
                var j = i - 1
                while j >= 0 && proxies[j].minX > p.minX {
                    proxies[j + 1] = proxies[j]
                    j -= 1
                }
                proxies[j + 1] = p
            }
        }
    }

    /// Calls `body(a, b)` for every pair whose x-intervals overlap.
    func forEachOverlap(_ body: (Int, Int) -> Void) {
        let n = proxies.count
        var i = 0
        while i < n {
            let a = proxies[i]
            var j = i + 1
            while j < n && proxies[j].minX <= a.maxX {
                body(a.id, proxies[j].id)
                j += 1
            }
            i += 1
        }
    }
}

func pairKey(_ a: Int, _ b: Int) -> UInt64 {
    let lo = UInt64(Swift.min(a, b)), hi = UInt64(Swift.max(a, b))
    return (lo << 32) | hi
}
