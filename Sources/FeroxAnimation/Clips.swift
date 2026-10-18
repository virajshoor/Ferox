import FeroxCore
import FeroxScene
import Foundation

/// What an animation channel drives.
public enum ChannelTarget: Codable, Hashable, Sendable {
    case translation
    case rotation
    case scale
    /// Morph-target weights (stored as individual channels per weight index).
    case morphWeight(Int)
    /// A named float on `MaterialOverrides` (`metallic`, `roughness`) or a custom property.
    case materialFloat(String)
    /// `MaterialOverrides.baseColor` / `.emissive` by name ("baseColor", "emissive").
    case materialColor(String)
    /// Sprite atlas frame index applied to `SpriteRenderer.uvRect` via the clip's frame list.
    case spriteFrame
}

/// One animated property on one node (identified by path relative to the animated root,
/// e.g. "Hips/Spine/Head"; the empty path is the root itself).
public struct AnimationChannel: Codable, Hashable, Sendable {
    public var path: String
    public var target: ChannelTarget
    public var vec3: AnimationCurve<Vec3>?
    public var quat: AnimationCurve<Quat>?
    public var float: AnimationCurve<Float>?
    public var color: AnimationCurve<Color>?

    public init(path: String, translation c: AnimationCurve<Vec3>) {
        self.path = path
        target = .translation
        vec3 = c
    }
    public init(path: String, rotation c: AnimationCurve<Quat>) {
        self.path = path
        target = .rotation
        quat = c
    }
    public init(path: String, scale c: AnimationCurve<Vec3>) {
        self.path = path
        target = .scale
        vec3 = c
    }
    public init(path: String, target: ChannelTarget, float c: AnimationCurve<Float>) {
        self.path = path
        self.target = target
        float = c
    }
    public init(path: String, target: ChannelTarget, color c: AnimationCurve<Color>) {
        self.path = path
        self.target = target
        color = c
    }

    public var duration: Float {
        max(vec3?.duration ?? 0, quat?.duration ?? 0, float?.duration ?? 0, color?.duration ?? 0)
    }
}

/// A named event fired when playback crosses `time` (footsteps, hit frames, sounds).
public struct AnimationEvent: Codable, Hashable, Sendable {
    public var time: Float
    public var name: String
    public var payload: String
    public init(time: Float, name: String, payload: String = "") {
        self.time = time
        self.name = name
        self.payload = payload
    }
}

/// A reusable animation asset.
public struct AnimationClip: Codable, Hashable, Sendable, Identifiable {
    public var id: AssetID
    public var name: String
    public var channels: [AnimationChannel]
    public var events: [AnimationEvent]
    /// Atlas frames for `.spriteFrame` channels (normalised UV rects).
    public var spriteFrames: [Rect]
    public var duration: Float
    public var loops: Bool

    public init(
        id: AssetID = AssetID(), name: String, channels: [AnimationChannel], events: [AnimationEvent] = [],
        spriteFrames: [Rect] = [], duration: Float? = nil, loops: Bool = true
    ) {
        self.id = id
        self.name = name
        self.channels = channels
        self.events = events.sorted { $0.time < $1.time }
        self.spriteFrames = spriteFrames
        self.duration = duration ?? channels.map(\.duration).max() ?? 0
        self.loops = loops
    }

    /// A flipbook clip for sprite sheets: frames shown at `fps`.
    public static func flipbook(name: String, frames: [Rect], fps: Float, loops: Bool = true) -> AnimationClip {
        let keys = frames.indices.map { AnimationCurve<Float>.Key(Float($0) / fps, Float($0)) }
        let curve = AnimationCurve(keys: keys, interpolation: .step)
        return AnimationClip(
            name: name, channels: [AnimationChannel(path: "", target: .spriteFrame, float: curve)], spriteFrames: frames,
            duration: Float(frames.count) / fps, loops: loops)
    }

    /// Wraps or clamps time according to looping.
    public func localTime(_ t: Float) -> Float {
        guard duration > 0 else { return 0 }
        if loops {
            let r = t.truncatingRemainder(dividingBy: duration)
            return r < 0 ? r + duration : r
        }
        return min(max(t, 0), duration)
    }

