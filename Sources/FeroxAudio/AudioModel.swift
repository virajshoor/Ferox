import FeroxCore
import Foundation

/// Distance attenuation curve for positional audio.
public enum AttenuationModel: String, Codable, Sendable, CaseIterable {
    /// gain = ref / (ref + rolloff × (d − ref)) — physically plausible default.
    case inverse
    /// gain falls linearly from 1 at `reference` to 0 at `maximum`.
    case linear
    /// gain = (d / ref)^(−rolloff).
    case exponential
}

public struct Attenuation: Codable, Sendable, Hashable {
    public var model: AttenuationModel = .inverse
    public var referenceDistance: Float = 1
    public var maximumDistance: Float = 100
    public var rolloff: Float = 1
    public init(
        model: AttenuationModel = .inverse, referenceDistance: Float = 1, maximumDistance: Float = 100,
        rolloff: Float = 1
    ) {
        self.model = model
        self.referenceDistance = referenceDistance
        self.maximumDistance = maximumDistance
        self.rolloff = rolloff
    }

    /// Gain at distance `d` (same formulas as OpenAL / AVAudioEnvironmentNode).
    public func gain(at d: Float) -> Float {
        let ref = max(referenceDistance, 1e-4)
        let dist = min(max(d, ref), maximumDistance)
        switch model {
        case .inverse: return ref / (ref + rolloff * (dist - ref))
        case .linear: return max(0, 1 - rolloff * (dist - ref) / max(maximumDistance - ref, 1e-4))
        case .exponential: return pow(dist / ref, -rolloff)
        }
    }
}

/// Mixer bus. Ferox ships a fixed set of buses routed into `master`; each has its own
/// volume, mute and attenuation settings.
public enum AudioBus: String, Codable, Sendable, CaseIterable {
    case master, music, sfx, ui, voice, ambience
}

public struct BusSettings: Codable, Sendable, Hashable {
    public var volume: Float = 1
    public var muted = false
    public var attenuation = Attenuation()
    /// Reverb send level [0, 1] for positional sources on this bus.
    public var reverbBlend: Float = 0
    public init() {}
}

/// Parameters for starting a sound.
public struct PlaybackOptions: Sendable, Hashable {
    public var bus: AudioBus = .sfx
    public var volume: Float = 1
    /// Playback rate (0.5–2.0); changes pitch and speed together.
    public var rate: Float = 1
    public var loops = false
    /// World position for 3D sources; nil plays non-spatialised (2D).
    public var position: Vec3?
    /// Higher priority voices steal lower ones when the voice limit is reached.
    public var priority: Int = 0
    /// Start offset in seconds.
    public var startTime: Double = 0
    public var fadeIn: Double = 0
    public init(bus: AudioBus = .sfx, volume: Float = 1, loops: Bool = false, position: Vec3? = nil) {
        self.bus = bus
        self.volume = volume
        self.loops = loops
        self.position = position
    }
}

/// Handle to a playing voice. Becomes invalid when the voice finishes or is stolen.
public struct VoiceHandle: Hashable, Sendable {
    public let index: Int
    public let generation: UInt32
    public static let invalid = VoiceHandle(index: -1, generation: 0)
}

/// Decoded or streamed sound asset metadata.
public struct AudioClipInfo: Sendable, Hashable {
    public var name: String
    public var duration: Double
    public var sampleRate: Double
    public var channels: Int
    public var isStreamed: Bool
    /// Positional playback requires mono clips (HRTF spatialisation); stereo clips play 2D.
    public var canSpatialize: Bool { channels == 1 }
}

/// Chooses which voice to steal when all are busy: the lowest-priority, then the oldest.
public enum VoiceAllocator {
    public struct Slot: Sendable {
        public var busy: Bool
        public var priority: Int
        public var startTime: Double
        public init(busy: Bool, priority: Int, startTime: Double) {
            self.busy = busy
            self.priority = priority
            self.startTime = startTime
        }
    }
    /// Returns the slot to use for a new voice of `priority`, or nil if every busy voice
    /// outranks it.
    public static func choose(_ slots: [Slot], priority: Int) -> Int? {
        if let free = slots.firstIndex(where: { !$0.busy }) { return free }
        let candidate = slots.indices.min {
            (slots[$0].priority, slots[$0].startTime) < (slots[$1].priority, slots[$1].startTime)
        }
        guard let c = candidate, slots[c].priority <= priority else { return nil }
        return c
    }
}

