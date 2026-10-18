import FeroxCore
import FeroxScene
import Foundation

/// Particle emitter configuration (serializable). Simulation runs on the CPU in
/// `ParticleSystem`, or on the GPU in the renderer when `simulation == .gpu`.
public struct ParticleEmitter: SerializableComponent, Hashable, Sendable {
    public enum Shape: Codable, Hashable, Sendable {
        case point
        case sphere(radius: Float, surfaceOnly: Bool)
        case hemisphere(radius: Float)
        case box(extents: Vec3)
        /// Cone opening along local +Y with half-angle in radians and base radius.
        case cone(angle: Float, radius: Float)
        /// Circle in the local XY plane (2D effects).
        case circle(radius: Float)
        /// Line segment along local X.
        case edge(length: Float)
    }
    public enum Simulation: String, Codable, Sendable { case cpu, gpu }
    public enum Space: String, Codable, Sendable { case world, local }
    public enum RenderMode: String, Codable, Sendable { case billboard, stretched, horizontal }
    public struct Burst: Codable, Hashable, Sendable {
        public var time: Float
        public var count: Int
        public init(time: Float, count: Int) {
            self.time = time
            self.count = count
        }
    }

    public var isEmitting = true
    public var maxParticles = 1000
    /// Particles per second.
    public var rate: Float = 50
    public var bursts: [Burst] = []
    /// Emitter cycle duration (bursts repeat each cycle when looping).
    public var duration: Float = 5
    public var loops = true
    public var lifetime: ClosedRange<Float> = 1...2
    public var startSpeed: ClosedRange<Float> = 1...3
    public var startSize: ClosedRange<Float> = 0.1...0.2
    public var startRotation: ClosedRange<Float> = 0...0
    public var angularVelocity: ClosedRange<Float> = 0...0
    public var shape: Shape = .cone(angle: 0.4, radius: 0.1)
    public var gravity: Vec3 = .zero
    /// Linear drag coefficient (per second).
    public var drag: Float = 0
    /// Turbulence strength (pseudo-curl noise).
    public var turbulence: Float = 0
    public var turbulenceFrequency: Float = 1
    public var sizeOverLifetime: AnimationCurve<Float> = AnimationCurve(keys: [.init(0, 1), .init(1, 1)])
    public var colorOverLifetime: Gradient = Gradient(.white, Color.white.withAlpha(0))
    public var speedOverLifetime: AnimationCurve<Float> = AnimationCurve(keys: [.init(0, 1), .init(1, 1)])
    /// Optional ground-plane collision at this world height with restitution.
    public var collisionPlaneY: Float?
    public var bounce: Float = 0.3
    public var simulation: Simulation = .cpu
    public var space: Space = .world
    public var renderMode: RenderMode = .billboard
    public var texture: AssetID?
    /// Flipbook sheet layout (columns, rows) and playback speed in frames per second.
    public var sheetGrid: IVec2Codable = IVec2Codable(1, 1)
    public var sheetFPS: Float = 0
    public var blend: SpriteBlendMode = .additive
    public var sortingLayer = 0
    public var seed: UInt64 = 1
    public init() {}
}

/// Codable integer pair.
public struct IVec2Codable: Codable, Hashable, Sendable {
    public var x: Int, y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
}

