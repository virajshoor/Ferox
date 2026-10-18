import Foundation
import FeroxCore

public struct BodyDesc3D: Sendable {
    public var type: BodyType = .dynamic
    public var position: Vec3 = .zero
    public var rotation: Quat = .identity
    public var linearVelocity: Vec3 = .zero
    public var angularVelocity: Vec3 = .zero
    public var linearDamping: Float = 0.01
    public var angularDamping: Float = 0.05
    public var gravityScale: Float = 1
    /// Per-axis rotation lock (1 = free, 0 = locked), e.g. (0, 1, 0) for upright characters.
    public var angularFactor = Vec3(1, 1, 1)
    public var allowSleep = true
    public var userData: UInt64 = 0
    public var shapes: [Shape3D] = []
    public init(type: BodyType = .dynamic, position: Vec3 = .zero, rotation: Quat = .identity, shapes: [Shape3D] = []) {
        self.type = type
        self.position = position
        self.rotation = rotation
        self.shapes = shapes
    }
}

/// Simulation state of a 3D rigid body.
public struct Body3D: Sendable {
    public internal(set) var type: BodyType
    public internal(set) var position: Vec3
    public internal(set) var rotation: Quat
    public internal(set) var linearVelocity: Vec3
    public internal(set) var angularVelocity: Vec3
    public internal(set) var previousPosition: Vec3
    public internal(set) var previousRotation: Quat
    public internal(set) var shapes: [Shape3D]
    public internal(set) var mass: Float = 0
    public internal(set) var localCenter: Vec3 = .zero
    public internal(set) var isAwake = true
    public var linearDamping: Float
    public var angularDamping: Float
    public var gravityScale: Float
    public internal(set) var angularFactor: Vec3
    public var allowSleep: Bool
    public var userData: UInt64

    var invMass: Float = 0
    var invInertiaLocal: Mat3 = .zero
    var invInertiaWorld: Mat3 = .zero
    var force = Vec3.zero
    var torque = Vec3.zero
    var sleepTime: Float = 0
    var aabb = AABB.empty

    public var pose: Pose3D { Pose3D(position: position, rotation: rotation) }
    public var worldCenter: Vec3 { pose.apply(localCenter) }

    public func interpolated(_ alpha: Float) -> (position: Vec3, rotation: Quat) {
        (previousPosition.lerp(to: position, alpha), previousRotation.nlerp(to: rotation, alpha))
    }

    public func velocity(at worldPoint: Vec3) -> Vec3 { linearVelocity + angularVelocity.cross(worldPoint - worldCenter) }

    mutating func updateWorldInertia() {
        let r = Mat3(rotation)
        invInertiaWorld = r * invInertiaLocal * r.transposed
        // Apply rotation locks by scaling rows/columns.
        if angularFactor != Vec3(1, 1, 1) {
            let f = Mat3(diagonal: angularFactor)
            invInertiaWorld = f * invInertiaWorld * f
        }
    }
}

public struct RaycastHit3D: Sendable {
    public var body: BodyID
    public var shape: Int
    public var point: Vec3
    public var normal: Vec3
    public var distance: Float
    public var userData: UInt64
}

public enum JointDesc3D: Sendable {
    /// Ball-and-socket at a world anchor.
    case ball(a: BodyID, b: BodyID, anchor: Vec3)
    /// Hinge around a world axis through a world anchor, with optional motor.
    case hinge(a: BodyID, b: BodyID, anchor: Vec3, axis: Vec3, motor: (speed: Float, maxTorque: Float)? = nil)
    /// Fixes the relative pose of two bodies.
    case fixed(a: BodyID, b: BodyID)
    /// Keeps two anchors at a distance (rod), or within [min, max] (rope/slack).
    case distance(a: BodyID, b: BodyID, anchorA: Vec3, anchorB: Vec3, minLength: Float? = nil, maxLength: Float? = nil)
}

/// A 3D rigid-body physics world. Same solver architecture as `PhysicsWorld2D` (sequential
/// impulses, warm starting, two friction directions, speculative contacts, sleep islands).
///
/// Supported shape pairs: sphere, box, capsule (all pairs), plane vs convex, triangle mesh
/// vs sphere/capsule (boxes vs mesh are approximated by an inscribed capsule). Convex hulls
/// are not implemented; continuous collision covers fast dynamic bodies against static and
/// kinematic ones only. See Docs/13-Physics.md.
public final class PhysicsWorld3D {
    public var gravity = Vec3(0, -9.81, 0)
    public var settings = SolverSettings()
    public private(set) var stepCount: UInt64 = 0

    var bodies: [Body3D?] = []
    var generations: [UInt32] = []
    var freeBodies: [UInt32] = []
    var contacts: [UInt64: Contact3D] = [:]
    var joints: [JointState3D?] = []
    var jointGenerations: [UInt32] = []
    var broadphase = SweepAndPrune()
    var broadphaseDirty = true
    /// Scratch buffer reused each step for the broadphase input (avoids a per-step allocation).
    private var broadphaseItems: [(id: Int, minX: Float, maxX: Float)] = []

    public private(set) var contactEvents: [ContactEvent<Vec3>] = []
    public var onContact: ((ContactEvent<Vec3>) -> Void)?

    public init(gravity: Vec3 = Vec3(0, -9.81, 0)) { self.gravity = gravity }

    // MARK: Bodies

    @discardableResult
    public func createBody(_ d: BodyDesc3D) -> BodyID {
        let b = Body3D(
            type: d.type, position: d.position, rotation: d.rotation.normalized, linearVelocity: d.linearVelocity,
            angularVelocity: d.angularVelocity, previousPosition: d.position, previousRotation: d.rotation.normalized,
            shapes: d.shapes, linearDamping: d.linearDamping, angularDamping: d.angularDamping,
            gravityScale: d.gravityScale, angularFactor: d.angularFactor, allowSleep: d.allowSleep, userData: d.userData)
        let index: Int
        if let i = freeBodies.popLast() {
            index = Int(i)
            bodies[index] = b
        } else {
            index = bodies.count
            bodies.append(b)
            generations.append(1)
        }
        recomputeMass(index)
        updateAABB(index)
        broadphaseDirty = true
        return BodyID(index: UInt32(index), generation: generations[index])
    }