    /// Events crossed when moving from `t0` to `t1` (unwrapped times; handles loop wrap).
    public func events(from t0: Float, to t1: Float) -> [AnimationEvent] {
        guard !events.isEmpty, t1 > t0, duration > 0 else { return [] }
        if !loops { return events.filter { $0.time > t0 && $0.time <= t1 } }
        var out: [AnimationEvent] = []
        var cycleStart = (t0 / duration).rounded(.down) * duration
        while cycleStart <= t1 {
            for e in events {
                let at = cycleStart + e.time
                if at > t0 && at <= t1 { out.append(e) }
            }
            cycleStart += duration
            if out.count > 1024 { break }
        }
        return out
    }
}

// MARK: - Skeletons and poses

/// Joint hierarchy with inverse bind matrices (from glTF skins).
public struct Skeleton: Codable, Hashable, Sendable {
    public var jointNames: [String]
    /// Parent index per joint (-1 for roots). Joints are topologically sorted (parents first).
    public var parents: [Int]
    public var inverseBindMatrices: [Mat4]
    public var restPose: [TRS]

    public init(jointNames: [String], parents: [Int], inverseBindMatrices: [Mat4], restPose: [TRS]) {
        self.jointNames = jointNames
        self.parents = parents
        self.inverseBindMatrices = inverseBindMatrices
        self.restPose = restPose
    }
    public var jointCount: Int { jointNames.count }
    public func index(of name: String) -> Int? { jointNames.firstIndex(of: name) }
}

/// Local joint transforms for a skeleton.
public struct Pose: Hashable, Sendable {
    public var local: [TRS]
    public init(_ local: [TRS]) { self.local = local }

    /// Blends towards `other` by `weight` (nlerp for rotations).
    public func blended(with other: Pose, weight: Float) -> Pose {
        guard weight > 0 else { return self }
        guard weight < 1 else { return other }
        return Pose(zip(local, other.local).map { $0.interpolated(to: $1, weight) })
    }

    /// Adds `additive` (a difference pose relative to `reference`) scaled by weight.
    public func addingAdditive(_ additive: Pose, reference: Pose, weight: Float) -> Pose {
        var out = local
        for i in out.indices where i < additive.local.count && i < reference.local.count {
            let dq = additive.local[i].rotation * reference.local[i].rotation.conjugate
            let wq = Quat.identity.nlerp(to: dq, weight)
            out[i].rotation = (wq * out[i].rotation).normalized
            out[i].position += (additive.local[i].position - reference.local[i].position) * weight
            out[i].scale *= Vec3(repeating: 1).lerp(to: additive.local[i].scale / reference.local[i].scale, weight)
        }
        return Pose(out)
    }

    /// Model-space joint matrices (parents must precede children).
    public func modelMatrices(_ skeleton: Skeleton) -> [Mat4] {
        var m = [Mat4](repeating: .identity, count: local.count)
        for i in local.indices {
            let lm = local[i].matrix
            let p = i < skeleton.parents.count ? skeleton.parents[i] : -1
            m[i] = p >= 0 ? m[p] * lm : lm
        }
        return m
    }

    /// Skinning matrices = model × inverse bind.
    public func skinningMatrices(_ skeleton: Skeleton) -> [Mat4] {
        let model = modelMatrices(skeleton)
        return model.indices.map { i in
            i < skeleton.inverseBindMatrices.count ? model[i] * skeleton.inverseBindMatrices[i] : model[i]
        }
    }
}

extension AnimationClip {
    /// Samples the clip's TRS channels into a pose for `skeleton` (joints are matched by
    /// the last path component of the channel).
    public func samplePose(_ skeleton: Skeleton, at time: Float, base: Pose? = nil) -> Pose {
        var pose = base ?? Pose(skeleton.restPose)
        let t = localTime(time)
        for ch in channels {
            let name = ch.path.split(separator: "/").last.map(String.init) ?? ch.path
            guard let j = skeleton.index(of: name), j < pose.local.count else { continue }
            switch ch.target {
            case .translation: if let v = ch.vec3?.sample(t) { pose.local[j].position = v }
            case .rotation: if let q = ch.quat?.sample(t) { pose.local[j].rotation = q }
            case .scale: if let v = ch.vec3?.sample(t) { pose.local[j].scale = v }
            default: break
            }
        }
        return pose
    }
}