/// Structure-of-arrays particle storage. A reference type so emitters can be updated in
/// place without copy-on-write traffic through the ECS.
public final class ParticlePool: @unchecked Sendable {
    public private(set) var count = 0
    public let capacity: Int
    public var positions: [Vec3]
    public var velocities: [Vec3]
    public var ages: [Float]
    public var lifetimes: [Float]
    public var sizes: [Float]
    public var rotations: [Float]
    public var angularVelocities: [Float]
    public var seeds: [Float]

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        positions = .init(repeating: .zero, count: self.capacity)
        velocities = .init(repeating: .zero, count: self.capacity)
        ages = .init(repeating: 0, count: self.capacity)
        lifetimes = .init(repeating: 1, count: self.capacity)
        sizes = .init(repeating: 0, count: self.capacity)
        rotations = .init(repeating: 0, count: self.capacity)
        angularVelocities = .init(repeating: 0, count: self.capacity)
        seeds = .init(repeating: 0, count: self.capacity)
    }

    @discardableResult
    func spawn(position: Vec3, velocity: Vec3, lifetime: Float, size: Float, rotation: Float, angular: Float, seed: Float) -> Bool {
        guard count < capacity else { return false }
        let i = count
        positions[i] = position
        velocities[i] = velocity
        ages[i] = 0
        lifetimes[i] = max(lifetime, 1e-3)
        sizes[i] = size
        rotations[i] = rotation
        angularVelocities[i] = angular
        seeds[i] = seed
        count += 1
        return true
    }

    func kill(_ i: Int) {
        let last = count - 1
        if i != last {
            positions[i] = positions[last]
            velocities[i] = velocities[last]
            ages[i] = ages[last]
            lifetimes[i] = lifetimes[last]
            sizes[i] = sizes[last]
            rotations[i] = rotations[last]
            angularVelocities[i] = angularVelocities[last]
            seeds[i] = seeds[last]
        }
        count -= 1
    }

    public func removeAll() { count = 0 }
}

/// Runtime emitter state (not serialized).
public struct ParticleState: Component, Sendable {
    public let pool: ParticlePool
    public internal(set) var time: Float = 0
    var emitAccumulator: Float = 0
    var rng: PCG32
    /// For GPU emitters: number of particles the renderer should spawn this frame.
    public internal(set) var pendingGPUSpawn = 0
    /// World matrix of the emitter when particles are simulated in local space.
    public internal(set) var emitterMatrix: Mat4 = .identity
    public init(capacity: Int, seed: UInt64) {
        pool = ParticlePool(capacity: capacity)
        rng = PCG32(seed: seed)
    }
}

/// CPU particle simulation (spawning, forces, collisions, ageing).
public final class ParticleSystem: System {
    public var phase: SystemPhase { .lateUpdate }
    public var order: Int { 50 }
    public var runsInEditMode: Bool { true }
    public init() {}

    public func update(world: World, context: SystemContext) {
        var missing: [(Entity, ParticleEmitter)] = []
        world.read(ParticleEmitter.self) { e, em in
            if world.get(ParticleState.self, e)?.pool.capacity != em.maxParticles { missing.append((e, em)) }
        }
        for (e, em) in missing { world.add(ParticleState(capacity: em.maxParticles, seed: em.seed), to: e) }

        let dt = context.dt
        world.forEach(ParticleEmitter.self, ParticleState.self) { e, em, st in
            guard world.isActiveInHierarchy(e) else { return }
            let m = world.get(WorldTransform.self, e)?.matrix ?? world.worldMatrix(of: e)
            st.emitterMatrix = m
            let previousTime = st.time
            st.time += dt
            if em.loops && em.duration > 0 && st.time > em.duration {
                st.time = st.time.truncatingRemainder(dividingBy: em.duration)
            }
            // Spawn count from rate and bursts.
            var spawn = 0
            if em.isEmitting && (em.loops || previousTime < em.duration) {
                st.emitAccumulator += em.rate * dt
                spawn = Int(st.emitAccumulator)
                st.emitAccumulator -= Float(spawn)
                for b in em.bursts {
                    let crossed = st.time >= previousTime ? (b.time > previousTime && b.time <= st.time)
                        : (b.time > previousTime || b.time <= st.time)
                    if crossed || (previousTime == 0 && b.time == 0) { spawn += b.count }
                }
            }
            if em.simulation == .gpu {
                st.pendingGPUSpawn = spawn
                return
            }
            ParticleSystem.simulate(em, &st, spawn: spawn, dt: dt, emitterMatrix: m)
        }
    }

