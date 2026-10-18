import Foundation
import FeroxCore
import FeroxScene

/// Bridges `PhysicsWorld2D` and the ECS.
///
/// Each fixed step it: creates bodies for new `RigidBody2D`/`Collider2D` entities, destroys
/// bodies of removed entities, teleports static/kinematic bodies whose `Transform` was
/// moved by game code, steps the simulation, writes dynamic poses back to `Transform` and
/// publishes `CollisionEvent2D`s. `interpolate(alpha:)` (called by the engine before
/// rendering) writes interpolated poses for bodies with `interpolate == true`.
public final class PhysicsSystem2D: System {
    public let physics: PhysicsWorld2D
    public var phase: SystemPhase { .fixedUpdate }
    public var order: Int { 0 }
    public var isEnabled = true
    private var bodies: [Entity: BodyID] = [:]
    private var joints: [Entity: JointID] = [:]
    private var tilemapRevisions: [Entity: UInt64] = [:]

    public init(physics: PhysicsWorld2D = PhysicsWorld2D()) { self.physics = physics }

    public func attach(world: World) { world.setResource(physics) }

    public func body(for e: Entity) -> BodyID? { bodies[e] }

    public func update(world: World, context: SystemContext) {
        sync(world)
        physics.step(context.dt)
        writeBack(world)
        for ev in physics.contactEvents {
            context.events.enqueue(
                CollisionEvent2D(
                    phase: ev.phase, entityA: Entity(physicsUserData: ev.userDataA), entityB: Entity(physicsUserData: ev.userDataB),
                    isTrigger: ev.isTrigger, points: ev.points, normal: ev.normal, impulse: ev.normalImpulse))
        }
    }

    private func pose(of e: Entity, in world: World) -> (Vec2, Float) {
        let m = world.parent(of: e) != nil ? world.worldMatrix(of: e) : (world.get(Transform.self, e)?.localMatrix ?? .identity)
        let p = m.translation
        let angle = atan2(m.c0.y, m.c0.x)
        return (Vec2(p.x, p.y), angle)
    }

    /// Creates/destroys bodies so the physics world mirrors the ECS.
    public func sync(_ world: World) {
        // Remove bodies for dead entities or entities that lost their physics components.
        for (e, id) in bodies where !world.isAlive(e) || (!world.has(RigidBody2D.self, e) && !world.has(Collider2D.self, e) && !world.has(TilemapCollider.self, e)) {
            physics.destroyBody(id)
            bodies[e] = nil
            if world.isAlive(e) { world.remove(PhysicsBody2DHandle.self, from: e) }
        }
        for (e, j) in joints where !world.isAlive(e) || !world.has(Joint2D.self, e) {
            physics.destroyJoint(j)
            joints[e] = nil
        }

        // Create bodies for new entities.
        var candidates = Set(world.entities(with: RigidBody2D.self))
        candidates.formUnion(world.entities(with: Collider2D.self))
        for e in candidates where bodies[e] == nil {
            guard world.has(Transform.self, e), world.isActiveInHierarchy(e) else { continue }
            let rb = world.get(RigidBody2D.self, e)
            let (p, a) = pose(of: e, in: world)
            var d = BodyDesc2D(type: rb?.type ?? .static, position: p, angle: a, shapes: world.get(Collider2D.self, e)?.shapes ?? [])
            if let rb {
                d.linearDamping = rb.linearDamping
                d.angularDamping = rb.angularDamping
                d.gravityScale = rb.gravityScale
                d.fixedRotation = rb.fixedRotation
                d.allowSleep = rb.allowSleep
                d.linearVelocity = rb.initialVelocity
            }
            d.userData = e.physicsUserData
            let id = physics.createBody(d)
            bodies[e] = id
            world.add(PhysicsBody2DHandle(body: id, lastPosition: p, lastAngle: a), to: e)
        }

        // Tilemap colliders: rebuild when the tilemap changes.
        for e in world.entities(with: TilemapCollider.self) {
            guard let map = world.get(Tilemap.self, e), let tc = world.get(TilemapCollider.self, e) else { continue }
            if tilemapRevisions[e] == map.revision, bodies[e] != nil { continue }
            tilemapRevisions[e] = map.revision
            let shapes = PhysicsSystem2D.tilemapShapes(map, material: tc.material, filter: tc.filter)
            let (p, a) = pose(of: e, in: world)
            if let id = bodies[e] {
                physics.setShapes(id, shapes)
            } else {
                var d = BodyDesc2D(type: .static, position: p, angle: a, shapes: shapes)
                d.userData = e.physicsUserData
                bodies[e] = physics.createBody(d)
            }
        }

        // Teleports and property changes driven by game code.
        world.forEach(PhysicsBody2DHandle.self, Transform.self) { e, h, _ in
            let (p, a) = pose(of: e, in: world)
            if (p - h.lastPosition).lengthSquared > 1e-8 || Swift.abs(wrapAngle(a - h.lastAngle)) > 1e-5 {
                physics.setTransform(h.body, position: p, angle: a, resetInterpolation: true)
                h.lastPosition = p
                h.lastAngle = a
            }
        }

        // Joints.
        world.read(Joint2D.self) { e, j in
            guard joints[e] == nil, let a = bodies[e], let b = bodies[j.connected], let ba = physics.body(a),
                let bb = physics.body(b)
            else { return }
            let anchorA = ba.transform.apply(j.localAnchor)
            let anchorB = bb.transform.apply(j.connectedLocalAnchor)
            let desc: JointDesc2D
            switch j.kind {
            case let .revolute(speed, torque, lower, upper):
                desc = .revolute(
                    a: a, b: b, anchor: anchorA, motor: speed.map { (speed: $0, maxTorque: torque) },
                    limits: (lower != nil && upper != nil) ? lower!...max(lower!, upper!) : nil)
            case let .distance(length, f, damping, minL, maxL):
                desc = .distance(
                    a: a, b: b, anchorA: anchorA, anchorB: anchorB, length: length, frequency: f, dampingRatio: damping,
                    minLength: minL, maxLength: maxL)
            }
            if let id = physics.createJoint(desc) { joints[e] = id }
        }
    }