    public func destroyBody(_ id: BodyID) {
        guard isValid(id) else { return }
        let i = Int(id.index)
        for (k, c) in contacts where c.bodyA == i || c.bodyB == i {
            if c.touching { emitEnd(c) }
            contacts[k] = nil
        }
        for j in joints.indices where joints[j]?.bodyA == i || joints[j]?.bodyB == i { joints[j] = nil }
        bodies[i] = nil
        generations[i] &+= 1
        if generations[i] == 0 { generations[i] = 1 }
        freeBodies.append(id.index)
        broadphaseDirty = true
    }

    public func isValid(_ id: BodyID) -> Bool {
        let i = Int(id.index)
        return i < bodies.count && bodies[i] != nil && generations[i] == id.generation
    }

    public func body(_ id: BodyID) -> Body3D? { isValid(id) ? bodies[Int(id.index)] : nil }
    public var bodyCount: Int { bodies.count - freeBodies.count }
    public var bodyIDs: [BodyID] {
        bodies.indices.compactMap { i in bodies[i] == nil ? nil : BodyID(index: UInt32(i), generation: generations[i]) }
    }
    func bodyID(_ i: Int) -> BodyID { BodyID(index: UInt32(i), generation: generations[i]) }

    private func mutate(_ id: BodyID, wake: Bool = true, _ f: (inout Body3D) -> Void) {
        guard isValid(id) else { return }
        let i = Int(id.index)
        f(&bodies[i]!)
        if wake {
            bodies[i]!.isAwake = true
            bodies[i]!.sleepTime = 0
        }
    }

    public func setTransform(_ id: BodyID, position: Vec3, rotation: Quat, resetInterpolation: Bool = false) {
        mutate(id) { b in
            b.position = position
            b.rotation = rotation.normalized
            if resetInterpolation {
                b.previousPosition = position
                b.previousRotation = b.rotation
            }
            b.updateWorldInertia()
        }
        if isValid(id) { updateAABB(Int(id.index)) }
    }
    public func setLinearVelocity(_ id: BodyID, _ v: Vec3) { mutate(id) { $0.linearVelocity = v } }
    public func setAngularVelocity(_ id: BodyID, _ w: Vec3) { mutate(id) { $0.angularVelocity = w } }
    public func applyForce(_ id: BodyID, _ f: Vec3, at point: Vec3? = nil) {
        mutate(id) { b in
            b.force += f
            if let point { b.torque += (point - b.worldCenter).cross(f) }
        }
    }
    public func applyTorque(_ id: BodyID, _ t: Vec3) { mutate(id) { $0.torque += t } }
    public func applyImpulse(_ id: BodyID, _ j: Vec3, at point: Vec3? = nil) {
        mutate(id) { b in
            b.linearVelocity += j * b.invMass
            if let point { b.angularVelocity += b.invInertiaWorld * (point - b.worldCenter).cross(j) }
        }
    }
    public func applyAngularImpulse(_ id: BodyID, _ j: Vec3) { mutate(id) { $0.angularVelocity += $0.invInertiaWorld * j } }
    public func setType(_ id: BodyID, _ t: BodyType) {
        mutate(id) { $0.type = t }
        if isValid(id) { recomputeMass(Int(id.index)) }
    }
    public func setShapes(_ id: BodyID, _ shapes: [Shape3D]) {
        mutate(id) { $0.shapes = shapes }
        guard isValid(id) else { return }
        let i = Int(id.index)
        for (k, c) in contacts where c.bodyA == i || c.bodyB == i { contacts[k] = nil }
        recomputeMass(i)
        updateAABB(i)
    }
    public func setAngularFactor(_ id: BodyID, _ f: Vec3) {
        mutate(id) { b in
            b.angularFactor = f
            b.updateWorldInertia()
        }
    }
    public func setDamping(_ id: BodyID, linear: Float, angular: Float) {
        mutate(id, wake: false) {
            $0.linearDamping = linear
            $0.angularDamping = angular
        }
    }
    public func setGravityScale(_ id: BodyID, _ s: Float) { mutate(id) { $0.gravityScale = s } }
    public func wake(_ id: BodyID) { mutate(id) { _ in } }

    func wakeBody(_ i: Int) {
        guard i >= 0, i < bodies.count, bodies[i] != nil else { return }
        bodies[i]!.isAwake = true
        bodies[i]!.sleepTime = 0
    }

    func recomputeMass(_ i: Int) {
        var b = bodies[i]!
        b.mass = 0
        b.invMass = 0
        b.invInertiaLocal = .zero
        b.localCenter = .zero
        if b.type == .dynamic {
            var m: Float = 0
            var c = Vec3.zero
            var inertia = Mat3.zero
            for s in b.shapes where !s.isTrigger {
                let md = s.massData()
                m += md.mass
                c += md.center * md.mass
                inertia = inertia + md.inertia
            }
            if m > 0 {
                c /= m
                // Shift the inertia tensor from the body origin to the centre of mass.
                let shift = Mat3(diagonal: Vec3(repeating: c.lengthSquared)) + Mat3(columns: c * -c.x, c * -c.y, c * -c.z)
                inertia = inertia + shift * -m
                b.mass = m
                b.invMass = 1 / m
                b.localCenter = c
                b.invInertiaLocal = inertia.inverse
            } else {
                b.mass = 1
                b.invMass = 1
                b.invInertiaLocal = Mat3(diagonal: Vec3(repeating: 1))
            }
        }
        b.updateWorldInertia()
        bodies[i] = b
    }

    func updateAABB(_ i: Int) {
        guard var b = bodies[i] else { return }
        var box = AABB.empty
        let pose = b.pose
        for s in b.shapes { box.expand(s.aabb(pose)) }
        if b.shapes.isEmpty { box = AABB(center: b.position, extents: .zero) }
        b.aabb = box.inflated(by: settings.speculativeDistance)
        bodies[i] = b
    }

    // MARK: Joints

    @discardableResult
    public func createJoint(_ d: JointDesc3D) -> JointID? {
        guard let j = JointState3D(d, world: self) else { return nil }
        let index: Int
        if let free = joints.firstIndex(where: { $0 == nil }) {
            index = free
            joints[index] = j
            jointGenerations[index] &+= 1
        } else {
            index = joints.count
            joints.append(j)
            jointGenerations.append(1)
        }
        wakeBody(j.bodyA)
        wakeBody(j.bodyB)
        return JointID(index: UInt32(index), generation: jointGenerations[index])
    }

