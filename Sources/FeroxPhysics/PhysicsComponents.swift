import Foundation
import FeroxCore
import FeroxScene

// MARK: - 2D

/// Makes an entity a simulated 2D rigid body (XY plane). Requires a `Collider2D` to collide.
public struct RigidBody2D: SerializableComponent, Hashable, Sendable {
    public var type: BodyType = .dynamic
    public var linearDamping: Float = 0
    public var angularDamping: Float = 0.05
    public var gravityScale: Float = 1
    public var fixedRotation = false
    public var allowSleep = true
    /// Interpolate the rendered transform between fixed steps (recommended for moving bodies).
    public var interpolate = true
    /// Velocity applied when the body is created.
    public var initialVelocity: Vec2 = .zero
    public init(type: BodyType = .dynamic) { self.type = type }
}

/// Collision shapes for a 2D entity. Without a `RigidBody2D` the entity becomes a static collider.
public struct Collider2D: SerializableComponent, Hashable, Sendable {
    public var shapes: [Shape2D]
    public init(_ shapes: [Shape2D]) { self.shapes = shapes }
    public init(_ shape: Shape2D) { shapes = [shape] }
    public static func box(_ size: Vec2, material: PhysicsMaterial = .default, isTrigger: Bool = false) -> Collider2D {
        var s = Shape2D.box(halfExtents: size * 0.5)
        s.material = material
        s.isTrigger = isTrigger
        return Collider2D(s)
    }
    public static func circle(_ radius: Float, material: PhysicsMaterial = .default, isTrigger: Bool = false) -> Collider2D {
        var s = Shape2D.circle(radius: radius)
        s.material = material
        s.isTrigger = isTrigger
        return Collider2D(s)
    }
}

/// Joint between this entity's body and `connected`.
public struct Joint2D: SerializableComponent, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case revolute(motorSpeed: Float?, maxMotorTorque: Float, lowerAngle: Float?, upperAngle: Float?)
        case distance(length: Float?, frequency: Float, dampingRatio: Float, minLength: Float?, maxLength: Float?)
    }
    public var kind: Kind
    public var connected: Entity
    /// Anchor in this entity's local space.
    public var localAnchor: Vec2
    /// Anchor on the connected body (local), used by distance joints.
    public var connectedLocalAnchor: Vec2
    public init(_ kind: Kind, connected: Entity, localAnchor: Vec2 = .zero, connectedLocalAnchor: Vec2 = .zero) {
        self.kind = kind
        self.connected = connected
        self.localAnchor = localAnchor
        self.connectedLocalAnchor = connectedLocalAnchor
    }
}

/// Generates static box colliders from a `Tilemap`'s solid tiles (merged per row run).
public struct TilemapCollider: SerializableComponent, Hashable, Sendable {
    public var material = PhysicsMaterial(friction: 0.8)
    public var filter = CollisionFilter.default
    public init() {}
}

/// Runtime link between an entity and its body (not serialized).
public struct PhysicsBody2DHandle: Component, Sendable {
    public var body: BodyID
    var lastPosition: Vec2
    var lastAngle: Float
    var revision: UInt64 = 0
}

// MARK: - 3D

public struct RigidBody3D: SerializableComponent, Hashable, Sendable {
    public var type: BodyType = .dynamic
    public var linearDamping: Float = 0.01
    public var angularDamping: Float = 0.05
    public var gravityScale: Float = 1
    /// Rotation lock per axis (1 free, 0 locked).
    public var angularFactor = Vec3(1, 1, 1)
    public var allowSleep = true
    public var interpolate = true
    public var initialVelocity: Vec3 = .zero
    public init(type: BodyType = .dynamic) { self.type = type }
}

/// Serializable 3D collider shape description.
public struct ColliderShape3D: Codable, Hashable, Sendable {
    public enum Geometry: Codable, Hashable, Sendable {
        case sphere(radius: Float)
        case box(halfExtents: Vec3)
        case capsule(height: Float, radius: Float)
        case plane(normal: Vec3, distance: Float)
        /// Static triangle mesh referencing a mesh asset (resolved by the physics system).
        case mesh(AssetID)
    }
    public var geometry: Geometry
    public var offset: Vec3 = .zero
    public var rotation: Quat = .identity
    public var material: PhysicsMaterial = .default
    public var filter: CollisionFilter = .default
    public var isTrigger = false
    public init(_ g: Geometry, offset: Vec3 = .zero, material: PhysicsMaterial = .default, isTrigger: Bool = false) {
        geometry = g
        self.offset = offset
        self.material = material
        self.isTrigger = isTrigger
    }
}