    private func writeBack(_ world: World) {
        world.forEach(PhysicsBody2DHandle.self, Transform.self) { e, h, t in
            guard let b = physics.body(h.body), b.type != .static else { return }
            setPose(world, e, &t, b.position, b.angle)
            h.lastPosition = b.position
            h.lastAngle = b.angle
        }
    }

    /// Writes interpolated poses for rendering. `alpha` is `FrameTime.interpolationAlpha`.
    public func interpolate(_ world: World, alpha: Float) {
        world.forEach(PhysicsBody2DHandle.self, Transform.self) { e, h, t in
            guard let b = physics.body(h.body), b.type != .static, b.isAwake,
                world.get(RigidBody2D.self, e)?.interpolate ?? false
            else { return }
            let (p, a) = b.interpolated(alpha)
            setPose(world, e, &t, p, a)
            h.lastPosition = p
            h.lastAngle = a
        }
    }

    private func setPose(_ world: World, _ e: Entity, _ t: inout Transform, _ p: Vec2, _ a: Float) {
        if let parent = world.parent(of: e) {
            let inv = world.worldMatrix(of: parent).inverse
            let lp = inv.transformPoint(Vec3(p.x, p.y, t.position.z))
            t.position = lp
            let parentAngle = atan2(world.worldMatrix(of: parent).c0.y, world.worldMatrix(of: parent).c0.x)
            t.rotation2D = a - parentAngle
        } else {
            t.position = Vec3(p.x, p.y, t.position.z)
            t.rotation2D = a
        }
    }

    /// Greedy row-run merge of solid tiles into boxes.
    public static func tilemapShapes(_ map: Tilemap, material: PhysicsMaterial, filter: CollisionFilter) -> [Shape2D] {
        var shapes: [Shape2D] = []
        let solid: (Int32) -> Bool = { map.solidTiles.isEmpty ? $0 >= 0 : map.solidTiles.contains($0) }
        for y in 0..<map.height {
            var x = 0
            while x < map.width {
                guard solid(map[x, y]) else {
                    x += 1
                    continue
                }
                let start = x
                while x < map.width && solid(map[x, y]) { x += 1 }
                let w = Float(x - start) * map.tileSize.x
                let center = Vec2((Float(start) * map.tileSize.x) + w / 2, (Float(y) + 0.5) * map.tileSize.y)
                var s = Shape2D.box(halfExtents: Vec2(w / 2, map.tileSize.y / 2), center: center)
                s.material = material
                s.filter = filter
                shapes.append(s)
                // Shapes per body are limited to 256 (contact key packing); split into extra
                // rows beyond that would require multiple bodies.
                if shapes.count >= 255 { return shapes }
            }
        }
        return shapes
    }
}

/// Wraps an angle difference into [-π, π].
@inline(__always) func wrapAngle(_ a: Float) -> Float {
    let twoPi = 2 * Float.pi
    return a - twoPi * (a / twoPi).rounded()
}

/// Bridges `PhysicsWorld3D` and the ECS (same responsibilities as `PhysicsSystem2D`).
public final class PhysicsSystem3D: System {
    public let physics: PhysicsWorld3D
    public var phase: SystemPhase { .fixedUpdate }
    public var order: Int { 1 }
    public var isEnabled = true
    /// Resolves `ColliderShape3D.Geometry.mesh` asset ids to collision meshes.
    public var meshProvider: ((AssetID) -> TriangleMesh?)?
    private var bodies: [Entity: BodyID] = [:]
    private var joints: [Entity: JointID] = [:]