    public func destroyJoint(_ id: JointID) {
        let i = Int(id.index)
        guard i < joints.count, jointGenerations[i] == id.generation, let j = joints[i] else { return }
        wakeBody(j.bodyA)
        wakeBody(j.bodyB)
        joints[i] = nil
    }

    public func setMotorSpeed(_ id: JointID, _ speed: Float) {
        let i = Int(id.index)
        guard i < joints.count, jointGenerations[i] == id.generation, let j = joints[i] else { return }
        joints[i]!.motorSpeed = speed
        wakeBody(j.bodyA)
        wakeBody(j.bodyB)
    }

    // MARK: Step

    public func step(_ dt: Float) {
        guard dt > 0 else { return }
        stepCount &+= 1
        contactEvents.removeAll(keepingCapacity: true)
        let n = bodies.count
        let inv = 1 / dt

        for i in 0..<n {
            guard var b = bodies[i] else { continue }
            b.previousPosition = b.position
            b.previousRotation = b.rotation
            if b.type == .dynamic && b.isAwake {
                b.linearVelocity += dt * (gravity * b.gravityScale + b.force * b.invMass)
                b.angularVelocity += dt * (b.invInertiaWorld * b.torque)
                b.linearVelocity *= 1 / (1 + dt * b.linearDamping)
                b.angularVelocity *= 1 / (1 + dt * b.angularDamping)
                b.angularVelocity *= b.angularFactor
            }
            b.force = .zero
            b.torque = .zero
            bodies[i] = b
        }

        updateContacts()

        // Sorted so the solve order (and therefore the result) is deterministic.
        // Single pass over the dictionary (no per-key re-lookup); sorted for a stable order.
        var active: [UInt64] = []
        active.reserveCapacity(contacts.count)
        for (k, c) in contacts where c.isActive(bodies) { active.append(k) }
        active.sort()
        for k in active { contacts[k]!.prepare(bodies, settings: settings, invDt: inv) }
        for j in joints.indices { joints[j]?.prepare(bodies, dt: dt, settings: settings) }
        if settings.warmStarting {
            for k in active { contacts[k]!.warmStart(&bodies) }
            for j in joints.indices { joints[j]?.warmStart(&bodies) }
        }
        for _ in 0..<max(1, settings.velocityIterations) {
            for j in joints.indices { joints[j]?.solve(&bodies, dt: dt) }
            for k in active { contacts[k]!.solve(&bodies) }
        }

        for i in 0..<n {
            guard var b = bodies[i], b.type != .static, b.isAwake else { continue }
            var dp = b.linearVelocity * dt
            if dp.lengthSquared > settings.maxTranslation * settings.maxTranslation {
                dp *= settings.maxTranslation / dp.length
                b.linearVelocity = dp * inv
            }
            var w = b.angularVelocity
            let angle = w.length * dt
            if angle > settings.maxRotation {
                w *= settings.maxRotation / angle
                b.angularVelocity = w
            }
            let oldCenter = b.worldCenter
            if settings.continuousCollision && b.type == .dynamic { dp = clampContinuous(i, b, from: oldCenter, dp) }
            // Quaternion integration: q' = q + ½ (ω, 0) q dt.
            let wq = Quat(x: w.x, y: w.y, z: w.z, w: 0)
            let dq = wq * b.rotation
            b.rotation = Quat(b.rotation.vector + dq.vector * (0.5 * dt)).normalized
            b.position = (oldCenter + dp) - b.rotation.act(b.localCenter)
            b.updateWorldInertia()
            bodies[i] = b
        }
        for i in 0..<n where bodies[i] != nil { updateAABB(i) }

        if settings.allowSleep { updateSleep(dt) }
        if let onContact { for e in contactEvents { onContact(e) } }
    }

    /// Continuous collision: shortens a dynamic body's step motion `dp` (from its centre `c`) so
    /// its core sphere stops just short of the first static or kinematic surface in the way; the
    /// contact solver stops it on the next step. Velocity is kept.
    /// ponytail: core-sphere sweep, Box2D-style; fast dynamic-vs-dynamic pairs can still tunnel.
    private func clampContinuous(_ i: Int, _ b: Body3D, from c: Vec3, _ dp: Vec3) -> Vec3 {
        let ext = b.aabb.extents - Vec3(repeating: settings.speculativeDistance)
        let core = 0.5 * min(ext.x, min(ext.y, ext.z))
        let len = dp.length
        guard core > 0, len > core, let filter = b.shapes.first(where: { !$0.isTrigger })?.filter else { return dp }
        let d = dp / len
        let ray = Ray(origin: c, direction: d)
        var best = len
        for j in bodies.indices where j != i {
            guard let o = bodies[j], o.type != .dynamic, !jointsDisableCollision(i, j),
                  o.aabb.inflated(by: core).intersect(ray, maxDistance: len) != nil else { continue }
            let pose = o.pose
            for s in o.shapes where !s.isTrigger && filter.shouldCollide(with: s.filter) {
                guard let (t, n) = Collide3D.rayShape(s, pose, c, d, best, inflate: core), t > 0, n.dot(d) < 0 else { continue }
                best = t
            }
        }
        return best < len ? d * max(best - settings.linearSlop, 0) : dp
    }

    private func shapeKey(_ body: Int, _ shape: Int) -> Int { (body << 8) | (shape & 0xFF) }

