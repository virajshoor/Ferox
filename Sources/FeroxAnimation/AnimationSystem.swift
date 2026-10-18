import FeroxCore
import FeroxScene
import Foundation

/// Registry of clips and skeletons available to animation systems (populated by the asset
/// system when models/clips load, or directly by game code). Stored as a world resource.
public final class AnimationLibrary {
    public private(set) var clips: [AssetID: AnimationClip] = [:]
    public private(set) var skeletons: [AssetID: Skeleton] = [:]
    public private(set) var timelines: [AssetID: Timeline] = [:]
    public init() {}
    public func add(_ clip: AnimationClip) { clips[clip.id] = clip }
    public func add(_ skeleton: Skeleton, id: AssetID) { skeletons[id] = skeleton }
    public func add(_ timeline: Timeline) { timelines[timeline.id] = timeline }
    public func clip(_ id: AssetID) -> AnimationClip? { clips[id] }
    public func clip(named name: String) -> AnimationClip? { clips.values.first { $0.name == name } }
}

/// Value produced by sampling a channel, before blending.
enum SampledValue {
    case vec3(Vec3), quat(Quat), float(Float), color(Color)

    func blended(with o: SampledValue, _ w: Float) -> SampledValue {
        switch (self, o) {
        case let (.vec3(a), .vec3(b)): return .vec3(a.lerp(to: b, w))
        case let (.quat(a), .quat(b)): return .quat(a.nlerp(to: b, w))
        case let (.float(a), .float(b)): return .float(Float.lerp(a, b, w))
        case let (.color(a), .color(b)): return .color(a.lerp(to: b, w))
        default: return w < 0.5 ? self : o
        }
    }
}

struct ChannelKey: Hashable {
    var path: String
    var target: ChannelTarget
}

/// Evaluates `Animator` components: state machines, cross-fades, 1D blend trees, events,
/// and writes results to joint/child transforms, materials and sprites.
///
/// Runs in `.lateUpdate` with order -100, i.e. before transform propagation, so animated
/// transforms are visible to rendering in the same frame.
public final class AnimationSystem: System {
    public var phase: SystemPhase { .lateUpdate }
    public var order: Int { -100 }
    public var isEnabled = true
    public let library: AnimationLibrary
    private var pathCache: [Entity: [String: Entity]] = [:]
    private var cacheVersion: UInt64 = .max

    public init(library: AnimationLibrary = AnimationLibrary()) { self.library = library }
    public func attach(world: World) { world.setResource(library) }

    func duration(of state: AnimatorState) -> Float {
        if let c = state.clip { return library.clip(c)?.duration ?? 0 }
        return state.blendTree.compactMap { library.clip($0.clip)?.duration }.max() ?? 0
    }

    func sample(_ clip: AnimationClip, _ time: Float) -> [ChannelKey: SampledValue] {
        let t = clip.localTime(time)
        var out: [ChannelKey: SampledValue] = [:]
        out.reserveCapacity(clip.channels.count)
        for ch in clip.channels {
            let k = ChannelKey(path: ch.path, target: ch.target)
            if let v = ch.vec3?.sample(t) { out[k] = .vec3(v) }
            else if let q = ch.quat?.sample(t) { out[k] = .quat(q) }
            else if let f = ch.float?.sample(t) { out[k] = .float(f) }
            else if let c = ch.color?.sample(t) { out[k] = .color(c) }
        }
        return out
    }

    static func blend(_ a: [ChannelKey: SampledValue], _ b: [ChannelKey: SampledValue], _ w: Float) -> [ChannelKey: SampledValue] {
        var out = a
        for (k, vb) in b {
            if let va = a[k] { out[k] = va.blended(with: vb, w) } else { out[k] = vb }
        }
        return out
    }

