#if canImport(AVFoundation)
import AVFoundation
import FeroxCore
import Foundation

/// AVAudioEngine implementation of `AudioBackend`.
///
/// Graph: `AVAudioPlayerNode` voices → one `AVAudioEnvironmentNode` per bus (providing 3D
/// spatialisation, distance attenuation, playback rate and reverb send) → main mixer.
/// Voices are pooled (`maxVoices`) and stolen by priority. Clips are either decoded into
/// `AVAudioPCMBuffer`s (sound effects) or streamed from disk with `AVAudioFile` segments
/// (music). Supported formats are those of `AVAudioFile` on macOS: WAV, AIFF, CAF, MP3,
/// AAC/M4A, ALAC and FLAC.
///
/// Threading: call all methods from the main thread. AVAudioEngine renders on its own
/// real-time thread; completion callbacks only set flags, and clean-up happens in `update`.
public final class AVAudioBackend: AudioBackend, @unchecked Sendable {
    private struct Clip {
        var info: AudioClipInfo
        var buffer: AVAudioPCMBuffer?
        var file: AVAudioFile?
        var temporaryURL: URL?
    }
    private final class Voice {
        let node = AVAudioPlayerNode()
        var generation: UInt32 = 0
        /// Incremented on every (re)schedule/stop; completion handlers ignore stale schedules.
        var scheduleID: UInt64 = 0
        var clip: Int = -1
        var busy = false
        var paused = false
        var loops = false
        var priority = 0
        var startTime: Double = 0
        var offset: Double = 0
        var volume: Float = 1
        var fadeTarget: Float?
        var fadeRate: Float = 0
        var stopAfterFade = false
        var bus: AudioBus = .sfx
        private let flagLock = NSLock()
        private var finishedFlag = false
        /// Written from AVAudioEngine's callback thread, read on the main thread.
        var finished: Bool {
            get { flagLock.locked { finishedFlag } }
            set { flagLock.locked { finishedFlag = newValue } }
        }
    }

    public let engine = AVAudioEngine()
    public let maxVoices: Int
    private var clips: [Int: Clip] = [:]
    private var nextClip = 1
    private var voices: [Voice] = []
    private var environments: [AudioBus: AVAudioEnvironmentNode] = [:]
    private var busSettings: [AudioBus: BusSettings] = [:]
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var clock: Double = 0