    func updateContacts() {
        broadphaseItems.removeAll(keepingCapacity: true)
        broadphaseItems.reserveCapacity(bodies.count)
        for i in bodies.indices { if let b = bodies[i] { broadphaseItems.append((i, b.aabb.min.x, b.aabb.max.x)) } }
        broadphase.update(broadphaseItems, rebuild: broadphaseDirty)
        broadphaseDirty = false

        var seen = Set<UInt64>()
        seen.reserveCapacity(contacts.count)
        broadphase.forEachOverlap { ia, ib in
            guard let a = bodies[ia], let b = bodies[ib] else { return }
            if a.type != .dynamic && b.type != .dynamic {
                if !(a.shapes.contains { $0.isTrigger } || b.shapes.contains { $0.isTrigger }) { return }
            }
            if !a.isAwake && !b.isAwake {
                for (k, c) in contacts where (c.bodyA == ia && c.bodyB == ib) || (c.bodyA == ib && c.bodyB == ia) {
                    seen.insert(k)
                }
                return
            }
            guard a.aabb.intersects(b.aabb), !jointsDisableCollision(ia, ib) else { return }
            let pa = a.pose, pb = b.pose
            for (sa, shapeA) in a.shapes.enumerated() {
                let boxA = shapeA.aabb(pa).inflated(by: settings.speculativeDistance)
                for (sb, shapeB) in b.shapes.enumerated() {
                    guard shapeA.filter.shouldCollide(with: shapeB.filter), boxA.intersects(shapeB.aabb(pb)) else { continue }
                    let ka = shapeKey(ia, sa), kb = shapeKey(ib, sb)
                    let flip = ka > kb
                    let (bi, bj, si, sj) = flip ? (ib, ia, sb, sa) : (ia, ib, sa, sb)
                    let (s1, s2) = flip ? (shapeB, shapeA) : (shapeA, shapeB)
                    let (p1, p2) = flip ? (pb, pa) : (pa, pb)
                    let trigger = s1.isTrigger || s2.isTrigger
                    let manifold = Collide3D.manifold(s1, p1, s2, p2, margin: trigger ? 0 : settings.speculativeDistance)
                    let key = pairKey(ka, kb)
                    seen.insert(key)
                    var c = contacts[key] ?? Contact3D(bodyA: bi, bodyB: bj, shapeA: si, shapeB: sj, isTrigger: trigger)
                    c.friction = PhysicsMaterial.mixFriction(s1.material.friction, s2.material.friction)
                    c.restitution = PhysicsMaterial.mixRestitution(s1.material.restitution, s2.material.restitution)
                    let was = c.touching
                    c.update(manifold)
                    if c.touching && !was {
                        emitBegin(c)
                        wakeBody(bi)
                        wakeBody(bj)
                    } else if !c.touching && was {
                        emitEnd(c)
                    }
                    contacts[key] = c
                }
            }
        }
        for (k, c) in contacts where !seen.contains(k) {
            if c.touching { emitEnd(c) }
            contacts[k] = nil
        }
    }

    func jointsDisableCollision(_ a: Int, _ b: Int) -> Bool {
        for j in joints {
            if let j, !j.collideConnected, (j.bodyA == a && j.bodyB == b) || (j.bodyA == b && j.bodyB == a) { return true }
        }
        return false
    }

    func emitBegin(_ c: Contact3D) {
        contactEvents.append(
            ContactEvent(
                phase: .began, bodyA: bodyID(c.bodyA), bodyB: bodyID(c.bodyB), shapeA: c.shapeA, shapeB: c.shapeB,
                userDataA: bodies[c.bodyA]?.userData ?? 0, userDataB: bodies[c.bodyB]?.userData ?? 0,
                isTrigger: c.isTrigger, points: c.isTrigger ? [] : c.points.map(\.point), normal: c.normal,
                normalImpulse: c.points.reduce(0) { $0 + $1.normalImpulse }))
    }

    func emitEnd(_ c: Contact3D) {
        contactEvents.append(
            ContactEvent(
                phase: .ended, bodyA: bodyID(c.bodyA), bodyB: bodyID(c.bodyB), shapeA: c.shapeA, shapeB: c.shapeB,
                userDataA: bodies[c.bodyA]?.userData ?? 0, userDataB: bodies[c.bodyB]?.userData ?? 0,
                isTrigger: c.isTrigger, points: [], normal: c.normal, normalImpulse: 0))
    }

    func updateSleep(_ dt: Float) {
        let n = bodies.count
        var uf = UnionFind(count: n)
        for c in contacts.values where c.touching && !c.isTrigger {
            if bodies[c.bodyA]?.type == .dynamic && bodies[c.bodyB]?.type == .dynamic { uf.union(c.bodyA, c.bodyB) }
        }
        for j in joints {
            if let j, bodies[j.bodyA]?.type == .dynamic, bodies[j.bodyB]?.type == .dynamic { uf.union(j.bodyA, j.bodyB) }
        }
        let lin2 = settings.sleepLinearThreshold * settings.sleepLinearThreshold
        let ang2 = settings.sleepAngularThreshold * settings.sleepAngularThreshold
        // Only keyed lookups are used on these maps (never iterated), so capacity hints are safe.
        var minSleep: [Int: Float] = [:]
        minSleep.reserveCapacity(n)
        var islandAwake: [Int: Bool] = [:]
        islandAwake.reserveCapacity(n)
        for i in 0..<n {
            guard var b = bodies[i], b.type == .dynamic else { continue }
            if b.isAwake {
                if !b.allowSleep || b.linearVelocity.lengthSquared > lin2 || b.angularVelocity.lengthSquared > ang2 {
                    b.sleepTime = 0
                } else {
                    b.sleepTime += dt
                }
                bodies[i] = b
            }
            let root = uf.find(i)
            minSleep[root] = min(minSleep[root] ?? .infinity, b.isAwake ? b.sleepTime : .infinity)
            islandAwake[root] = (islandAwake[root] ?? false) || b.isAwake
        }
        for i in 0..<n {
            guard var b = bodies[i], b.type == .dynamic else { continue }
            let root = uf.find(i)
            guard islandAwake[root] == true else { continue }
            if (minSleep[root] ?? 0) >= settings.timeToSleep {
                b.isAwake = false
                b.linearVelocity = .zero
                b.angularVelocity = .zero
            } else if !b.isAwake {
                b.isAwake = true
                b.sleepTime = 0
            }
            bodies[i] = b
        }
    }

    // MARK: Queries

    public func raycast(
        origin: Vec3, direction: Vec3, maxDistance: Float = .infinity, filter: CollisionFilter = .default,
        includeTriggers: Bool = false
    ) -> RaycastHit3D? {
        var best: RaycastHit3D?
        raycastAll(origin: origin, direction: direction, maxDistance: maxDistance, filter: filter, includeTriggers: includeTriggers) {
            if $0.distance < (best?.distance ?? .infinity) { best = $0 }
            return true
        }
        return best
    }