    public init(physics: PhysicsWorld3D = PhysicsWorld3D()) { self.physics = physics }

    public func attach(world: World) { world.setResource(physics) }

    public func body(for e: Entity) -> BodyID? { bodies[e] }

    public func update(world: World, context: SystemContext) {
        sync(world)
        physics.step(context.dt)
        writeBack(world)
        for ev in physics.contactEvents {
            context.events.enqueue(
                CollisionEvent3D(
                    phase: ev.phase, entityA: Entity(physicsUserData: ev.userDataA), entityB: Entity(physicsUserData: ev.userDataB),
                    isTrigger: ev.isTrigger, points: ev.points, normal: ev.normal, impulse: ev.normalImpulse))
        }
    }

    private func pose(of e: Entity, in world: World) -> (Vec3, Quat) {
        if world.parent(of: e) != nil {
            let d = world.worldMatrix(of: e).decompose()
            return (d.translation, d.rotation)
        }
        let t = world.get(Transform.self, e) ?? Transform()
        return (t.position, t.rotation)
    }

    func makeShapes(_ c: Collider3D?, scale: Vec3) -> [Shape3D] {
        guard let c else { return [] }
        let s = (scale.x + scale.y + scale.z) / 3  // colliders use uniform scale
        return c.shapes.compactMap { d in
            let g: ShapeGeometry3D
            switch d.geometry {
            case .sphere(let r): g = .sphere(radius: r * s)
            case .box(let h): g = .box(halfExtents: h * scale)
            case .capsule(let height, let r):
                g = .capsule(halfHeight: max(0, height * s * 0.5 - r * s), radius: r * s)
            case .plane(let n, let dist): g = .plane(normal: n.normalized, distance: dist)
            case .mesh(let id):
                guard let mesh = meshProvider?(id) else {
                    Log.warning("Physics", "Mesh collider asset \(id) unavailable")
                    return nil
                }
                g = .mesh(mesh)
            }
            return Shape3D(g, localPose: Pose3D(position: d.offset * scale, rotation: d.rotation), material: d.material,
                           filter: d.filter, isTrigger: d.isTrigger)
        }
    }

    public func sync(_ world: World) {
        for (e, id) in bodies where !world.isAlive(e) || (!world.has(RigidBody3D.self, e) && !world.has(Collider3D.self, e)) {
            physics.destroyBody(id)
            bodies[e] = nil
            if world.isAlive(e) { world.remove(PhysicsBody3DHandle.self, from: e) }
        }
        for (e, j) in joints where !world.isAlive(e) || !world.has(Joint3D.self, e) {
            physics.destroyJoint(j)
            joints[e] = nil
        }
        var candidates = Set(world.entities(with: RigidBody3D.self))
        candidates.formUnion(world.entities(with: Collider3D.self))
        for e in candidates where bodies[e] == nil {
            guard let t = world.get(Transform.self, e), world.isActiveInHierarchy(e) else { continue }
            let rb = world.get(RigidBody3D.self, e)
            let (p, q) = pose(of: e, in: world)
            var d = BodyDesc3D(type: rb?.type ?? .static, position: p, rotation: q,
                               shapes: makeShapes(world.get(Collider3D.self, e), scale: t.scale))
            if let rb {
                d.linearDamping = rb.linearDamping
                d.angularDamping = rb.angularDamping
                d.gravityScale = rb.gravityScale
                d.angularFactor = rb.angularFactor
                d.allowSleep = rb.allowSleep
                d.linearVelocity = rb.initialVelocity
            }
            d.userData = e.physicsUserData
            let id = physics.createBody(d)
            bodies[e] = id
            world.add(PhysicsBody3DHandle(body: id, lastPosition: p, lastRotation: q), to: e)
        }
        world.forEach(PhysicsBody3DHandle.self, Transform.self) { e, h, _ in
            let (p, q) = pose(of: e, in: world)
            if (p - h.lastPosition).lengthSquared > 1e-8 || !q.isApproximatelyEqual(to: h.lastRotation, tolerance: 1e-5) {
                physics.setTransform(h.body, position: p, rotation: q, resetInterpolation: true)
                h.lastPosition = p
                h.lastRotation = q
            }
        }
        world.read(Joint3D.self) { e, j in
            guard joints[e] == nil, let a = bodies[e], let b = bodies[j.connected], let ba = physics.body(a),
                let bb = physics.body(b)
            else { return }
            let anchorA = ba.pose.apply(j.localAnchor)
            let anchorB = bb.pose.apply(j.connectedLocalAnchor)
            let desc: JointDesc3D
            switch j.kind {
            case .ball: desc = .ball(a: a, b: b, anchor: anchorA)
            case let .hinge(axis, speed, torque):
                desc = .hinge(a: a, b: b, anchor: anchorA, axis: ba.pose.rotate(axis), motor: speed.map { (speed: $0, maxTorque: torque) })
            case .fixed: desc = .fixed(a: a, b: b)
            case let .distance(minL, maxL):
                desc = .distance(a: a, b: b, anchorA: anchorA, anchorB: anchorB, minLength: minL, maxLength: maxL)
            }
            if let id = physics.createJoint(desc) { joints[e] = id }
        }
    }