    func sampleState(_ state: AnimatorState, time: Float, params: [String: AnimatorParameter]) -> [ChannelKey: SampledValue] {
        if let id = state.clip, let clip = library.clip(id) { return sample(clip, time) }
        guard !state.blendTree.isEmpty else { return [:] }
        var x: Float = 0
        if let p = state.blendParameter, case .float(let f)? = params[p] { x = f }
        let pts = state.blendTree
        if x <= pts[0].threshold || pts.count == 1 {
            return library.clip(pts[0].clip).map { sample($0, time) } ?? [:]
        }
        for i in 1..<pts.count where x <= pts[i].threshold {
            let a = pts[i - 1], b = pts[i]
            let w = (x - a.threshold) / max(b.threshold - a.threshold, 1e-6)
            // Normalised time keeps clips of different lengths in phase (walk/run sync).
            guard let ca = library.clip(a.clip), let cb = library.clip(b.clip) else { return [:] }
            let blendedDuration = Float.lerp(ca.duration, cb.duration, w)
            let phase = blendedDuration > 0 ? time / blendedDuration : 0
            return AnimationSystem.blend(sample(ca, phase * ca.duration), sample(cb, phase * cb.duration), w)
        }
        return library.clip(pts[pts.count - 1].clip).map { sample($0, time) } ?? [:]
    }

    public func update(world: World, context: SystemContext) {
        if cacheVersion != world.structureVersion {
            pathCache.removeAll(keepingCapacity: true)
            cacheVersion = world.structureVersion
        }
        var results: [(Entity, [ChannelKey: SampledValue], [AnimationEvent], String)] = []
        world.forEach(Animator.self) { e, anim in
            let before = anim.stateTime
            let stateBefore = anim.currentState
            anim.advance(dt: context.dt) { self.duration(of: $0) }
            guard let cur = anim.controller.state(named: anim.currentState) else { return }
            var values = sampleState(cur, time: anim.stateTime, params: anim.parameters)
            if let prevName = anim.previousState, let prev = anim.controller.state(named: prevName) {
                let pv = sampleState(prev, time: anim.previousStateTime, params: anim.parameters)
                values = AnimationSystem.blend(pv, values, anim.currentWeight)
            }
            var events: [AnimationEvent] = []
            if stateBefore == anim.currentState, let id = cur.clip, let clip = library.clip(id) {
                events = clip.events(from: before, to: anim.stateTime)
            }
            results.append((e, values, events, cur.name))
        }
        for (e, values, events, stateName) in results {
            apply(values, to: e, world: world)
            for ev in events { context.events.enqueue(AnimationEventFired(entity: e, clip: stateName, event: ev)) }
        }
    }

    /// Resolves a channel path ("Arm/Hand") to an entity under `root` by `Name`.
    func resolve(_ path: String, from root: Entity, world: World) -> Entity? {
        if path.isEmpty { return root }
        if let e = pathCache[root]?[path] { return world.isAlive(e) ? e : nil }
        var cursor = root
        for comp in path.split(separator: "/") {
            guard let next = world.children(of: cursor).first(where: { world.get(Name.self, $0)?.value == String(comp) }) else {
                // Fallback: search the whole subtree for the last component (glTF node names are unique).
                var found: Entity?
                let leaf = String(path.split(separator: "/").last ?? "")
                world.visitSubtree(root) { c, _ in if found == nil, world.get(Name.self, c)?.value == leaf { found = c } }
                if let found { pathCache[root, default: [:]][path] = found }
                return found
            }
            cursor = next
        }
        pathCache[root, default: [:]][path] = cursor
        return cursor
    }