    public func raycastAll(
        origin: Vec3, direction: Vec3, maxDistance: Float = .infinity, filter: CollisionFilter = .default,
        includeTriggers: Bool = false, radius: Float = 0, _ visit: (RaycastHit3D) -> Bool
    ) {
        let d = direction.normalized
        guard d.lengthSquared > 0 else { return }
        let ray = Ray(origin: origin, direction: d)
        for i in bodies.indices {
            guard let b = bodies[i] else { continue }
            guard b.aabb.inflated(by: radius).intersect(ray, maxDistance: maxDistance) != nil else { continue }
            let pose = b.pose
            for (si, s) in b.shapes.enumerated() {
                if s.isTrigger && !includeTriggers { continue }
                guard filter.shouldCollide(with: s.filter) else { continue }
                if let rh = Collide3D.rayShape(s, pose, origin, d, maxDistance, inflate: radius) {
                    let (t, n) = rh
                    let hit = RaycastHit3D(
                        body: bodyID(i), shape: si, point: origin + d * t - n * radius, normal: n, distance: t,
                        userData: b.userData)
                    if !visit(hit) { return }
                }
            }
        }
    }

    /// Sphere sweep. Exact for spheres/capsules/planes; conservative for boxes and meshes.
    public func sphereCast(
        origin: Vec3, direction: Vec3, radius: Float, maxDistance: Float, filter: CollisionFilter = .default
    ) -> RaycastHit3D? {
        var best: RaycastHit3D?
        raycastAll(origin: origin, direction: direction, maxDistance: maxDistance, filter: filter, radius: radius) {
            if $0.distance < (best?.distance ?? .infinity) { best = $0 }
            return true
        }
        return best
    }

    /// Bodies with a shape overlapping the sphere.
    public func overlapSphere(center: Vec3, radius: Float, filter: CollisionFilter = .default, includeTriggers: Bool = true) -> [BodyID] {
        let probe = Shape3D.sphere(radius)
        let pp = Pose3D(position: center)
        let box = AABB(center: center, extents: Vec3(repeating: radius))
        var out: [BodyID] = []
        for i in bodies.indices {
            guard let b = bodies[i], b.aabb.intersects(box) else { continue }
            let pose = b.pose
            let hit = b.shapes.contains { s in
                (includeTriggers || !s.isTrigger) && filter.shouldCollide(with: s.filter)
                    && Collide3D.manifold(probe, pp, s, pose, margin: 0).points.contains { $0.separation <= 0 }
            }
            if hit { out.append(bodyID(i)) }
        }
        return out
    }

    /// Bodies with a shape overlapping an oriented box.
    public func overlapBox(center: Vec3, halfExtents: Vec3, rotation: Quat = .identity, filter: CollisionFilter = .default) -> [BodyID] {
        let probe = Shape3D.box(halfExtents)
        let pp = Pose3D(position: center, rotation: rotation)
        let box = probe.aabb(pp)
        var out: [BodyID] = []
        for i in bodies.indices {
            guard let b = bodies[i], b.aabb.intersects(box) else { continue }
            let pose = b.pose
            if b.shapes.contains(where: { s in
                filter.shouldCollide(with: s.filter)
                    && Collide3D.manifold(probe, pp, s, pose, margin: 0).points.contains { $0.separation <= 0 }
            }) {
                out.append(bodyID(i))
            }
        }
        return out
    }

    public func contacts(of id: BodyID) -> [(other: BodyID, normal: Vec3, points: [Vec3])] {
        let i = Int(id.index)
        return contacts.values.compactMap { c in
            guard c.touching, !c.isTrigger, c.bodyA == i || c.bodyB == i else { return nil }
            let other = c.bodyA == i ? c.bodyB : c.bodyA
            return (bodyID(other), c.bodyA == i ? c.normal : -c.normal, c.points.map(\.point))
        }
    }

    public var activeContactCount: Int { contacts.values.filter(\.touching).count }

    // MARK: Debug draw

    public func debugLines(includeContacts: Bool = true) -> [DebugLine<Vec3>] {
        var lines: [DebugLine<Vec3>] = []
        func circle(_ c: Vec3, _ u: Vec3, _ v: Vec3, _ r: Float, _ kind: DebugLine<Vec3>.Kind) {
            let n = 20
            for k in 0..<n {
                let a0 = Float(k) / Float(n) * 2 * .pi, a1 = Float(k + 1) / Float(n) * 2 * .pi
                lines.append(DebugLine(a: c + (u * cos(a0) + v * sin(a0)) * r, b: c + (u * cos(a1) + v * sin(a1)) * r, kind: kind))
            }
        }
        for b in bodies {
            guard let b else { continue }
            for s in b.shapes {
                let kind: DebugLine<Vec3>.Kind =
                    s.isTrigger ? .trigger : (b.type == .static ? .staticCollider : (b.isAwake ? .collider : .sleeping))
                let pose = b.pose * s.localPose
                let r = Mat3(pose.rotation)
                switch s.geometry {
                case .sphere(let rad):
                    circle(pose.position, r.c0, r.c1, rad, kind)
                    circle(pose.position, r.c1, r.c2, rad, kind)
                    circle(pose.position, r.c0, r.c2, rad, kind)
                case .box(let h):
                    var corners: [Vec3] = []
                    for i in 0..<8 {
                        let sx: Float = (i & 1) != 0 ? 1 : -1, sy: Float = (i & 2) != 0 ? 1 : -1, sz: Float = (i & 4) != 0 ? 1 : -1
                        corners.append(pose.apply(Vec3(sx * h.x, sy * h.y, sz * h.z)))
                    }
                    for (a, c) in [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)] {
                        lines.append(DebugLine(a: corners[a], b: corners[c], kind: kind))
                    }
                case .capsule(let hh, let rad):
                    let top = pose.apply(Vec3(0, hh, 0)), bottom = pose.apply(Vec3(0, -hh, 0))
                    circle(top, r.c0, r.c2, rad, kind)
                    circle(bottom, r.c0, r.c2, rad, kind)
                    for side in [r.c0, -r.c0, r.c2, -r.c2] {
                        lines.append(DebugLine(a: top + side * rad, b: bottom + side * rad, kind: kind))
                    }
                case .plane(let n, let d):
                    let wn = b.pose.rotate(n)
                    let c = wn * (d + wn.dot(b.position))
                    let u = wn.anyPerpendicular, v = wn.cross(u)
                    for k in -5...5 {
                        let f = Float(k) * 2
                        lines.append(DebugLine(a: c + u * f - v * 10, b: c + u * f + v * 10, kind: kind))
                        lines.append(DebugLine(a: c + v * f - u * 10, b: c + v * f + u * 10, kind: kind))
                    }
                case .mesh(let mesh):
                    let limit = min(mesh.triangleCount, 20000)
                    for t in 0..<limit {
                        let (a, bb, c) = mesh.triangle(t)
                        let wa = pose.apply(a), wb = pose.apply(bb), wc = pose.apply(c)
                        lines.append(DebugLine(a: wa, b: wb, kind: kind))
                        lines.append(DebugLine(a: wb, b: wc, kind: kind))
                        lines.append(DebugLine(a: wc, b: wa, kind: kind))
                    }
                }
            }
        }
        if includeContacts {
            for c in contacts.values where c.touching && !c.isTrigger {
                for p in c.points { lines.append(DebugLine(a: p.point, b: p.point + c.normal * 0.25, kind: .contactNormal)) }
            }
        }
        for j in joints {
            guard let j, let a = bodies[j.bodyA], let b = bodies[j.bodyB] else { continue }
            lines.append(DebugLine(a: a.pose.apply(j.localAnchorA), b: b.pose.apply(j.localAnchorB), kind: .joint))
        }
        return lines
    }
}

