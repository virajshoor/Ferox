import Foundation
import FeroxCore

/// Construction parameters for a 2D body.
public struct BodyDesc2D: Sendable {
    public var type: BodyType = .dynamic
    public var position: Vec2 = .zero
    public var angle: Float = 0
    public var linearVelocity: Vec2 = .zero
    public var angularVelocity: Float = 0
    public var linearDamping: Float = 0
    public var angularDamping: Float = 0.05
    public var gravityScale: Float = 1
    public var fixedRotation = false
    public var allowSleep = true
    public var userData: UInt64 = 0
    public var shapes: [Shape2D] = []
    public init(type: BodyType = .dynamic, position: Vec2 = .zero, angle: Float = 0, shapes: [Shape2D] = []) {
        self.type = type
        self.position = position
        self.angle = angle
        self.shapes = shapes
    }
}

/// Simulation state of a 2D rigid body. Read through `PhysicsWorld2D.body(_:)`; mutate via
/// the world's API so that mass, sleep state and broadphase stay consistent.
public struct Body2D: Sendable {
    public internal(set) var type: BodyType
    public internal(set) var position: Vec2
    public internal(set) var angle: Float
    public internal(set) var linearVelocity: Vec2
    public internal(set) var angularVelocity: Float
    /// Pose at the start of the last step (for render interpolation).
    public internal(set) var previousPosition: Vec2
    public internal(set) var previousAngle: Float
    public internal(set) var shapes: [Shape2D]
    public internal(set) var mass: Float = 0
    public internal(set) var inertia: Float = 0
    public internal(set) var localCenter: Vec2 = .zero
    public internal(set) var isAwake = true
    public var linearDamping: Float
    public var angularDamping: Float
    public var gravityScale: Float
    public internal(set) var fixedRotation: Bool
    public var allowSleep: Bool
    public var userData: UInt64

    var invMass: Float = 0
    var invInertia: Float = 0
    var force: Vec2 = .zero
    var torque: Float = 0
    var sleepTime: Float = 0
    var aabbMin: Vec2 = .zero
    var aabbMax: Vec2 = .zero

    public var transform: Transform2D { Transform2D(position: position, angle: angle) }
    /// World-space centre of mass.
    public var worldCenter: Vec2 { transform.apply(localCenter) }

    /// Interpolated pose between the previous and current step.
    public func interpolated(_ alpha: Float) -> (position: Vec2, angle: Float) {
        (previousPosition.lerp(to: position, alpha), Float.lerp(previousAngle, angle, alpha))
    }

    /// Velocity of a world point attached to the body.
    public func velocity(at worldPoint: Vec2) -> Vec2 {
        let r = worldPoint - worldCenter
        return linearVelocity + Vec2(-angularVelocity * r.y, angularVelocity * r.x)
    }
}

public struct RaycastHit2D: Sendable {
    public var body: BodyID
    public var shape: Int
    public var point: Vec2
    public var normal: Vec2
    public var fraction: Float
    public var distance: Float
    public var userData: UInt64
}

/// Joint definitions.
public enum JointDesc2D: Sendable {
    /// Pins two bodies together at a world anchor; optional motor and angle limits.
    case revolute(a: BodyID, b: BodyID, anchor: Vec2, motor: (speed: Float, maxTorque: Float)? = nil,
                  limits: ClosedRange<Float>? = nil)
    /// Keeps the anchors at `length`; `frequency` > 0 makes it a spring; `minLength`/`maxLength`
    /// turn it into a rope/slider range.
    case distance(a: BodyID, b: BodyID, anchorA: Vec2, anchorB: Vec2, length: Float? = nil, frequency: Float = 0,
                  dampingRatio: Float = 0.7, minLength: Float? = nil, maxLength: Float? = nil)
    /// Soft constraint pulling a body point towards a world target (editor dragging, grabbing).
    case target(body: BodyID, anchor: Vec2, target: Vec2, maxForce: Float, frequency: Float = 5, dampingRatio: Float = 0.7)
}

/// A 2D rigid-body physics world.
///
/// Algorithm summary (see Docs/13-Physics.md):
/// - Broadphase: sort-and-sweep on X with temporal coherence.
/// - Narrowphase: analytic circle/capsule tests, SAT + reference-face clipping for polygons,
///   producing up to two contact points with feature ids.
/// - Solver: sequential impulses with warm starting, Coulomb friction, restitution with a
///   velocity threshold, Baumgarte stabilisation with slop, and speculative contacts.
/// - Sleeping: union-find islands over contacts/joints.
///
/// Limitations: no continuous collision detection (fast thin objects may tunnel; keep
/// `maxTranslation` and the step size reasonable), polygons are convex (≤16 vertices).
public final class PhysicsWorld2D {
    public var gravity = Vec2(0, -9.81)
    public var settings = SolverSettings()
    public private(set) var stepCount: UInt64 = 0

    var bodies: [Body2D?] = []
    var generations: [UInt32] = []
    var freeBodies: [UInt32] = []
    var contacts: [UInt64: Contact2D] = [:]
    var joints: [JointState2D?] = []
    var jointGenerations: [UInt32] = []
    var broadphase = SweepAndPrune()
    var broadphaseDirty = true
    /// Scratch buffer reused each step for the broadphase input (avoids a per-step allocation).
    private var broadphaseItems: [(id: Int, minX: Float, maxX: Float)] = []

    /// Contact and trigger events produced by the last `step`.
    public private(set) var contactEvents: [ContactEvent<Vec2>] = []
    /// Called for each event during `step` (after solving). Prefer reading `contactEvents`.
    public var onContact: ((ContactEvent<Vec2>) -> Void)?

    public init(gravity: Vec2 = Vec2(0, -9.81)) { self.gravity = gravity }

    // MARK: Bodies