    func apply(_ values: [ChannelKey: SampledValue], to root: Entity, world: World) {
        let binding = world.get(SkeletonBinding.self, root)
        let skeleton = binding.flatMap { library.skeletons[$0.skeleton] }
        for (k, v) in values {
            let target: Entity?
            if let binding, let skeleton {
                let leaf = k.path.split(separator: "/").last.map(String.init) ?? k.path
                if let j = skeleton.index(of: leaf), j < binding.joints.count {
                    target = binding.joints[j]
                } else {
                    target = resolve(k.path, from: root, world: world)
                }
            } else {
                target = resolve(k.path, from: root, world: world)
            }
            guard let e = target else { continue }
            switch (k.target, v) {
            case (.translation, .vec3(let p)): world.modify(Transform.self, e) { $0.position = p }
            case (.rotation, .quat(let q)): world.modify(Transform.self, e) { $0.rotation = q }
            case (.scale, .vec3(let s)): world.modify(Transform.self, e) { $0.scale = s }
            case (.materialFloat(let name), .float(let f)):
                var o = world.get(MaterialOverrides.self, e) ?? MaterialOverrides()
                if name == "metallic" { o.metallic = f } else if name == "roughness" { o.roughness = f }
                world.add(o, to: e)
            case (.materialColor(let name), .color(let c)):
                var o = world.get(MaterialOverrides.self, e) ?? MaterialOverrides()
                if name == "emissive" { o.emissive = c } else { o.baseColor = c }
                world.add(o, to: e)
            case (.spriteFrame, .float(let f)):
                guard let anim = world.get(Animator.self, root), let st = anim.controller.state(named: anim.currentState),
                    let id = st.clip, let clip = library.clip(id), !clip.spriteFrames.isEmpty
                else { continue }
                let idx = min(max(Int(f), 0), clip.spriteFrames.count - 1)
                world.modify(SpriteRenderer.self, e) { $0.uvRect = clip.spriteFrames[idx] }
            default:
                continue
            }
        }
    }
}

// MARK: - Tweens

/// Simple property animation (UI, pickups, doors) without authoring a clip.
public struct Tween: SerializableComponent, Hashable, Sendable {
    public enum Property: Codable, Hashable, Sendable {
        case position(from: Vec3, to: Vec3)
        case scale(from: Vec3, to: Vec3)
        case rotation(from: Quat, to: Quat)
        case spriteColor(from: Color, to: Color)
    }
    public enum Loop: String, Codable, Sendable { case once, loop, pingPong }
    public var property: Property
    public var duration: Float
    public var delay: Float = 0
    public var easing: Easing = .easeInOutQuad
    public var loop: Loop = .once
    public var elapsed: Float = 0
    /// Remove the component when a `.once` tween completes.
    public var removeOnComplete = true
    public init(_ property: Property, duration: Float, easing: Easing = .easeInOutQuad, loop: Loop = .once, delay: Float = 0) {
        self.property = property
        self.duration = max(duration, 1e-4)
        self.easing = easing
        self.loop = loop
        self.delay = delay
    }
}

public struct TweenCompleted: Event, Sendable { public var entity: Entity }

public final class TweenSystem: System {
    public var phase: SystemPhase { .lateUpdate }
    public var order: Int { -90 }
    public var runsInEditMode: Bool { false }
    public init() {}

    public func update(world: World, context: SystemContext) {
        var finished: [Entity] = []
        var writes: [(Entity, Tween.Property, Float)] = []
        world.forEach(Tween.self) { e, tw in
            tw.elapsed += context.dt
            let active = tw.elapsed - tw.delay
            guard active >= 0 else { return }
            var u = active / tw.duration
            switch tw.loop {
            case .once:
                if u >= 1 {
                    u = 1
                    finished.append(e)
                }
            case .loop: u = u.truncatingRemainder(dividingBy: 1)
            case .pingPong:
                let c = u.truncatingRemainder(dividingBy: 2)
                u = c > 1 ? 2 - c : c
            }
            writes.append((e, tw.property, tw.easing.apply(u)))
        }
        for (e, prop, t) in writes {
            switch prop {
            case let .position(a, b): world.modify(Transform.self, e) { $0.position = a.lerp(to: b, t) }
            case let .scale(a, b): world.modify(Transform.self, e) { $0.scale = a.lerp(to: b, t) }
            case let .rotation(a, b): world.modify(Transform.self, e) { $0.rotation = a.slerp(to: b, t) }
            case let .spriteColor(a, b): world.modify(SpriteRenderer.self, e) { $0.color = a.lerp(to: b, t) }
            }
        }
        for e in finished {
            if world.get(Tween.self, e)?.removeOnComplete ?? false { world.remove(Tween.self, from: e) }
            context.events.enqueue(TweenCompleted(entity: e))
        }
    }
}