// MARK: - Contact constraint

struct Contact3D {
    struct Point {
        var point: Vec3
        var separation: Float
        var id: UInt32
        var normalImpulse: Float = 0
        var tangentImpulse = Vec2.zero
        var rA = Vec3.zero, rB = Vec3.zero
        var normalMass: Float = 0
        var tangentMass = Vec2.zero
        var bias: Float = 0
        var restitutionBias: Float = 0
    }
    var bodyA: Int, bodyB: Int, shapeA: Int, shapeB: Int
    var isTrigger: Bool
    var normal = Vec3.zero
    var t1 = Vec3.zero, t2 = Vec3.zero
    var points: [Point] = []
    var friction: Float = 0.6
    var restitution: Float = 0
    var touching = false

    init(bodyA: Int, bodyB: Int, shapeA: Int, shapeB: Int, isTrigger: Bool) {
        self.bodyA = bodyA
        self.bodyB = bodyB
        self.shapeA = shapeA
        self.shapeB = shapeB
        self.isTrigger = isTrigger
    }

    mutating func update(_ m: Manifold3D) {
        var np: [Point] = []
        np.reserveCapacity(m.points.count)
        for mp in m.points {
            var p = Point(point: mp.point, separation: mp.separation, id: mp.id)
            if let old = points.first(where: { $0.id == mp.id }) {
                p.normalImpulse = old.normalImpulse
                p.tangentImpulse = old.tangentImpulse
            }
            np.append(p)
        }
        // Keep the friction basis stable across frames when the normal barely changes.
        if normal.dot(m.normal) < 0.99 || t1 == .zero {
            normal = m.normal
            t1 = normal.anyPerpendicular
            t2 = normal.cross(t1)
            for i in np.indices { np[i].tangentImpulse = .zero }
        } else {
            normal = m.normal
            t1 = (t1 - normal * normal.dot(t1)).normalized
            t2 = normal.cross(t1)
        }
        points = np
        touching = isTrigger ? !points.isEmpty : points.contains { $0.separation <= 0.0001 }
    }

    func isActive(_ bodies: [Body3D?]) -> Bool {
        guard !isTrigger, !points.isEmpty, let a = bodies[bodyA], let b = bodies[bodyB] else { return false }
        return (a.isAwake && a.type != .static) || (b.isAwake && b.type != .static)
    }

    static func effectiveMass(_ a: Body3D, _ b: Body3D, _ rA: Vec3, _ rB: Vec3, _ dir: Vec3) -> Float {
        let ra = rA.cross(dir), rb = rB.cross(dir)
        let k = a.invMass + b.invMass + ra.dot(a.invInertiaWorld * ra) + rb.dot(b.invInertiaWorld * rb)
        return k > 0 ? 1 / k : 0
    }

    mutating func prepare(_ bodies: [Body3D?], settings: SolverSettings, invDt: Float) {
        let a = bodies[bodyA]!, b = bodies[bodyB]!
        let ca = a.worldCenter, cb = b.worldCenter
        for i in points.indices {
            var p = points[i]
            p.rA = p.point - ca
            p.rB = p.point - cb
            p.normalMass = Contact3D.effectiveMass(a, b, p.rA, p.rB, normal)
            p.tangentMass = Vec2(Contact3D.effectiveMass(a, b, p.rA, p.rB, t1), Contact3D.effectiveMass(a, b, p.rA, p.rB, t2))
            p.bias = p.separation > 0
                ? -p.separation * invDt
                : settings.baumgarte * invDt * Swift.max(0, -(p.separation + settings.linearSlop))
            let vn = (b.velocity(at: p.point) - a.velocity(at: p.point)).dot(normal)
            p.restitutionBias = vn < -settings.restitutionThreshold ? -restitution * vn : 0
            if !settings.warmStarting {
                p.normalImpulse = 0
                p.tangentImpulse = .zero
            }
            points[i] = p
        }
    }

    func apply(_ bodies: inout [Body3D?], _ p: Point, _ impulse: Vec3) {
        if bodies[bodyA]!.type == .dynamic {
            bodies[bodyA]!.linearVelocity -= impulse * bodies[bodyA]!.invMass
            bodies[bodyA]!.angularVelocity -= bodies[bodyA]!.invInertiaWorld * p.rA.cross(impulse)
        }
        if bodies[bodyB]!.type == .dynamic {
            bodies[bodyB]!.linearVelocity += impulse * bodies[bodyB]!.invMass
            bodies[bodyB]!.angularVelocity += bodies[bodyB]!.invInertiaWorld * p.rB.cross(impulse)
        }
    }