    private func writeBack(_ world: World) {
        world.forEach(PhysicsBody3DHandle.self, Transform.self) { e, h, t in
            guard let b = physics.body(h.body), b.type != .static else { return }
            setPose(world, e, &t, b.position, b.rotation)
            h.lastPosition = b.position
            h.lastRotation = b.rotation
        }
    }

    public func interpolate(_ world: World, alpha: Float) {
        world.forEach(PhysicsBody3DHandle.self, Transform.self) { e, h, t in
            guard let b = physics.body(h.body), b.type != .static, b.isAwake,
                world.get(RigidBody3D.self, e)?.interpolate ?? false
            else { return }
            let (p, q) = b.interpolated(alpha)
            setPose(world, e, &t, p, q)
            h.lastPosition = p
            h.lastRotation = q
        }
    }

    private func setPose(_ world: World, _ e: Entity, _ t: inout Transform, _ p: Vec3, _ q: Quat) {
        if let parent = world.parent(of: e) {
            let pm = world.worldMatrix(of: parent)
            let local = pm.inverse * Mat4(translation: p, rotation: q, scale: Vec3(1, 1, 1))
            let d = local.decompose()
            t.position = d.translation
            t.rotation = d.rotation
        } else {
            t.position = p
            t.rotation = q
        }
    }
}

/// Kinematic character controller for 3D (capsule, slide-and-step).
///
/// Moves a capsule by casting a sphere at its base along the desired motion and sliding
/// along hit surfaces (up to 4 iterations), with ground detection and slope limiting.
/// It moves the entity's `Transform` directly and does not require a `RigidBody3D`.
public struct CharacterController3D: SerializableComponent, Hashable, Sendable {
    public var radius: Float = 0.35
    public var height: Float = 1.8
    public var maxSlopeDegrees: Float = 50
    public var skinWidth: Float = 0.02
    public var gravity: Float = -20
    public internal(set) var verticalVelocity: Float = 0
    public internal(set) var isGrounded = false
    public var filter = CollisionFilter.default
    public init() {}

    /// Moves by `displacement` (horizontal intent) plus gravity over `dt`. Returns the applied motion.
    @discardableResult
    public mutating func move(_ transform: inout Transform, displacement: Vec3, dt: Float, physics: PhysicsWorld3D, jump: Float? = nil) -> Vec3 {
        if let jump, isGrounded { verticalVelocity = jump }
        verticalVelocity += gravity * dt
        var motion = displacement + Vec3(0, verticalVelocity * dt, 0)
        var position = transform.position
        let minGroundDot = cos(maxSlopeDegrees.radians)
        isGrounded = false
        let centerOffset = Vec3(0, radius, 0)
        for _ in 0..<4 {
            let len = motion.length
            if len < 1e-5 { break }
            let dir = motion / len
            // Cast from the sphere at the capsule base and the one at its top; take the nearest.
            let bottom = position + centerOffset
            let top = position + Vec3(0, max(height - radius, radius), 0)
            let hits = [bottom, top].compactMap {
                physics.sphereCast(origin: $0, direction: dir, radius: radius, maxDistance: len + skinWidth, filter: filter)
            }
            guard let hit = hits.min(by: { $0.distance < $1.distance }) else {
                position += motion
                motion = .zero
                break
            }
            let travel = max(0, hit.distance - skinWidth)
            position += dir * travel
            if hit.normal.y >= minGroundDot {
                isGrounded = true
                if verticalVelocity < 0 { verticalVelocity = 0 }
            }
            // Slide: remove the component into the surface.
            var remaining = motion - dir * travel
            remaining -= hit.normal * remaining.dot(hit.normal)
            if hit.normal.y < minGroundDot && remaining.y > 0 { remaining.y = 0 }  // no climbing steep slopes
            motion = remaining
        }
        // Ground probe for stable grounding on flat floors.
        if !isGrounded,
            let g = physics.sphereCast(
                origin: position + centerOffset, direction: Vec3(0, -1, 0), radius: radius * 0.95,
                maxDistance: skinWidth * 4, filter: filter), g.normal.y >= minGroundDot
        {
            isGrounded = true
            if verticalVelocity < 0 { verticalVelocity = 0 }
        }
        let applied = position - transform.position
        transform.position = position
        return applied
    }
}