// MARK: - Timelines

/// Sequenced tracks for cutscenes and scripted moments.
public struct Timeline: Codable, Hashable, Sendable, Identifiable {
    public enum Track: Codable, Hashable, Sendable {
        /// Plays `clip` on the entity at `path` between start and start + clip duration.
        case animation(path: String, clip: AssetID, start: Float)
        /// Enables the entity at `path` only within [start, end).
        case activation(path: String, start: Float, end: Float)
        /// Fires `TimelineEventFired` when crossing `time`.
        case event(time: Float, name: String, payload: String)
    }
    public var id: AssetID
    public var name: String
    public var duration: Float
    public var tracks: [Track]
    public init(id: AssetID = AssetID(), name: String, duration: Float, tracks: [Track]) {
        self.id = id
        self.name = name
        self.duration = duration
        self.tracks = tracks
    }
}

public struct TimelinePlayer: SerializableComponent, Hashable, Sendable {
    public var timeline: AssetID
    public var time: Float = 0
    public var isPlaying = true
    public var loops = false
    public var speed: Float = 1
    public init(timeline: AssetID) { self.timeline = timeline }
}

public struct TimelineEventFired: Event, Sendable {
    public var entity: Entity
    public var name: String
    public var payload: String
}

public final class TimelineSystem: System {
    public var phase: SystemPhase { .lateUpdate }
    public var order: Int { -95 }
    let animation: AnimationSystem
    public init(animation: AnimationSystem) { self.animation = animation }

    public func update(world: World, context: SystemContext) {
        var jobs: [(Entity, Timeline, Float, Float)] = []
        world.forEach(TimelinePlayer.self) { e, p in
            guard p.isPlaying, let tl = animation.library.timelines[p.timeline] else { return }
            let t0 = p.time
            p.time += context.dt * p.speed
            if p.time >= tl.duration {
                if p.loops { p.time = p.time.truncatingRemainder(dividingBy: max(tl.duration, 1e-4)) } else {
                    p.time = tl.duration
                    p.isPlaying = false
                }
            }
            jobs.append((e, tl, t0, p.time))
        }
        for (root, tl, t0, t1) in jobs {
            for track in tl.tracks {
                switch track {
                case let .animation(path, clipID, start):
                    guard let clip = animation.library.clip(clipID), t1 >= start, t1 <= start + clip.duration || clip.loops
                    else { continue }
                    animation.apply(animation.sample(clip, t1 - start), to: animation.resolve(path, from: root, world: world) ?? root, world: world)
                case let .activation(path, start, end):
                    guard let e = animation.resolve(path, from: root, world: world) else { continue }
                    let active = t1 >= start && t1 < end
                    if active && world.has(Disabled.self, e) { world.remove(Disabled.self, from: e) }
                    if !active && !world.has(Disabled.self, e) { world.add(Disabled(), to: e) }
                case let .event(time, name, payload):
                    let crossed = t1 >= t0 ? (time > t0 && time <= t1) : (time > t0 || time <= t1)
                    if crossed { context.events.enqueue(TimelineEventFired(entity: root, name: name, payload: payload)) }
                }
            }
        }
    }
}

extension ComponentRegistry {
    public func registerAnimationComponents() {
        register(Animator.self)
        register(Tween.self)
        register(TimelinePlayer.self)
        register(ParticleEmitter.self) { ParticleEmitter() }
        register(TrailRenderer.self) { TrailRenderer() }
    }
}