    func warmStart(_ bodies: inout [Body3D?]) {
        for p in points { apply(&bodies, p, normal * p.normalImpulse + t1 * p.tangentImpulse.x + t2 * p.tangentImpulse.y) }
    }

    func relativeVelocity(_ bodies: [Body3D?], _ p: Point) -> Vec3 {
        let a = bodies[bodyA]!, b = bodies[bodyB]!
        return (b.linearVelocity + b.angularVelocity.cross(p.rB)) - (a.linearVelocity + a.angularVelocity.cross(p.rA))
    }

    mutating func solve(_ bodies: inout [Body3D?]) {
        for i in points.indices {
            var p = points[i]
            let dv = relativeVelocity(bodies, p)
            let maxF = friction * p.normalImpulse
            var newT = p.tangentImpulse - Vec2(p.tangentMass.x * dv.dot(t1), p.tangentMass.y * dv.dot(t2))
            // Circular friction cone.
            let l = newT.length
            if l > maxF && l > 0 { newT *= maxF / l }
            let delta = newT - p.tangentImpulse
            p.tangentImpulse = newT
            apply(&bodies, p, t1 * delta.x + t2 * delta.y)
            points[i] = p
        }
        for i in points.indices {
            var p = points[i]
            let vn = relativeVelocity(bodies, p).dot(normal)
            let target = Swift.max(p.bias, p.restitutionBias)
            let newImpulse = Swift.max(p.normalImpulse - p.normalMass * (vn - target), 0)
            let delta = newImpulse - p.normalImpulse
            p.normalImpulse = newImpulse
            apply(&bodies, p, normal * delta)
            points[i] = p
        }
    }
}

// MARK: - Joints

struct JointState3D {
    enum Kind { case ball, hinge, fixed, distance }
    var kind: Kind
    var bodyA: Int
    var bodyB: Int
    var localAnchorA: Vec3
    var localAnchorB: Vec3
    var collideConnected = false
    var localAxisA = Vec3.up
    var localAxisB = Vec3.up
    var relativeRotation = Quat.identity
    var motorEnabled = false
    var motorSpeed: Float = 0
    var maxMotorTorque: Float = 0
    var minLength: Float = 0
    var maxLength: Float = 0

    // Solver state
    var rA = Vec3.zero, rB = Vec3.zero
    var linearImpulse = Vec3.zero
    var angularImpulse = Vec3.zero
    var motorImpulse: Float = 0
    var axialImpulse: Float = 0
    var lowerImpulse: Float = 0
    var upperImpulse: Float = 0
    var linearMass = Mat3.zero
    var positionBias = Vec3.zero
    var angularBias = Vec3.zero
    var angularMass = Mat3.zero
    var hingeAxis = Vec3.up
    var perp1 = Vec3.right, perp2 = Vec3(0, 0, 1)
    var axis = Vec3.zero
    var axialMass: Float = 0
    var currentLength: Float = 0
    var baumgarte: Float = 0.2
    var invDt: Float = 60

    init?(_ d: JointDesc3D, world: PhysicsWorld3D) {
        switch d {
        case let .ball(a, b, anchor):
            guard let ba = world.body(a), let bb = world.body(b) else { return nil }
            kind = .ball
            bodyA = Int(a.index)
            bodyB = Int(b.index)
            localAnchorA = ba.pose.invApply(anchor)
            localAnchorB = bb.pose.invApply(anchor)
        case let .hinge(a, b, anchor, axis, motor):
            guard let ba = world.body(a), let bb = world.body(b) else { return nil }
            kind = .hinge
            bodyA = Int(a.index)
            bodyB = Int(b.index)
            localAnchorA = ba.pose.invApply(anchor)
            localAnchorB = bb.pose.invApply(anchor)
            localAxisA = ba.pose.invRotate(axis.normalized)
            localAxisB = bb.pose.invRotate(axis.normalized)
            if let motor {
                motorEnabled = true
                motorSpeed = motor.speed
                maxMotorTorque = motor.maxTorque
            }
        case let .fixed(a, b):
            guard let ba = world.body(a), let bb = world.body(b) else { return nil }
            kind = .fixed
            bodyA = Int(a.index)
            bodyB = Int(b.index)
            let mid = (ba.position + bb.position) * 0.5
            localAnchorA = ba.pose.invApply(mid)
            localAnchorB = bb.pose.invApply(mid)
            relativeRotation = ba.rotation.conjugate * bb.rotation
        case let .distance(a, b, anchorA, anchorB, minL, maxL):
            guard let ba = world.body(a), let bb = world.body(b) else { return nil }
            kind = .distance
            bodyA = Int(a.index)
            bodyB = Int(b.index)
            localAnchorA = ba.pose.invApply(anchorA)
            localAnchorB = bb.pose.invApply(anchorB)
            let rest = max(0.005, (anchorB - anchorA).length)
            minLength = max(0.005, minL ?? rest)
            maxLength = max(minLength, maxL ?? rest)
            collideConnected = true
        }
    }

    /// K = (mA + mB) I - [rA]× IA⁻¹ [rA]× - [rB]× IB⁻¹ [rB]× for a point constraint.
    static func pointMass(_ a: Body3D, _ b: Body3D, _ rA: Vec3, _ rB: Vec3) -> Mat3 {
        let sa = Mat3.skew(rA), sb = Mat3.skew(rB)
        let m = a.invMass + b.invMass
        var k = Mat3(diagonal: Vec3(repeating: m))
        k = k + (sa * a.invInertiaWorld * sa) * -1
        k = k + (sb * b.invInertiaWorld * sb) * -1
        return k.inverse
    }