public struct Collider3D: SerializableComponent, Hashable, Sendable {
    public var shapes: [ColliderShape3D]
    public init(_ shapes: [ColliderShape3D]) { self.shapes = shapes }
    public init(_ shape: ColliderShape3D) { shapes = [shape] }
    public static func box(_ size: Vec3, material: PhysicsMaterial = .default, isTrigger: Bool = false) -> Collider3D {
        Collider3D(ColliderShape3D(.box(halfExtents: size * 0.5), material: material, isTrigger: isTrigger))
    }
    public static func sphere(_ r: Float, material: PhysicsMaterial = .default, isTrigger: Bool = false) -> Collider3D {
        Collider3D(ColliderShape3D(.sphere(radius: r), material: material, isTrigger: isTrigger))
    }
    public static func capsule(height: Float, radius: Float, material: PhysicsMaterial = .default) -> Collider3D {
        Collider3D(ColliderShape3D(.capsule(height: height, radius: radius), material: material))
    }
}

public struct Joint3D: SerializableComponent, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case ball
        case hinge(axis: Vec3, motorSpeed: Float?, maxMotorTorque: Float)
        case fixed
        case distance(minLength: Float?, maxLength: Float?)
    }
    public var kind: Kind
    public var connected: Entity
    public var localAnchor: Vec3
    public var connectedLocalAnchor: Vec3
    public init(_ kind: Kind, connected: Entity, localAnchor: Vec3 = .zero, connectedLocalAnchor: Vec3 = .zero) {
        self.kind = kind
        self.connected = connected
        self.localAnchor = localAnchor
        self.connectedLocalAnchor = connectedLocalAnchor
    }
}

public struct PhysicsBody3DHandle: Component, Sendable {
    public var body: BodyID
    var lastPosition: Vec3
    var lastRotation: Quat
}

// MARK: - Events

/// Collision/trigger event between two entities, published on the engine `EventBus`.
public struct CollisionEvent2D: Event, Sendable {
    public var phase: ContactEvent<Vec2>.Phase
    public var entityA: Entity
    public var entityB: Entity
    public var isTrigger: Bool
    public var points: [Vec2]
    public var normal: Vec2
    public var impulse: Float
    /// True if `entity` participates.
    public func involves(_ e: Entity) -> Bool { entityA == e || entityB == e }
    public func other(than e: Entity) -> Entity { entityA == e ? entityB : entityA }
}

public struct CollisionEvent3D: Event, Sendable {
    public var phase: ContactEvent<Vec3>.Phase
    public var entityA: Entity
    public var entityB: Entity
    public var isTrigger: Bool
    public var points: [Vec3]
    public var normal: Vec3
    public var impulse: Float
    public func involves(_ e: Entity) -> Bool { entityA == e || entityB == e }
    public func other(than e: Entity) -> Entity { entityA == e ? entityB : entityA }
}

extension Entity {
    /// Packs an entity into physics user data.
    public var physicsUserData: UInt64 { (UInt64(generation) << 32) | UInt64(index) }
    public init(physicsUserData u: UInt64) {
        self.init(index: UInt32(truncatingIfNeeded: u), generation: UInt32(truncatingIfNeeded: u >> 32))
    }
}

extension ComponentRegistry {
    /// Registers FeroxPhysics' serializable components.
    public func registerPhysicsComponents() {
        register(RigidBody2D.self) { RigidBody2D() }
        register(Collider2D.self) { Collider2D.box(Vec2(1, 1)) }
        register(Joint2D.self)
        register(TilemapCollider.self) { TilemapCollider() }
        register(RigidBody3D.self) { RigidBody3D() }
        register(Collider3D.self) { Collider3D.box(Vec3(1, 1, 1)) }
        register(Joint3D.self)
    }
}