    /// Spawns and integrates particles. Exposed for tests and offline previews.
    public static func simulate(_ em: ParticleEmitter, _ st: inout ParticleState, spawn: Int, dt: Float, emitterMatrix m: Mat4) {
        let pool = st.pool
        for _ in 0..<spawn {
            let (lp, ldir) = sampleShape(em.shape, &st.rng)
            var pos = lp, vel = ldir * st.rng.nextFloat(in: em.startSpeed)
            if em.space == .world {
                pos = m.transformAffine(lp)
                vel = m.transformDirection(vel)
            }
            pool.spawn(
                position: pos, velocity: vel, lifetime: st.rng.nextFloat(in: em.lifetime),
                size: st.rng.nextFloat(in: em.startSize), rotation: st.rng.nextFloat(in: em.startRotation),
                angular: st.rng.nextFloat(in: em.angularVelocity), seed: st.rng.nextFloat())
        }
        let dragFactor = 1 / (1 + em.drag * dt)
        var i = 0
        while i < pool.count {
            pool.ages[i] += dt
            if pool.ages[i] >= pool.lifetimes[i] {
                pool.kill(i)
                continue
            }
            var v = pool.velocities[i]
            v += em.gravity * dt
            if em.turbulence > 0 {
                let p = pool.positions[i] * em.turbulenceFrequency
                let s = pool.seeds[i] * 10
                let n = Vec3(sin(p.y * 1.7 + s) + cos(p.z * 2.3), sin(p.z * 1.3 + s) + cos(p.x * 1.9), sin(p.x * 2.1 + s) + cos(p.y * 1.1))
                v += n * (em.turbulence * dt)
            }
            v *= dragFactor
            pool.velocities[i] = v
            let lifeT = pool.ages[i] / pool.lifetimes[i]
            let speedMul = em.speedOverLifetime.sample(lifeT) ?? 1
            pool.positions[i] += v * (speedMul * dt)
            pool.rotations[i] += pool.angularVelocities[i] * dt
            if let y = em.collisionPlaneY, pool.positions[i].y < y {
                pool.positions[i].y = y
                if pool.velocities[i].y < 0 { pool.velocities[i].y = -pool.velocities[i].y * em.bounce }
            }
            i += 1
        }
    }

    /// Initial state of one particle spawned on the GPU.
    public struct Spawn: Sendable, Hashable {
        public var position: Vec3
        public var velocity: Vec3
        public var lifetime: Float
        public var size: Float
        public var rotation: Float
        public var angularVelocity: Float
    }