    mutating func prepare(_ bodies: [Body3D?], dt: Float, settings: SolverSettings) {
        guard let a = bodies[bodyA], let b = bodies[bodyB] else { return }
        baumgarte = settings.baumgarte
        invDt = 1 / dt
        rA = a.rotation.act(localAnchorA - a.localCenter)
        rB = b.rotation.act(localAnchorB - b.localCenter)
        let pA = a.worldCenter + rA, pB = b.worldCenter + rB
        switch kind {
        case .ball, .hinge, .fixed:
            linearMass = JointState3D.pointMass(a, b, rA, rB)
            positionBias = (pB - pA) * (baumgarte * invDt)
            let iSum = a.invInertiaWorld + b.invInertiaWorld
            angularMass = iSum.inverse
            if kind == .hinge {
                let axA = a.rotation.act(localAxisA), axB = b.rotation.act(localAxisB)
                hingeAxis = axA
                perp1 = axA.anyPerpendicular
                perp2 = axA.cross(perp1)
                // Misalignment of B's axis relative to A's, projected on the perpendicular plane.
                angularBias = axA.cross(axB) * (baumgarte * invDt)
                if !motorEnabled { motorImpulse = 0 }
            } else if kind == .fixed {
                // Rotation error: q_err = qB * (qA * qRel)⁻¹, as a small-angle vector.
                let target = a.rotation * relativeRotation
                var qe = b.rotation * target.conjugate
                if qe.w < 0 { qe = Quat(-qe.vector) }
                angularBias = qe.imaginary * (2 * baumgarte * invDt)
            }
        case .distance:
            let d = pB - pA
            currentLength = d.length
            axis = currentLength > 1e-6 ? d / currentLength : .up
            let ra = rA.cross(axis), rb = rB.cross(axis)
            let k = a.invMass + b.invMass + ra.dot(a.invInertiaWorld * ra) + rb.dot(b.invInertiaWorld * rb)
            axialMass = k > 0 ? 1 / k : 0
        }
    }

    func applyLinear(_ bodies: inout [Body3D?], _ p: Vec3) {
        if bodies[bodyA]!.type == .dynamic {
            bodies[bodyA]!.linearVelocity -= p * bodies[bodyA]!.invMass
            bodies[bodyA]!.angularVelocity -= bodies[bodyA]!.invInertiaWorld * rA.cross(p)
        }
        if bodies[bodyB]!.type == .dynamic {
            bodies[bodyB]!.linearVelocity += p * bodies[bodyB]!.invMass
            bodies[bodyB]!.angularVelocity += bodies[bodyB]!.invInertiaWorld * rB.cross(p)
        }
    }

    func applyAngular(_ bodies: inout [Body3D?], _ j: Vec3) {
        if bodies[bodyA]!.type == .dynamic { bodies[bodyA]!.angularVelocity -= bodies[bodyA]!.invInertiaWorld * j }
        if bodies[bodyB]!.type == .dynamic { bodies[bodyB]!.angularVelocity += bodies[bodyB]!.invInertiaWorld * j }
    }

    func warmStart(_ bodies: inout [Body3D?]) {
        guard bodies[bodyA] != nil, bodies[bodyB] != nil else { return }
        switch kind {
        case .ball:
            applyLinear(&bodies, linearImpulse)
        case .hinge:
            applyLinear(&bodies, linearImpulse)
            applyAngular(&bodies, angularImpulse + hingeAxis * motorImpulse)
        case .fixed:
            applyLinear(&bodies, linearImpulse)
            applyAngular(&bodies, angularImpulse)
        case .distance:
            applyLinear(&bodies, axis * (axialImpulse + lowerImpulse - upperImpulse))
        }
    }

    func limitBias(_ c: Float) -> Float { c > 0 ? c * invDt : baumgarte * c * invDt }

    mutating func solve(_ bodies: inout [Body3D?], dt: Float) {
        guard bodies[bodyA] != nil, bodies[bodyB] != nil else { return }
        func pointVelocity() -> Vec3 {
            let a = bodies[bodyA]!, b = bodies[bodyB]!
            return (b.linearVelocity + b.angularVelocity.cross(rB)) - (a.linearVelocity + a.angularVelocity.cross(rA))
        }
        func relativeAngular() -> Vec3 { bodies[bodyB]!.angularVelocity - bodies[bodyA]!.angularVelocity }

        switch kind {
        case .ball, .hinge, .fixed:
            if kind == .hinge {
                if motorEnabled {
                    let wa = hingeAxis.dot(relativeAngular())
                    let k = hingeAxis.dot((bodies[bodyA]!.invInertiaWorld + bodies[bodyB]!.invInertiaWorld) * hingeAxis)
                    let mass: Float = k > 0 ? 1 / k : 0
                    let maxImpulse = maxMotorTorque * dt
                    let old = motorImpulse
                    motorImpulse = (motorImpulse - mass * (wa - motorSpeed)).clamped(-maxImpulse, maxImpulse)
                    applyAngular(&bodies, hingeAxis * (motorImpulse - old))
                }
                // Two angular constraints perpendicular to the hinge axis.
                for dir in [perp1, perp2] {
                    let k = dir.dot((bodies[bodyA]!.invInertiaWorld + bodies[bodyB]!.invInertiaWorld) * dir)
                    guard k > 0 else { continue }
                    let cdot = dir.dot(relativeAngular())
                    let lambda = -(cdot + dir.dot(angularBias)) / k
                    angularImpulse += dir * lambda
                    applyAngular(&bodies, dir * lambda)
                }
            } else if kind == .fixed {
                let rhs = -(relativeAngular() + angularBias)
                let lambda = angularMass * rhs
                angularImpulse += lambda
                applyAngular(&bodies, lambda)
            }
            let rhs = -(pointVelocity() + positionBias)
            let lambda = linearMass * rhs
            linearImpulse += lambda
            applyLinear(&bodies, lambda)
        case .distance:
            if minLength == maxLength {
                let lambda = -axialMass * (axis.dot(pointVelocity()) + baumgarte * (currentLength - minLength) * invDt)
                axialImpulse += lambda
                applyLinear(&bodies, axis * lambda)
            } else {
                do {
                    let lambda = -axialMass * (axis.dot(pointVelocity()) + limitBias(currentLength - minLength))
                    let newImpulse = Swift.max(lowerImpulse + lambda, 0)
                    applyLinear(&bodies, axis * (newImpulse - lowerImpulse))
                    lowerImpulse = newImpulse
                }
                do {
                    let lambda = -axialMass * (-axis.dot(pointVelocity()) + limitBias(maxLength - currentLength))
                    let newImpulse = Swift.max(upperImpulse + lambda, 0)
                    applyLinear(&bodies, axis * -(newImpulse - upperImpulse))
                    upperImpulse = newImpulse
                }
            }
        }
    }
}
