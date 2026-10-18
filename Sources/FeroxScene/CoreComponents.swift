import Foundation
import FeroxCore

/// Human-readable entity name (shown in the editor hierarchy).
public struct Name: Component, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var value: String
    public init(_ value: String) { self.value = value }
    public init(stringLiteral value: String) { self.value = value }
}

/// Local transform relative to the parent (or the world, for root entities).
///
/// Property observers set `isDirty` whenever a field changes (including through `inout`
/// access in queries), letting `TransformSystem` skip unchanged subtrees.
public struct Transform: Component, Codable, Hashable, Sendable {
    public var position: Vec3 { didSet { isDirty = true } }
    public var rotation: Quat { didSet { isDirty = true } }
    public var scale: Vec3 { didSet { isDirty = true } }
    /// Set when any field changes; cleared by `TransformSystem`.
    public internal(set) var isDirty: Bool = true

    public init(position: Vec3 = .zero, rotation: Quat = .identity, scale: Vec3 = Vec3(1, 1, 1)) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }
    public init(_ trs: TRS) { self.init(position: trs.position, rotation: trs.rotation, scale: trs.scale) }

    public var trs: TRS {
        get { TRS(position: position, rotation: rotation, scale: scale) }
        set {
            position = newValue.position
            rotation = newValue.rotation
            scale = newValue.scale
        }
    }
    public var localMatrix: Mat4 { Mat4(translation: position, rotation: rotation, scale: scale) }
    public var forward: Vec3 { rotation.act(.forward) }
    public var right: Vec3 { rotation.act(.right) }
    public var up: Vec3 { rotation.act(.up) }

    /// 2D convenience: position in the XY plane.
    public var position2D: Vec2 {
        get { Vec2(position.x, position.y) }
        set { position = Vec3(newValue.x, newValue.y, position.z) }
    }
    /// 2D convenience: rotation around +Z in radians.
    public var rotation2D: Float {
        get { 2 * atan2(rotation.z, rotation.w) }
        set { rotation = Quat(angle: newValue, axis: Vec3(0, 0, 1)) }
    }

    public mutating func translate(_ d: Vec3) { position += d }
    public mutating func rotate(_ q: Quat) { rotation = (q * rotation).normalized }
    public mutating func lookAt(_ target: Vec3, up: Vec3 = .up) {
        rotation = Quat.lookRotation(forward: target - position, up: up)
    }

    enum CodingKeys: String, CodingKey { case position, rotation, scale }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent(Vec3.self, forKey: .position) ?? .zero
        rotation = try c.decodeIfPresent(Quat.self, forKey: .rotation) ?? .identity
        scale = try c.decodeIfPresent(Vec3.self, forKey: .scale) ?? Vec3(1, 1, 1)
        isDirty = true
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(position, forKey: .position)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(scale, forKey: .scale)
    }

    public static func == (a: Transform, b: Transform) -> Bool {
        a.position == b.position && a.rotation == b.rotation && a.scale == b.scale
    }
    public func hash(into h: inout Hasher) {
        h.combine(position)
        h.combine(rotation)
        h.combine(scale)
    }
}

/// World-space matrix computed by `TransformSystem`. `previous` holds last frame's value
/// for motion vectors (TAA, motion blur, temporal upscaling).
public struct WorldTransform: Component, Sendable, Hashable {
    public var matrix: Mat4 = .identity
    public var previous: Mat4 = .identity
    /// True on the first frame after creation/teleport so motion vectors are zero.
    public var resetHistory = true
    public init() {}
    public init(matrix: Mat4) {
        self.matrix = matrix
        previous = matrix
    }
    public var position: Vec3 { matrix.translation }
    public var forward: Vec3 { matrix.transformDirection(.forward).normalized }
}

/// Parent link. Managed through `World.setParent`; do not add manually.
public struct Parent: Component, Sendable, Hashable {
    public var entity: Entity
}

/// Ordered child list. Managed through `World.setParent`; do not add manually.
public struct Children: Component, Sendable, Hashable {
    public var entities: [Entity] = []
}

/// Entities with this component are skipped by gameplay, physics and rendering systems
/// (Unity's `SetActive(false)`). Applies to the whole subtree for rendering.
public struct Disabled: Component, Codable, Hashable, Sendable { public init() {} }

/// Free-form string tags, e.g. "Player", "Enemy".
public struct Tags: Component, Codable, Hashable, Sendable {
    public var values: Set<String>
    public init(_ values: Set<String> = []) { self.values = values }
    public func contains(_ t: String) -> Bool { values.contains(t) }
}

/// 32 bit layer mask used for rendering visibility, physics filtering and raycasts.
public struct LayerMask: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func layer(_ i: Int) -> LayerMask { LayerMask(rawValue: 1 << UInt32(i & 31)) }
    public static let `default` = LayerMask(rawValue: 1)
    public static let ui = LayerMask.layer(5)
    public static let editorOnly = LayerMask.layer(31)
    public static let all = LayerMask(rawValue: .max)
}

/// The layer an entity belongs to (exactly one layer bit).
public struct Layer: Component, Codable, Hashable, Sendable {
    public var index: Int
    public init(_ index: Int = 0) { self.index = min(max(index, 0), 31) }
    public var mask: LayerMask { .layer(index) }
}

/// Group memberships, e.g. for wave spawners or "all collectibles" queries.
public struct Groups: Component, Codable, Hashable, Sendable {
    public var names: Set<String>
    public init(_ names: Set<String> = []) { self.names = names }
}

/// Stable identifier for an entity across saves (assigned on first save).
public struct PersistentID: Component, Codable, Hashable, Sendable {
    public var value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

/// Marks an entity as belonging to a loaded scene (see `SceneManager`).
public struct SceneMember: Component, Hashable, Sendable {
    public var scene: SceneHandle
}

/// Entities with this component survive scene unloads (Unity's `DontDestroyOnLoad`).
public struct PersistAcrossScenes: Component, Codable, Hashable, Sendable { public init() {} }