    public init(maxVoices: Int = 48) throws {
        self.maxVoices = max(1, maxVoices)
        for bus in AudioBus.allCases where bus != .master {
            let env = AVAudioEnvironmentNode()
            engine.attach(env)
            engine.connect(env, to: engine.mainMixerNode, format: nil)
            env.renderingAlgorithm = .HRTFHQ
            environments[bus] = env
            busSettings[bus] = BusSettings()
            applyBus(bus)
        }
        busSettings[.master] = BusSettings()
        for _ in 0..<self.maxVoices {
            let v = Voice()
            engine.attach(v.node)
            voices.append(v)
        }
        engine.prepare()
        try engine.start()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.warning("Audio", "Audio configuration changed (device switch); restarting engine")
            do { try self.engine.start() } catch { Log.error("Audio", "Engine restart failed: \(error)") }
        }
        Log.info("Audio", "AVAudioEngine started (\(self.maxVoices) voices, output \(engine.outputNode.outputFormat(forBus: 0).sampleRate) Hz)")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
        for c in clips.values { if let t = c.temporaryURL { try? FileManager.default.removeItem(at: t) } }
    }

    // MARK: Clips

    public func loadClip(_ data: Data, name: String, stream: Bool) throws -> AudioClipID {
        // AVAudioFile reads from URLs; stage in-memory data in a private temporary file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferox-audio-\(UUID().uuidString)")
            .appendingPathExtension((name as NSString).pathExtension.isEmpty ? "caf" : (name as NSString).pathExtension)
        try data.write(to: url, options: [.atomic])
        do {
            let id = try loadClip(url: url, stream: stream)
            if stream {
                clips[id.value]?.temporaryURL = url
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            clips[id.value]?.info.name = name
            return id
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func loadClip(url: URL, stream: Bool) throws -> AudioClipID {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioError.decodeFailed(url.lastPathComponent, String(describing: error))
        }
        let fmt = file.processingFormat
        guard fmt.channelCount >= 1, fmt.channelCount <= 8, fmt.sampleRate > 0 else {
            throw AudioError.decodeFailed(url.lastPathComponent, "unsupported channel layout")
        }
        let duration = Double(file.length) / fmt.sampleRate
        var clip = Clip(
            info: AudioClipInfo(name: url.lastPathComponent, duration: duration, sampleRate: fmt.sampleRate,
                                channels: Int(fmt.channelCount), isStreamed: stream))
        if stream {
            clip.file = file
        } else {
            guard file.length < 48_000 * 60 * 10,
                let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))
            else { throw AudioError.decodeFailed(url.lastPathComponent, "clip too long to decode into memory; stream it instead") }
            try file.read(into: buffer)
            clip.buffer = buffer
            MemoryTracker.shared.allocate("audio", bytes: Int(buffer.frameLength) * Int(fmt.channelCount) * 4)
        }
        let id = nextClip
        nextClip += 1
        clips[id] = clip
        return AudioClipID(value: id)
    }

    public func clipInfo(_ id: AudioClipID) -> AudioClipInfo? { clips[id.value]?.info }

    public func unloadClip(_ id: AudioClipID) {
        for v in voices where v.clip == id.value && v.busy { stopNow(v) }
        if let c = clips.removeValue(forKey: id.value) {
            if let b = c.buffer { MemoryTracker.shared.free("audio", bytes: Int(b.frameLength) * Int(b.format.channelCount) * 4) }
            if let t = c.temporaryURL { try? FileManager.default.removeItem(at: t) }
        }
    }

    // MARK: Voices

    private func voice(_ h: VoiceHandle) -> Voice? {
        guard h.index >= 0, h.index < voices.count, voices[h.index].generation == h.generation, voices[h.index].busy else { return nil }
        return voices[h.index]
    }

    @discardableResult
    public func play(_ clipID: AudioClipID, options o: PlaybackOptions) -> VoiceHandle {
        guard let clip = clips[clipID.value], let env = environments[o.bus == .master ? .sfx : o.bus] else { return .invalid }
        let slots = voices.map { VoiceAllocator.Slot(busy: $0.busy, priority: $0.priority, startTime: $0.startTime) }
        guard let index = VoiceAllocator.choose(slots, priority: o.priority) else { return .invalid }
        let v = voices[index]
        if v.busy { stopNow(v) }
        v.generation &+= 1
        v.clip = clipID.value
        v.busy = true
        v.paused = false
        v.loops = o.loops
        v.priority = o.priority
        v.startTime = clock
        v.offset = min(max(o.startTime, 0), clip.info.duration)
        v.volume = o.volume
        v.bus = o.bus
        v.finished = false
        v.stopAfterFade = false

        let format = clip.buffer?.format ?? clip.file!.processingFormat
        engine.disconnectNodeOutput(v.node)
        engine.connect(v.node, to: env, format: format)
        let spatial = o.position != nil && clip.info.canSpatialize
        v.node.renderingAlgorithm = spatial ? .HRTFHQ : .stereoPassThrough
        if let p = o.position { v.node.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z) }
        v.node.rate = min(max(o.rate, 0.5), 2)
        v.node.reverbBlend = busSettings[o.bus]?.reverbBlend ?? 0
        if o.fadeIn > 0 {
            v.node.volume = 0
            v.fadeTarget = o.volume
            v.fadeRate = Float(1 / o.fadeIn)
        } else {
            v.node.volume = o.volume
            v.fadeTarget = nil
        }
        schedule(v, clip: clip, from: v.offset)
        v.node.play()
        return VoiceHandle(index: index, generation: v.generation)
    }

    private func schedule(_ v: Voice, clip: Clip, from seconds: Double) {
        v.scheduleID &+= 1
        let sid = v.scheduleID
        let onDone: AVAudioPlayerNodeCompletionHandler = { [weak v] _ in
            guard let v, v.scheduleID == sid else { return }
            v.finished = true
        }
        if let buffer = clip.buffer {
            let sr = buffer.format.sampleRate
            let startFrame = AVAudioFramePosition(seconds * sr)
            if startFrame > 0, startFrame < AVAudioFramePosition(buffer.frameLength),
                let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - AVAudioFrameCount(startFrame))
            {
                // Play the remainder once, then loop the full buffer if requested.
                tail.frameLength = tail.frameCapacity
                for c in 0..<Int(buffer.format.channelCount) {
                    if let src = buffer.floatChannelData?[c], let dst = tail.floatChannelData?[c] {
                        dst.update(from: src.advanced(by: Int(startFrame)), count: Int(tail.frameLength))
                    }
                }
                v.node.scheduleBuffer(tail, at: nil, options: [], completionCallbackType: .dataPlayedBack, completionHandler: v.loops ? nil : onDone)
                if v.loops { v.node.scheduleBuffer(buffer, at: nil, options: .loops, completionCallbackType: .dataPlayedBack, completionHandler: onDone) }
            } else {
                v.node.scheduleBuffer(buffer, at: nil, options: v.loops ? .loops : [], completionCallbackType: .dataPlayedBack, completionHandler: onDone)
            }
        } else if let file = clip.file {
            let sr = file.processingFormat.sampleRate
            let start = min(AVAudioFramePosition(seconds * sr), file.length)
            let count = AVAudioFrameCount(max(0, file.length - start))
            guard count > 0 else {
                v.finished = true
                return
            }
            v.node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self, weak v] _ in
                guard let v, v.scheduleID == sid else { return }
                if v.loops {
                    // Re-schedule from the start on the main thread for gapless-enough looping.
                    DispatchQueue.main.async {
                        guard let self, v.scheduleID == sid, v.busy, let clip = self.clips[v.clip] else { return }
                        v.offset = 0
                        self.schedule(v, clip: clip, from: 0)
                    }
                } else {
                    v.finished = true
                }
            }
        }
    }

    private func stopNow(_ v: Voice) {
        v.scheduleID &+= 1  // invalidate pending completion handlers first
        v.node.stop()
        v.busy = false
        v.paused = false
        v.fadeTarget = nil
    }

    public func stop(_ h: VoiceHandle, fadeOut: Double) {
        guard let v = voice(h) else { return }
        if fadeOut > 0 {
            v.fadeTarget = 0
            v.fadeRate = Float(1 / fadeOut)
            v.stopAfterFade = true
        } else {
            stopNow(v)
        }
    }

    public func pause(_ h: VoiceHandle) {
        guard let v = voice(h), !v.paused else { return }
        v.node.pause()
        v.paused = true
    }

    public func resume(_ h: VoiceHandle) {
        guard let v = voice(h), v.paused else { return }
        v.node.play()
        v.paused = false
    }

    public func seek(_ h: VoiceHandle, to seconds: Double) {
        guard let v = voice(h), let clip = clips[v.clip] else { return }
        let wasPaused = v.paused
        v.scheduleID &+= 1
        v.node.stop()
        v.offset = min(max(seconds, 0), clip.info.duration)
        v.finished = false
        schedule(v, clip: clip, from: v.offset)
        if !wasPaused { v.node.play() }
    }

    public func setVolume(_ h: VoiceHandle, _ volume: Float) {
        guard let v = voice(h) else { return }
        v.volume = volume
        if v.fadeTarget == nil { v.node.volume = volume }
    }

    public func setPosition(_ h: VoiceHandle, _ p: Vec3) {
        voice(h)?.node.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }

    public func setRate(_ h: VoiceHandle, _ rate: Float) { voice(h)?.node.rate = min(max(rate, 0.5), 2) }

    public func isPlaying(_ h: VoiceHandle) -> Bool {
        guard let v = voice(h) else { return false }
        return !v.paused && !v.finished
    }

    public func playbackTime(_ h: VoiceHandle) -> Double? {
        guard let v = voice(h), let clip = clips[v.clip] else { return nil }
        guard let nodeTime = v.node.lastRenderTime, let t = v.node.playerTime(forNodeTime: nodeTime) else { return v.offset }
        let played = v.offset + Double(t.sampleTime) / t.sampleRate
        return v.loops && clip.info.duration > 0 ? played.truncatingRemainder(dividingBy: clip.info.duration) : min(played, clip.info.duration)
    }

    // MARK: Listener & buses

    public func setListener(position p: Vec3, forward f: Vec3, up u: Vec3) {
        for env in environments.values {
            env.listenerPosition = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
            env.listenerVectorOrientation = AVAudio3DVectorOrientation(
                forward: AVAudio3DVector(x: f.x, y: f.y, z: f.z), up: AVAudio3DVector(x: u.x, y: u.y, z: u.z))
        }
    }

    public func setBus(_ bus: AudioBus, _ settings: BusSettings) {
        busSettings[bus] = settings
        if bus == .master {
            engine.mainMixerNode.outputVolume = settings.muted ? 0 : settings.volume
        } else {
            applyBus(bus)
        }
    }

    public func bus(_ bus: AudioBus) -> BusSettings { busSettings[bus] ?? BusSettings() }

    private func applyBus(_ bus: AudioBus) {
        guard let env = environments[bus], let s = busSettings[bus] else { return }
        env.outputVolume = s.muted ? 0 : s.volume
        let p = env.distanceAttenuationParameters
        switch s.attenuation.model {
        case .inverse: p.distanceAttenuationModel = .inverse
        case .linear: p.distanceAttenuationModel = .linear
        case .exponential: p.distanceAttenuationModel = .exponential
        }
        p.referenceDistance = s.attenuation.referenceDistance
        p.maximumDistance = s.attenuation.maximumDistance
        p.rolloffFactor = s.attenuation.rolloff
    }

    // MARK: Frame update

    public func update(dt: Double) {
        clock += dt
        for v in voices where v.busy {
            if let target = v.fadeTarget {
                let step = v.fadeRate * Float(dt) * max(v.volume, 0.0001)
                let cur = v.node.volume
                let next = cur < target ? min(cur + step, target) : max(cur - step, target)
                v.node.volume = next
                if next == target {
                    v.fadeTarget = nil
                    if v.stopAfterFade { stopNow(v) }
                }
            }
            if v.busy && v.finished && !v.loops { stopNow(v) }
        }
    }

    public var activeVoiceCount: Int { voices.filter { $0.busy && !$0.paused }.count }
}

public enum AudioError: Error, CustomStringConvertible {
    case decodeFailed(String, String)
    public var description: String {
        switch self {
        case let .decodeFailed(n, r): return "Could not decode audio '\(n)': \(r)"
        }
    }
}
#endif