    @discardableResult
    public func createBody(_ d: BodyDesc2D) -> BodyID {
        let b = Body2D(
            type: d.type, position: d.position, angle: d.angle, linearVelocity: d.linearVelocity,
            angularVelocity: d.angularVelocity, previousPosition: d.position, previousAngle: d.angle, shapes: d.shapes,
            linearDamping: d.linearDamping, angularDamping: d.angularDamping, gravityScale: d.gravityScale,
            fixedRotation: d.fixedRotation, allowSleep: d.allowSleep, userData: d.userData)
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
        // Emit end events for touching contacts and remove contacts/joints referencing the body.
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

    public func body(_ id: BodyID) -> Body2D? { isValid(id) ? bodies[Int(id.index)] : nil }

    public var bodyCount: Int { bodies.count - freeBodies.count }

    /// All live body ids.
    public var bodyIDs: [BodyID] {
        bodies.indices.compactMap { i in bodies[i] == nil ? nil : BodyID(index: UInt32(i), generation: generations[i]) }
    }

    private func mutate(_ id: BodyID, wake: Bool = true, _ f: (inout Body2D) -> Void) {
        guard isValid(id) else { return }
        let i = Int(id.index)
        f(&bodies[i]!)
        if wake { bodies[i]!.isAwake = true; bodies[i]!.sleepTime = 0 }
    }

    public func setTransform(_ id: BodyID, position: Vec2, angle: Float, resetInterpolation: Bool = false) {
        mutate(id) { b in
            b.position = position
            b.angle = angle
            if resetInterpolation {
                b.previousPosition = position
                b.previousAngle = angle
            }
        }
        if isValid(id) { updateAABB(Int(id.index)) }
    }
    public func setLinearVelocity(_ id: BodyID, _ v: Vec2) { mutate(id) { $0.linearVelocity = v } }
    public func setAngularVelocity(_ id: BodyID, _ w: Float) { mutate(id) { $0.angularVelocity = w } }
    public func applyForce(_ id: BodyID, _ f: Vec2, at point: Vec2? = nil) {
        mutate(id) { b in
            b.force += f
            if let point { b.torque += (point - b.worldCenter).cross(f) }
        }
    }
    public func applyTorque(_ id: BodyID, _ t: Float) { mutate(id) { $0.torque += t } }
    public func applyLinearImpulse(_ id: BodyID, _ j: Vec2, at point: Vec2? = nil) {
        mutate(id) { b in
            b.linearVelocity += j * b.invMass
            if let point { b.angularVelocity += b.invInertia * (point - b.worldCenter).cross(j) }
        }
    }
    public func applyAngularImpulse(_ id: BodyID, _ j: Float) { mutate(id) { $0.angularVelocity += $0.invInertia * j } }
    public func setType(_ id: BodyID, _ t: BodyType) {
        mutate(id) { $0.type = t }
        if isValid(id) { recomputeMass(Int(id.index)) }
    }
    public func setShapes(_ id: BodyID, _ shapes: [Shape2D]) {
        mutate(id) { $0.shapes = shapes }
        guard isValid(id) else { return }
        let i = Int(id.index)
        for (k, c) in contacts where c.bodyA == i || c.bodyB == i { contacts[k] = nil }
        recomputeMass(i)
        updateAABB(i)
    }
    public func setFixedRotation(_ id: BodyID, _ fixed: Bool) {
        mutate(id) { $0.fixedRotation = fixed }
        if isValid(id) { recomputeMass(Int(id.index)) }
    }
    public func setDamping(_ id: BodyID, linear: Float, angular: Float) {
        mutate(id, wake: false) {
            $0.linearDamping = linear
            $0.angularDamping = angular
        }
    }
    public func setGravityScale(_ id: BodyID, _ s: Float) { mutate(id) { $0.gravityScale = s } }
    public func wake(_ id: BodyID) { mutate(id) { _ in } }

    func recomputeMass(_ i: Int) {
        var b = bodies[i]!
        b.mass = 0
        b.inertia = 0
        b.invMass = 0
        b.invInertia = 0
        b.localCenter = .zero
        if b.type == .dynamic {
            var m: Float = 0, c = Vec2.zero, inertia: Float = 0
            for s in b.shapes where !s.isTrigger {
                let md = s.massData()
                m += md.mass
                c += md.center * md.mass
                inertia += md.inertia
            }
            if m > 0 {
                c /= m
                b.mass = m
                b.invMass = 1 / m
                b.localCenter = c
                // Shift inertia to the centre of mass.
                inertia -= m * c.lengthSquared
                if inertia > 0 && !b.fixedRotation {
                    b.inertia = inertia
                    b.invInertia = 1 / inertia
                }
            } else {
                b.mass = 1
                b.invMass = 1
            }
        }
        bodies[i] = b
    }

    func updateAABB(_ i: Int) {
        guard var b = bodies[i] else { return }
        let xf = b.transform
        var lo = Vec2(repeating: .infinity), hi = Vec2(repeating: -.infinity)
        for s in b.shapes {
            let (a, c) = s.aabb(xf)
            lo = pointwiseMin(lo, a)
            hi = pointwiseMax(hi, c)
        }
        if b.shapes.isEmpty { lo = b.position; hi = b.position }
        let m = settings.speculativeDistance
        b.aabbMin = lo - m
        b.aabbMax = hi + m
        bodies[i] = b
    }

    // MARK: Joints

    @discardableResult
    public func createJoint(_ d: JointDesc2D) -> JointID? {
        guard let j = JointState2D(d, world: self) else { return nil }
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

    /// Updates the target of a `.target` joint.
    public func setJointTarget(_ id: JointID, _ target: Vec2) {
        let i = Int(id.index)
        guard i < joints.count, jointGenerations[i] == id.generation else { return }
        joints[i]?.target = target
        if let j = joints[i] { wakeBody(j.bodyB) }
    }

    /// Sets the motor speed of a revolute joint.
    public func setMotorSpeed(_ id: JointID, _ speed: Float) {
        let i = Int(id.index)
        guard i < joints.count, jointGenerations[i] == id.generation else { return }
        joints[i]?.motorSpeed = speed
        if let j = joints[i] {
            wakeBody(j.bodyA)
            wakeBody(j.bodyB)
        }
    }

    func wakeBody(_ i: Int) {
        guard i >= 0, i < bodies.count, bodies[i] != nil else { return }
        bodies[i]!.isAwake = true
        bodies[i]!.sleepTime = 0
    }

    // MARK: Step

    /// Advances the simulation by `dt` seconds (call with a fixed step).
    public func step(_ dt: Float) {
        guard dt > 0 else { return }
        stepCount &+= 1
        contactEvents.removeAll(keepingCapacity: true)
        let n = bodies.count

        // 1. Integrate velocities.
        for i in 0..<n {
            guard var b = bodies[i] else { continue }
            b.previousPosition = b.position
            b.previousAngle = b.angle
            if b.type == .dynamic && b.isAwake {
                b.linearVelocity += dt * (gravity * b.gravityScale + b.force * b.invMass)
                b.angularVelocity += dt * b.invInertia * b.torque
                b.linearVelocity *= 1 / (1 + dt * b.linearDamping)
                b.angularVelocity *= 1 / (1 + dt * b.angularDamping)
            }
            b.force = .zero
            b.torque = 0
            bodies[i] = b
        }

        // 2. Collision detection.
        updateContacts()

        // 3. Solve.
        // Sorted so the solve order (and therefore the result) is deterministic.
        // Single pass over the dictionary (no per-key re-lookup); sorted for a stable order.
        var active: [UInt64] = []
        active.reserveCapacity(contacts.count)
        for (k, c) in contacts where c.isActive(bodies) { active.append(k) }
        active.sort()
        let inv = 1 / dt
        for k in active { contacts[k]!.prepare(&bodies, settings: settings, invDt: inv) }
        for j in joints.indices { joints[j]?.prepare(&bodies, dt: dt, settings: settings) }
        if settings.warmStarting {
            for k in active { contacts[k]!.warmStart(&bodies) }
            for j in joints.indices { joints[j]?.warmStart(&bodies) }
        }
        for _ in 0..<max(1, settings.velocityIterations) {
            for j in joints.indices { joints[j]?.solve(&bodies, dt: dt) }
            for k in active { contacts[k]!.solve(&bodies) }
        }

        // 4. Integrate positions.
        for i in 0..<n {
            guard var b = bodies[i], b.type != .static, b.isAwake else { continue }
            var dp = b.linearVelocity * dt
            if dp.lengthSquared > settings.maxTranslation * settings.maxTranslation {
                dp *= settings.maxTranslation / dp.length
                b.linearVelocity = dp * inv
            }
            var da = b.angularVelocity * dt
            if Swift.abs(da) > settings.maxRotation {
                da = da < 0 ? -settings.maxRotation : settings.maxRotation
                b.angularVelocity = da * inv
            }
            // Integrate about the centre of mass.
            let oldCenter = b.worldCenter
            b.angle += da
            let newCenter = oldCenter + dp
            b.position = newCenter - Transform2D(position: .zero, angle: b.angle).rotate(b.localCenter)
            bodies[i] = b
        }
        for i in 0..<n where bodies[i] != nil { updateAABB(i) }

        // 5. Sleep.
        if settings.allowSleep { updateSleep(dt) }

        // 6. Dispatch events.
        if let onContact { for e in contactEvents { onContact(e) } }
    }

    private func shapeKey(_ body: Int, _ shape: Int) -> Int { (body << 8) | (shape & 0xFF) }

    func updateContacts() {
        let n = bodies.count
        broadphaseItems.removeAll(keepingCapacity: true)
        broadphaseItems.reserveCapacity(n)
        for i in 0..<n {
            if let b = bodies[i] { broadphaseItems.append((i, b.aabbMin.x, b.aabbMax.x)) }
        }
        broadphase.update(broadphaseItems, rebuild: broadphaseDirty)
        broadphaseDirty = false

        var seen = Set<UInt64>()
        seen.reserveCapacity(contacts.count)
        broadphase.forEachOverlap { ia, ib in
            guard let a = bodies[ia], let b = bodies[ib] else { return }
            if a.type != .dynamic && b.type != .dynamic {
                // Kinematic/static pairs only matter for triggers.
                if !(a.shapes.contains { $0.isTrigger } || b.shapes.contains { $0.isTrigger }) { return }
            }
            if !a.isAwake && !b.isAwake {
                // Keep existing contacts alive so sleeping stacks remain stable.
                for (k, c) in contacts where (c.bodyA == ia && c.bodyB == ib) || (c.bodyA == ib && c.bodyB == ia) {
                    seen.insert(k)
                }
                return
            }
            guard a.aabbMin.y <= b.aabbMax.y && b.aabbMin.y <= a.aabbMax.y else { return }
            guard !jointsDisableCollision(ia, ib) else { return }
            let xa = a.transform, xb = b.transform
            for (sa, shapeA) in a.shapes.enumerated() {
                let (alo, ahi) = shapeA.aabb(xa)
                for (sb, shapeB) in b.shapes.enumerated() {
                    guard shapeA.filter.shouldCollide(with: shapeB.filter) else { continue }
                    let (blo, bhi) = shapeB.aabb(xb)
                    let m = settings.speculativeDistance
                    guard alo.x - m <= bhi.x && blo.x - m <= ahi.x && alo.y - m <= bhi.y && blo.y - m <= ahi.y else { continue }
                    let key = pairKey(shapeKey(ia, sa), shapeKey(ib, sb))
                    // Normalise ordering so A is always the lower shape key.
                    let flip = shapeKey(ia, sa) > shapeKey(ib, sb)
                    let (bi, bj, si, sj) = flip ? (ib, ia, sb, sa) : (ia, ib, sa, sb)
                    let (s1, s2) = flip ? (shapeB, shapeA) : (shapeA, shapeB)
                    let (x1, x2) = flip ? (xb, xa) : (xa, xb)
                    let trigger = s1.isTrigger || s2.isTrigger
                    var manifold: Manifold2D
                    if trigger {
                        manifold = Collide2D.manifold(s1, x1, s2, x2, margin: 0)
                    } else {
                        manifold = Collide2D.manifold(s1, x1, s2, x2, margin: settings.speculativeDistance)
                    }
                    seen.insert(key)
                    var c = contacts[key] ?? Contact2D(bodyA: bi, bodyB: bj, shapeA: si, shapeB: sj, isTrigger: trigger)
                    c.friction = PhysicsMaterial.mixFriction(s1.material.friction, s2.material.friction)
                    c.restitution = PhysicsMaterial.mixRestitution(s1.material.restitution, s2.material.restitution)
                    let wasTouching = c.touching
                    c.update(manifold)
                    if c.touching && !wasTouching {
                        emitBegin(c)
                        // Contact with an awake body wakes a sleeping one.
                        if !(bodies[bi]!.isAwake) { wakeBody(bi) }
                        if !(bodies[bj]!.isAwake) { wakeBody(bj) }
                    } else if !c.touching && wasTouching {
                        emitEnd(c)
                    }
                    contacts[key] = c
                }
            }
        }
        // Remove stale contacts (AABBs no longer overlapping).
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

    func bodyID(_ i: Int) -> BodyID { BodyID(index: UInt32(i), generation: generations[i]) }

    func emitBegin(_ c: Contact2D) {
        let ba = bodies[c.bodyA]!, bb = bodies[c.bodyB]!
        contactEvents.append(
            ContactEvent(
                phase: .began, bodyA: bodyID(c.bodyA), bodyB: bodyID(c.bodyB), shapeA: c.shapeA, shapeB: c.shapeB,
                userDataA: ba.userData, userDataB: bb.userData, isTrigger: c.isTrigger,
                points: c.isTrigger ? [] : c.points.map(\.point), normal: c.normal,
                normalImpulse: c.points.reduce(0) { $0 + $1.normalImpulse }))
    }

    func emitEnd(_ c: Contact2D) {
        let ua = bodies[c.bodyA]?.userData ?? 0, ub = bodies[c.bodyB]?.userData ?? 0
        contactEvents.append(
            ContactEvent(
                phase: .ended, bodyA: bodyID(c.bodyA), bodyB: bodyID(c.bodyB), shapeA: c.shapeA, shapeB: c.shapeB,
                userDataA: ua, userDataB: ub, isTrigger: c.isTrigger, points: [], normal: c.normal, normalImpulse: 0))
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
                if !b.allowSleep || b.linearVelocity.lengthSquared > lin2 || b.angularVelocity * b.angularVelocity > ang2 {
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
            if islandAwake[root] == true {
                if (minSleep[root] ?? 0) >= settings.timeToSleep {
                    b.isAwake = false
                    b.linearVelocity = .zero
                    b.angularVelocity = 0
                } else if !b.isAwake {
                    // Island contains an active body: wake the whole island.
                    b.isAwake = true
                    b.sleepTime = 0
                }
                bodies[i] = b
            }
        }
    }

    // MARK: Queries

    /// Closest hit along the segment `from → to`.
    public func raycast(from: Vec2, to: Vec2, filter: CollisionFilter = .default, includeTriggers: Bool = false) -> RaycastHit2D? {
        var best: RaycastHit2D?
        raycastAll(from: from, to: to, filter: filter, includeTriggers: includeTriggers) { hit in
            if hit.fraction < (best?.fraction ?? .infinity) { best = hit }
            return true
        }
        return best
    }

    /// Visits every hit; return false from `visit` to stop.
    public func raycastAll(
        from: Vec2, to: Vec2, filter: CollisionFilter = .default, includeTriggers: Bool = false, radius: Float = 0,
        _ visit: (RaycastHit2D) -> Bool
    ) {
        let d = to - from
        let lo = pointwiseMin(from, to) - radius, hi = pointwiseMax(from, to) + radius
        let length = d.length
        for i in bodies.indices {
            guard let b = bodies[i], b.aabbMin.x <= hi.x, b.aabbMax.x >= lo.x, b.aabbMin.y <= hi.y, b.aabbMax.y >= lo.y else {
                continue
            }
            let xf = b.transform
            for (si, s) in b.shapes.enumerated() {
                if s.isTrigger && !includeTriggers { continue }
                guard filter.shouldCollide(with: s.filter) else { continue }
                if let rh = Collide2D.raycast(s, xf, origin: from, delta: d, inflate: radius) {
                    let (t, n) = rh
                    let hit = RaycastHit2D(
                        body: bodyID(i), shape: si, point: from + d * t - n * radius, normal: n, fraction: t,
                        distance: t * length, userData: b.userData)
                    if !visit(hit) { return }
                }
            }
        }
    }

    /// Circle sweep (shape cast). Returns the first time of impact.
    public func circleCast(from: Vec2, to: Vec2, radius: Float, filter: CollisionFilter = .default) -> RaycastHit2D? {
        var best: RaycastHit2D?
        raycastAll(from: from, to: to, filter: filter, radius: radius) { hit in
            if hit.fraction < (best?.fraction ?? .infinity) { best = hit }
            return true
        }
        return best
    }

    /// Bodies with a shape containing `point`.
    public func overlapPoint(_ point: Vec2, filter: CollisionFilter = .default) -> [BodyID] {
        var out: [BodyID] = []
        for i in bodies.indices {
            guard let b = bodies[i] else { continue }
            let xf = b.transform
            if b.shapes.contains(where: { filter.shouldCollide(with: $0.filter) && Collide2D.contains($0, xf, point) }) {
                out.append(bodyID(i))
            }
        }
        return out
    }

    /// Bodies whose AABB overlaps the box.
    public func overlapAABB(min lo: Vec2, max hi: Vec2) -> [BodyID] {
        bodies.indices.compactMap { i in
            guard let b = bodies[i], b.aabbMin.x <= hi.x, b.aabbMax.x >= lo.x,
                b.aabbMin.y <= hi.y, b.aabbMax.y >= lo.y
            else { return nil }
            return bodyID(i)
        }
    }

    /// Bodies with a shape overlapping a circle.
    public func overlapCircle(center: Vec2, radius: Float, filter: CollisionFilter = .default) -> [BodyID] {
        let probe = Shape2D.circle(radius: radius)
        let px = Transform2D(position: center, angle: 0)
        return overlapAABB(min: center - radius, max: center + radius).filter { id in
            guard let b = body(id) else { return false }
            let xf = b.transform
            return b.shapes.contains { s in
                filter.shouldCollide(with: s.filter)
                    && !Collide2D.manifold(probe, px, s, xf, margin: 0).points.filter { $0.separation <= 0 }.isEmpty
            }
        }
    }

    /// Contacts currently touching `id`.
    public func contacts(of id: BodyID) -> [(other: BodyID, normal: Vec2, points: [Vec2])] {
        let i = Int(id.index)
        return contacts.values.compactMap { c in
            guard c.touching, c.bodyA == i || c.bodyB == i else { return nil }
            let other = c.bodyA == i ? c.bodyB : c.bodyA
            return (bodyID(other), c.bodyA == i ? c.normal : -c.normal, c.points.map(\.point))
        }
    }

    public var activeContactCount: Int { contacts.values.filter(\.touching).count }

    // MARK: Debug draw

    public func debugLines(includeContacts: Bool = true, includeAABBs: Bool = false) -> [DebugLine<Vec2>] {
        var lines: [DebugLine<Vec2>] = []
        for i in bodies.indices {
            guard let b = bodies[i] else { continue }
            let xf = b.transform
            for s in b.shapes {
                let kind: DebugLine<Vec2>.Kind =
                    s.isTrigger ? .trigger : (b.type == .static ? .staticCollider : (b.isAwake ? .collider : .sleeping))
                switch s.geometry {
                case .circle(let c, let r):
                    let center = xf.apply(c)
                    let segs = 24
                    for k in 0..<segs {
                        let a0 = Float(k) / Float(segs) * 2 * .pi, a1 = Float(k + 1) / Float(segs) * 2 * .pi
                        lines.append(DebugLine(a: center + Vec2(cos(a0), sin(a0)) * r, b: center + Vec2(cos(a1), sin(a1)) * r, kind: kind))
                    }
                    lines.append(DebugLine(a: center, b: center + xf.rotate(Vec2(r, 0)), kind: kind))
                case .polygon(let p):
                    let v = p.vertices.map(xf.apply)
                    for k in v.indices { lines.append(DebugLine(a: v[k], b: v[(k + 1) % v.count], kind: kind)) }
                case .capsule(let a, let bb, let r):
                    let wa = xf.apply(a), wb = xf.apply(bb)
                    let n = (wb - wa).perpendicular.normalized * r
                    lines.append(DebugLine(a: wa + n, b: wb + n, kind: kind))
                    lines.append(DebugLine(a: wa - n, b: wb - n, kind: kind))
                    for (c, dir) in [(wa, Float(1)), (wb, Float(-1))] {
                        let base = atan2(n.y, n.x)
                        for k in 0..<8 {
                            let a0 = base + dir * Float(k) / 8 * .pi, a1 = base + dir * Float(k + 1) / 8 * .pi
                            lines.append(DebugLine(a: c + Vec2(cos(a0), sin(a0)) * r, b: c + Vec2(cos(a1), sin(a1)) * r, kind: kind))
                        }
                    }
                }
            }
            if includeAABBs {
                let lo = b.aabbMin, hi = b.aabbMax
                let corners = [lo, Vec2(hi.x, lo.y), hi, Vec2(lo.x, hi.y)]
                for k in 0..<4 { lines.append(DebugLine(a: corners[k], b: corners[(k + 1) % 4], kind: .aabb)) }
            }
        }
        if includeContacts {
            for c in contacts.values where c.touching && !c.isTrigger {
                for p in c.points {
                    lines.append(DebugLine(a: p.point - Vec2(0.05, 0), b: p.point + Vec2(0.05, 0), kind: .contact))
                    lines.append(DebugLine(a: p.point, b: p.point + c.normal * 0.3, kind: .contactNormal))
                }
            }
        }
        for j in joints {
            guard let j, let a = bodies[j.bodyA], let b = bodies[j.bodyB] else { continue }
            lines.append(DebugLine(a: a.transform.apply(j.localAnchorA), b: b.transform.apply(j.localAnchorB), kind: .joint))
        }
        return lines
    }
}

// MARK: - Contact constraint

struct Contact2D {
    struct Point {
        var point: Vec2
        var separation: Float
        var id: UInt32
        var normalImpulse: Float = 0
        var tangentImpulse: Float = 0
        var rA = Vec2.zero, rB = Vec2.zero
        var normalMass: Float = 0, tangentMass: Float = 0
        var bias: Float = 0
        var restitutionBias: Float = 0
    }
    var bodyA: Int, bodyB: Int, shapeA: Int, shapeB: Int
    var isTrigger: Bool
    var normal = Vec2.zero
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

    mutating func update(_ m: Manifold2D) {
        var newPoints: [Point] = []
        newPoints.reserveCapacity(m.points.count)
        for mp in m.points {
            var p = Point(point: mp.point, separation: mp.separation, id: mp.id)
            // Warm-start: carry accumulated impulses for matching features.
            if let old = points.first(where: { $0.id == mp.id }) {
                p.normalImpulse = old.normalImpulse
                p.tangentImpulse = old.tangentImpulse
            }
            newPoints.append(p)
        }
        points = newPoints
        normal = m.normal
        touching = isTrigger ? !points.isEmpty : points.contains { $0.separation <= 0.0001 }
    }

    func isActive(_ bodies: [Body2D?]) -> Bool {
        guard !isTrigger, !points.isEmpty, let a = bodies[bodyA], let b = bodies[bodyB] else { return false }
        return (a.isAwake && a.type != .static) || (b.isAwake && b.type != .static)
    }

    mutating func prepare(_ bodies: inout [Body2D?], settings: SolverSettings, invDt: Float) {
        let a = bodies[bodyA]!, b = bodies[bodyB]!
        let ca = a.worldCenter, cb = b.worldCenter
        let t = Vec2(normal.y, -normal.x)
        for i in points.indices {
            var p = points[i]
            p.rA = p.point - ca
            p.rB = p.point - cb
            let rnA = p.rA.cross(normal), rnB = p.rB.cross(normal)
            let kN = a.invMass + b.invMass + a.invInertia * rnA * rnA + b.invInertia * rnB * rnB
            p.normalMass = kN > 0 ? 1 / kN : 0
            let rtA = p.rA.cross(t), rtB = p.rB.cross(t)
            let kT = a.invMass + b.invMass + a.invInertia * rtA * rtA + b.invInertia * rtB * rtB
            p.tangentMass = kT > 0 ? 1 / kT : 0
            if p.separation > 0 {
                // Speculative: allow closing exactly the gap this step.
                p.bias = -p.separation * invDt
            } else {
                p.bias = settings.baumgarte * invDt * Swift.max(0, -(p.separation + settings.linearSlop))
            }
            let dv = b.velocity(at: p.point) - a.velocity(at: p.point)
            let vn = dv.dot(normal)
            p.restitutionBias = vn < -settings.restitutionThreshold ? -restitution * vn : 0
            if !settings.warmStarting {
                p.normalImpulse = 0
                p.tangentImpulse = 0
            }
            points[i] = p
        }
    }

    func applyImpulse(_ bodies: inout [Body2D?], _ p: Point, _ impulse: Vec2) {
        if bodies[bodyA]!.type == .dynamic {
            bodies[bodyA]!.linearVelocity -= impulse * bodies[bodyA]!.invMass
            bodies[bodyA]!.angularVelocity -= bodies[bodyA]!.invInertia * p.rA.cross(impulse)
        }
        if bodies[bodyB]!.type == .dynamic {
            bodies[bodyB]!.linearVelocity += impulse * bodies[bodyB]!.invMass
            bodies[bodyB]!.angularVelocity += bodies[bodyB]!.invInertia * p.rB.cross(impulse)
        }
    }

    func warmStart(_ bodies: inout [Body2D?]) {
        let t = Vec2(normal.y, -normal.x)
        for p in points { applyImpulse(&bodies, p, normal * p.normalImpulse + t * p.tangentImpulse) }
    }

    func relativeVelocity(_ bodies: [Body2D?], _ p: Point) -> Vec2 {
        let a = bodies[bodyA]!, b = bodies[bodyB]!
        let va = a.linearVelocity + Vec2(-a.angularVelocity * p.rA.y, a.angularVelocity * p.rA.x)
        let vb = b.linearVelocity + Vec2(-b.angularVelocity * p.rB.y, b.angularVelocity * p.rB.x)
        return vb - va
    }

    mutating func solve(_ bodies: inout [Body2D?]) {
        let t = Vec2(normal.y, -normal.x)
        // Friction first (uses the previous normal impulse as the bound), then normal.
        for i in points.indices {
            var p = points[i]
            let vt = relativeVelocity(bodies, p).dot(t)
            let maxF = friction * p.normalImpulse
            let newImpulse = (p.tangentImpulse - p.tangentMass * vt).clamped(-maxF, maxF)
            let delta = newImpulse - p.tangentImpulse
            p.tangentImpulse = newImpulse
            applyImpulse(&bodies, p, t * delta)
            points[i] = p
        }
        for i in points.indices {
            var p = points[i]
            let vn = relativeVelocity(bodies, p).dot(normal)
            let target = Swift.max(p.bias, p.restitutionBias)
            let newImpulse = Swift.max(p.normalImpulse - p.normalMass * (vn - target), 0)
            let delta = newImpulse - p.normalImpulse
            p.normalImpulse = newImpulse
            applyImpulse(&bodies, p, normal * delta)
            points[i] = p
        }
    }
}

// MARK: - Joints

struct JointState2D {
    enum Kind { case revolute, distance, target }
    var kind: Kind
    var bodyA: Int
    var bodyB: Int
    var localAnchorA: Vec2
    var localAnchorB: Vec2
    var collideConnected = false
    // Revolute
    var motorSpeed: Float = 0
    var maxMotorTorque: Float = 0
    var motorEnabled = false
    var limits: ClosedRange<Float>?
    var referenceAngle: Float = 0
    // Distance
    var length: Float = 1
    var minLength: Float = 0
    var maxLength: Float = 0
    var frequency: Float = 0
    var dampingRatio: Float = 0.7
    // Target
    var target: Vec2 = .zero
    var maxForce: Float = 0

    // Solver state
    var impulse = Vec2.zero
    var axialImpulse: Float = 0
    var motorImpulse: Float = 0
    var lowerImpulse: Float = 0
    var upperImpulse: Float = 0
    var rA = Vec2.zero, rB = Vec2.zero
    var axis = Vec2.zero
    var axialMass: Float = 0
    var springMass: Float = 0
    var gamma: Float = 0
    var bias = Vec2.zero
    var springBias: Float = 0
    var currentLength: Float = 0
    var jointAngle: Float = 0
    var kInv = (Vec2.zero, Vec2.zero)
    var baumgarte: Float = 0.2
    var invDt: Float = 60

    init?(_ d: JointDesc2D, world: PhysicsWorld2D) {
        switch d {
        case let .revolute(a, b, anchor, motor, limits):
            guard let ba = world.body(a), let bb = world.body(b) else { return nil }
            kind = .revolute
            bodyA = Int(a.index)
            bodyB = Int(b.index)
            localAnchorA = ba.transform.invApply(anchor)
            localAnchorB = bb.transform.invApply(anchor)
            referenceAngle = bb.angle - ba.angle
            if let motor {
                motorEnabled = true
                motorSpeed = motor.speed
                maxMotorTorque = motor.maxTorque
            }
            self.limits = limits
        case let .distance(a, b, anchorA, anchorB, length, frequency, dampingRatio, minLength, maxLength):
            guard let ba = world.body(a), let bb = world.body(b) else { return nil }
            kind = .distance
            bodyA = Int(a.index)
            bodyB = Int(b.index)
            localAnchorA = ba.transform.invApply(anchorA)
            localAnchorB = bb.transform.invApply(anchorB)
            let rest = max(0.005, length ?? (anchorB - anchorA).length)
            self.length = rest
            self.frequency = max(0, frequency)
            self.dampingRatio = dampingRatio
            self.minLength = max(0.005, min(minLength ?? rest, rest))
            self.maxLength = max(maxLength ?? rest, rest)
            collideConnected = true
        case let .target(b, anchor, target, maxForce, frequency, dampingRatio):
            guard let bb = world.body(b) else { return nil }
            kind = .target
            // Target joints act on a single body; bodyA aliases bodyB and is never modified.
            bodyA = Int(b.index)
            bodyB = Int(b.index)
            localAnchorA = .zero
            localAnchorB = bb.transform.invApply(anchor)
            self.target = target
            self.maxForce = maxForce
            self.frequency = max(0.1, frequency)
            self.dampingRatio = dampingRatio
            collideConnected = true
        }
    }

    /// Soft-constraint coefficients (E. Catto, "Soft Constraints", GDC 2011):
    /// returns (gamma, beta) for an effective `mass`, spring `frequency` (Hz) and damping ratio.
    static func soft(mass: Float, frequency: Float, damping: Float, dt: Float) -> (gamma: Float, beta: Float) {
        let omega = 2 * Float.pi * frequency
        let c = 2 * mass * damping * omega
        let k = mass * omega * omega
        let g = dt * (c + dt * k)
        let gamma = g > 0 ? 1 / g : 0
        return (gamma, dt * k * gamma)
    }

    mutating func prepare(_ bodies: inout [Body2D?], dt: Float, settings: SolverSettings) {
        guard let a = bodies[bodyA], let b = bodies[bodyB] else { return }
        baumgarte = settings.baumgarte
        invDt = 1 / dt
        rA = a.transform.rotate(localAnchorA - a.localCenter)
        rB = b.transform.rotate(localAnchorB - b.localCenter)
        let mA = a.invMass, mB = b.invMass, iA = a.invInertia, iB = b.invInertia
        switch kind {
        case .revolute:
            let k11 = mA + mB + iA * rA.y * rA.y + iB * rB.y * rB.y
            let k12 = -iA * rA.x * rA.y - iB * rB.x * rB.y
            let k22 = mA + mB + iA * rA.x * rA.x + iB * rB.x * rB.x
            var det = k11 * k22 - k12 * k12
            if det != 0 { det = 1 / det }
            kInv = (Vec2(det * k22, -det * k12), Vec2(-det * k12, det * k11))
            let c = (b.worldCenter + rB) - (a.worldCenter + rA)
            bias = c * (settings.baumgarte * invDt)
            let iSum = iA + iB
            axialMass = iSum > 0 ? 1 / iSum : 0
            jointAngle = b.angle - a.angle - referenceAngle
            if !motorEnabled { motorImpulse = 0 }
            if limits == nil {
                lowerImpulse = 0
                upperImpulse = 0
            }
        case .distance:
            let d = (b.worldCenter + rB) - (a.worldCenter + rA)
            currentLength = d.length
            axis = currentLength > 1e-6 ? d / currentLength : Vec2(1, 0)
            let crA = rA.cross(axis), crB = rB.cross(axis)
            let k = mA + mB + iA * crA * crA + iB * crB * crB
            axialMass = k > 0 ? 1 / k : 0
            if frequency > 0 {
                let s = JointState2D.soft(mass: axialMass, frequency: frequency, damping: dampingRatio, dt: dt)
                gamma = s.gamma
                springBias = (currentLength - length) * s.beta
                springMass = k + gamma > 0 ? 1 / (k + gamma) : 0
            } else {
                gamma = 0
                springBias = 0
                springMass = 0
            }
        case .target:
            let s = JointState2D.soft(mass: b.mass, frequency: frequency, damping: dampingRatio, dt: dt)
            gamma = s.gamma
            let k11 = mB + iB * rB.y * rB.y + gamma
            let k12 = -iB * rB.x * rB.y
            let k22 = mB + iB * rB.x * rB.x + gamma
            var det = k11 * k22 - k12 * k12
            if det != 0 { det = 1 / det }
            kInv = (Vec2(det * k22, -det * k12), Vec2(-det * k12, det * k11))
            bias = ((b.worldCenter + rB) - target) * s.beta
        }
    }

    func applyPair(_ bodies: inout [Body2D?], _ p: Vec2) {
        if kind != .target && bodies[bodyA]!.type == .dynamic {
            bodies[bodyA]!.linearVelocity -= p * bodies[bodyA]!.invMass
            bodies[bodyA]!.angularVelocity -= bodies[bodyA]!.invInertia * rA.cross(p)
        }
        if bodies[bodyB]!.type == .dynamic {
            bodies[bodyB]!.linearVelocity += p * bodies[bodyB]!.invMass
            bodies[bodyB]!.angularVelocity += bodies[bodyB]!.invInertia * rB.cross(p)
        }
    }

    func applyAngular(_ bodies: inout [Body2D?], _ j: Float) {
        if bodies[bodyA]!.type == .dynamic { bodies[bodyA]!.angularVelocity -= bodies[bodyA]!.invInertia * j }
        if bodies[bodyB]!.type == .dynamic { bodies[bodyB]!.angularVelocity += bodies[bodyB]!.invInertia * j }
    }

    func warmStart(_ bodies: inout [Body2D?]) {
        guard bodies[bodyA] != nil, bodies[bodyB] != nil else { return }
        switch kind {
        case .revolute:
            applyPair(&bodies, impulse)
            applyAngular(&bodies, motorImpulse + lowerImpulse - upperImpulse)
        case .distance:
            applyPair(&bodies, axis * (axialImpulse + lowerImpulse - upperImpulse))
        case .target:
            applyPair(&bodies, impulse)
        }
    }

    static func pointVelocity(_ b: Body2D, _ r: Vec2) -> Vec2 {
        b.linearVelocity + Vec2(-b.angularVelocity * r.y, b.angularVelocity * r.x)
    }

    /// Bias for a one-sided limit with position error `c` (positive = inside the allowed range):
    /// speculative when separated, Baumgarte-corrected when violated.
    func limitBias(_ c: Float) -> Float { c > 0 ? c * invDt : baumgarte * c * invDt }

    mutating func solve(_ bodies: inout [Body2D?], dt: Float) {
        guard bodies[bodyA] != nil, bodies[bodyB] != nil else { return }
        switch kind {
        case .revolute:
            if motorEnabled {
                let wRel = bodies[bodyB]!.angularVelocity - bodies[bodyA]!.angularVelocity
                let maxImpulse = maxMotorTorque * dt
                let old = motorImpulse
                motorImpulse = (motorImpulse - axialMass * (wRel - motorSpeed)).clamped(-maxImpulse, maxImpulse)
                applyAngular(&bodies, motorImpulse - old)
            }
            if let limits {
                // Lower limit: angle >= lower.
                do {
                    let wRel = bodies[bodyB]!.angularVelocity - bodies[bodyA]!.angularVelocity
                    let lambda = -axialMass * (wRel + limitBias(jointAngle - limits.lowerBound))
                    let newImpulse = Swift.max(lowerImpulse + lambda, 0)
                    applyAngular(&bodies, newImpulse - lowerImpulse)
                    lowerImpulse = newImpulse
                }
                // Upper limit: angle <= upper.
                do {
                    let wRel = bodies[bodyA]!.angularVelocity - bodies[bodyB]!.angularVelocity
                    let lambda = -axialMass * (wRel + limitBias(limits.upperBound - jointAngle))
                    let newImpulse = Swift.max(upperImpulse + lambda, 0)
                    applyAngular(&bodies, -(newImpulse - upperImpulse))
                    upperImpulse = newImpulse
                }
            }
            let cdot = JointState2D.pointVelocity(bodies[bodyB]!, rB) - JointState2D.pointVelocity(bodies[bodyA]!, rA)
            let rhs = -(cdot + bias)
            let lambda = kInv.0 * rhs.x + kInv.1 * rhs.y
            impulse += lambda
            applyPair(&bodies, lambda)
        case .distance:
            func axialVelocity() -> Float {
                axis.dot(JointState2D.pointVelocity(bodies[bodyB]!, rB) - JointState2D.pointVelocity(bodies[bodyA]!, rA))
            }
            if frequency > 0 {
                // Soft spring towards the rest length.
                let lambda = -springMass * (axialVelocity() + springBias + gamma * axialImpulse)
                axialImpulse += lambda
                applyPair(&bodies, axis * lambda)
            } else if minLength == maxLength {
                // Rigid rod.
                let c = currentLength - length
                let lambda = -axialMass * (axialVelocity() + baumgarte * c * invDt)
                axialImpulse += lambda
                applyPair(&bodies, axis * lambda)
            }
            if minLength < maxLength {
                // Lower bound: length >= minLength (push apart).
                do {
                    let lambda = -axialMass * (axialVelocity() + limitBias(currentLength - minLength))
                    let newImpulse = Swift.max(lowerImpulse + lambda, 0)
                    applyPair(&bodies, axis * (newImpulse - lowerImpulse))
                    lowerImpulse = newImpulse
                }
                // Upper bound: length <= maxLength (pull together).
                do {
                    let lambda = -axialMass * (-axialVelocity() + limitBias(maxLength - currentLength))
                    let newImpulse = Swift.max(upperImpulse + lambda, 0)
                    applyPair(&bodies, axis * -(newImpulse - upperImpulse))
                    upperImpulse = newImpulse
                }
            }
        case .target:
            let cdot = JointState2D.pointVelocity(bodies[bodyB]!, rB)
            let rhs = -(cdot + bias + gamma * impulse)
            var lambda = kInv.0 * rhs.x + kInv.1 * rhs.y
            let old = impulse
            impulse += lambda
            let maxImpulse = maxForce * dt
            if impulse.lengthSquared > maxImpulse * maxImpulse { impulse *= maxImpulse / impulse.length }
            lambda = impulse - old
            applyPair(&bodies, lambda)
        }
    }
}