    /// Generates the particles a GPU emitter requested this frame (`pendingGPUSpawn`) and
    /// clears the request. Shapes and random ranges match the CPU path exactly; the
    /// renderer uploads the result and the GPU integrates it.
    public static func takeGPUSpawns(_ em: ParticleEmitter, _ st: inout ParticleState) -> [Spawn] {
        let n = min(st.pendingGPUSpawn, max(em.maxParticles, 0))
        st.pendingGPUSpawn = 0
        guard n > 0 else { return [] }
        let m = st.emitterMatrix
        var out: [Spawn] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let (lp, ldir) = sampleShape(em.shape, &st.rng)
            var pos = lp, vel = ldir * st.rng.nextFloat(in: em.startSpeed)
            if em.space == .world {
                pos = m.transformAffine(lp)
                vel = m.transformDirection(vel)
            }
            out.append(Spawn(
                position: pos, velocity: vel, lifetime: st.rng.nextFloat(in: em.lifetime),
                size: st.rng.nextFloat(in: em.startSize), rotation: st.rng.nextFloat(in: em.startRotation),
                angularVelocity: st.rng.nextFloat(in: em.angularVelocity)))
        }
        return out
    }

    static func sampleShape(_ s: ParticleEmitter.Shape, _ rng: inout PCG32) -> (Vec3, Vec3) {
        switch s {
        case .point:
            return (.zero, rng.nextUnitVector())
        case let .sphere(r, surface):
            let d = rng.nextUnitVector()
            let rad = surface ? r : r * pow(rng.nextFloat(), 1 / 3)
            return (d * rad, d)
        case .hemisphere(let r):
            var d = rng.nextUnitVector()
            d.y = Swift.abs(d.y)
            return (d * r * pow(rng.nextFloat(), 1 / 3), d)
        case .box(let e):
            let p = Vec3(rng.nextFloat(in: -1...1), rng.nextFloat(in: -1...1), rng.nextFloat(in: -1...1)) * e
            return (p, .up)
        case let .cone(angle, radius):
            let disc = rng.nextInUnitDisc()
            let base = Vec3(disc.x, 0, disc.y) * radius
            let a = rng.nextFloat() * angle
            let phi = rng.nextFloat() * 2 * .pi
            let dir = Vec3(sin(a) * cos(phi), cos(a), sin(a) * sin(phi))
            return (base, dir)
        case .circle(let r):
            let disc = rng.nextInUnitDisc()
            let p = Vec3(disc.x, disc.y, 0) * r
            let d = Vec3(disc.x, disc.y, 0)
            return (p, d.lengthSquared > 1e-6 ? d.normalized : Vec3(0, 1, 0))
        case .edge(let length):
            return (Vec3(rng.nextFloat(in: -0.5...0.5) * length, 0, 0), .up)
        }
    }
}

// MARK: - Trails

/// Ribbon trail behind a moving entity.
public struct TrailRenderer: SerializableComponent, Hashable, Sendable {
    /// Seconds a point lives.
    public var lifetime: Float = 0.5
    /// Minimum distance moved before a new point is added.
    public var minVertexDistance: Float = 0.05
    public var widthOverLifetime: AnimationCurve<Float> = AnimationCurve(keys: [.init(0, 0.2), .init(1, 0)])
    public var color: Gradient = Gradient(.white, Color.white.withAlpha(0))
    public var texture: AssetID?
    public var blend: SpriteBlendMode = .additive
    public var maxPoints = 128
    public init() {}
}

public final class TrailBuffer: @unchecked Sendable {
    public var points: [Vec3] = []
    public var times: [Float] = []
    public init() {}
}

public struct TrailState: Component, Sendable {
    public let buffer = TrailBuffer()
    public internal(set) var clock: Float = 0
    public init() {}
}

public final class TrailSystem: System {
    public var phase: SystemPhase { .lateUpdate }
    public var order: Int { 60 }
    public init() {}

    public func update(world: World, context: SystemContext) {
        var missing: [Entity] = []
        world.read(TrailRenderer.self) { e, _ in if !world.has(TrailState.self, e) { missing.append(e) } }
        for e in missing { world.add(TrailState(), to: e) }
        world.forEach(TrailRenderer.self, TrailState.self) { e, tr, st in
            st.clock += context.dt
            let b = st.buffer
            let p = world.worldMatrix(of: e).translation
            // Expire old points.
            let cutoff = st.clock - tr.lifetime
            var drop = 0
            while drop < b.times.count && b.times[drop] < cutoff { drop += 1 }
            if drop > 0 {
                b.points.removeFirst(drop)
                b.times.removeFirst(drop)
            }
            // The last point is a "head" that follows the entity; it is committed (a new head
            // appended) once it is far enough from the previous committed point.
            if b.points.count >= 2, (p - b.points[b.points.count - 2]).length < tr.minVertexDistance {
                b.points[b.points.count - 1] = p
                b.times[b.times.count - 1] = st.clock
            } else {
                b.points.append(p)
                b.times.append(st.clock)
                if b.points.count > tr.maxPoints {
                    b.points.removeFirst()
                    b.times.removeFirst()
                }
            }
        }
    }
}