/// Decides whether a clip may be decoded into memory under the audio memory budget.
///
/// Decoded clips are 32-bit float PCM, so a clip costs `frames × channels × 4` bytes.
/// A clip that would push the decoded total over the budget is streamed from disk
/// instead: it still plays, but costs only a small read buffer. Streamed clips are never
/// counted against the budget.
public enum AudioMemoryPolicy {
    /// Bytes a clip of `frames` frames and `channels` channels occupies once decoded.
    public static func decodedBytes(frames: Int64, channels: Int) -> Int {
        let f = max(frames, 0)
        let c = Int64(max(channels, 0))
        let (bytes, overflow) = f.multipliedReportingOverflow(by: c * 4)
        return overflow || bytes > Int64(Int.max) ? Int.max : Int(bytes)
    }

    /// True when the clip should be streamed: either the caller asked for streaming, or
    /// decoding `bytes` more would exceed `budget` given `resident` decoded bytes.
    /// A budget of zero or less streams every clip.
    public static func shouldStream(requested: Bool, bytes: Int, resident: Int, budget: Int) -> Bool {
        if requested { return true }
        guard budget > 0 else { return true }
        let (total, overflow) = max(resident, 0).addingReportingOverflow(max(bytes, 0))
        return overflow || total > budget
    }
}

/// Converts decibels to linear gain and back.
public enum Decibels {
    public static func toGain(_ db: Float) -> Float { pow(10, db / 20) }
    public static func fromGain(_ g: Float) -> Float { 20 * log10(max(g, 1e-6)) }
}

/// Audio engine interface used by the rest of Ferox (the macOS implementation is
/// `AVAudioBackend`; `SilentAudioBackend` is used headless and in tests).
public protocol AudioBackend: AnyObject {
    func loadClip(_ data: Data, name: String, stream: Bool) throws -> AudioClipID
    func loadClip(url: URL, stream: Bool) throws -> AudioClipID
    func clipInfo(_ id: AudioClipID) -> AudioClipInfo?
    func unloadClip(_ id: AudioClipID)
    @discardableResult func play(_ clip: AudioClipID, options: PlaybackOptions) -> VoiceHandle
    func stop(_ v: VoiceHandle, fadeOut: Double)
    func pause(_ v: VoiceHandle)
    func resume(_ v: VoiceHandle)
    func seek(_ v: VoiceHandle, to seconds: Double)
    func setVolume(_ v: VoiceHandle, _ volume: Float)
    func setPosition(_ v: VoiceHandle, _ p: Vec3)
    func setRate(_ v: VoiceHandle, _ rate: Float)
    func isPlaying(_ v: VoiceHandle) -> Bool
    func playbackTime(_ v: VoiceHandle) -> Double?
    func setListener(position: Vec3, forward: Vec3, up: Vec3)
    func setBus(_ bus: AudioBus, _ settings: BusSettings)
    func bus(_ bus: AudioBus) -> BusSettings
    /// Stops every voice, fading each out over `fadeOut` seconds (0 stops at once).
    func stopAll(fadeOut: Double)
    /// Called once per frame on the main thread (fades, finished voices).
    func update(dt: Double)
    var activeVoiceCount: Int { get }
    /// Upper bound for decoded (non-streamed) clip memory, in bytes. A clip that would
    /// exceed it is streamed instead (see `AudioMemoryPolicy`). Clips already decoded
    /// are not affected when the budget is lowered.
    var memoryBudgetBytes: Int { get set }
    /// Bytes currently held by decoded clips.
    var decodedBytes: Int { get }
}

/// Default for `AudioBackend.memoryBudgetBytes`; matches `AssetManager`'s default
/// `MemoryBudget.audioBytes`. `Engine` replaces it with the asset manager's budget.
public let defaultAudioMemoryBudget = 128 << 20

public struct AudioClipID: Hashable, Sendable {
    public let value: Int
}

/// No-op backend (headless servers, CI, tests). Tracks state so logic can be tested.
public final class SilentAudioBackend: AudioBackend {
    private var clips: [Int: AudioClipInfo] = [:]
    private var nextClip = 1
    private var voices: [Int: (clip: Int, playing: Bool, time: Double, generation: UInt32, loops: Bool)] = [:]
    private var nextVoice = 0
    private var buses: [AudioBus: BusSettings] = [:]
    /// Decoded size per clip; the silent backend charges a clip's data size.
    private var clipBytes: [Int: Int] = [:]
    public var memoryBudgetBytes = defaultAudioMemoryBudget
    public private(set) var decodedBytes = 0
    public init() {}

    public func loadClip(_ data: Data, name: String, stream: Bool) throws -> AudioClipID {
        let id = nextClip
        nextClip += 1
        let streamed = AudioMemoryPolicy.shouldStream(
            requested: stream, bytes: data.count, resident: decodedBytes,
            budget: memoryBudgetBytes)
        clips[id] = AudioClipInfo(name: name, duration: 1, sampleRate: 48000, channels: 1, isStreamed: streamed)
        if !streamed {
            clipBytes[id] = data.count
            decodedBytes += data.count
        }
        return AudioClipID(value: id)
    }
    public func loadClip(url: URL, stream: Bool) throws -> AudioClipID {
        try loadClip(Data(), name: url.lastPathComponent, stream: stream)
    }
    public func clipInfo(_ id: AudioClipID) -> AudioClipInfo? { clips[id.value] }
    public func unloadClip(_ id: AudioClipID) {
        clips[id.value] = nil
        voices = voices.filter { $0.value.clip != id.value }
        if let b = clipBytes.removeValue(forKey: id.value) { decodedBytes -= b }
    }
    public func play(_ clip: AudioClipID, options: PlaybackOptions) -> VoiceHandle {
        guard clips[clip.value] != nil else { return .invalid }
        let i = nextVoice
        nextVoice += 1
        voices[i] = (clip.value, true, options.startTime, 1, options.loops)
        return VoiceHandle(index: i, generation: 1)
    }
    public func stop(_ v: VoiceHandle, fadeOut: Double) { voices[v.index] = nil }
    public func stopAll(fadeOut: Double) { voices.removeAll() }
    public func pause(_ v: VoiceHandle) { voices[v.index]?.playing = false }
    public func resume(_ v: VoiceHandle) { voices[v.index]?.playing = true }
    public func seek(_ v: VoiceHandle, to seconds: Double) { voices[v.index]?.time = seconds }
    public func setVolume(_ v: VoiceHandle, _ volume: Float) {}
    public func setPosition(_ v: VoiceHandle, _ p: Vec3) {}
    public func setRate(_ v: VoiceHandle, _ rate: Float) {}
    public func isPlaying(_ v: VoiceHandle) -> Bool { voices[v.index]?.playing ?? false }
    public func playbackTime(_ v: VoiceHandle) -> Double? { voices[v.index]?.time }
    public func setListener(position: Vec3, forward: Vec3, up: Vec3) {}
    public func setBus(_ bus: AudioBus, _ settings: BusSettings) { buses[bus] = settings }
    public func bus(_ bus: AudioBus) -> BusSettings { buses[bus] ?? BusSettings() }
    public func update(dt: Double) {
        for (k, v) in voices where v.playing {
            let t = v.time + dt
            let dur = clips[v.clip]?.duration ?? 0
            if t >= dur && !v.loops {
                voices[k] = nil
            } else {
                voices[k]?.time = v.loops && dur > 0 ? t.truncatingRemainder(dividingBy: dur) : t
            }
        }
    }
    public var activeVoiceCount: Int { voices.values.filter(\.playing).count }
}
