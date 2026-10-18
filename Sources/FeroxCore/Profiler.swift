import Foundation

/// A completed timing sample (CPU scope or GPU pass).
public struct ProfileSample: Sendable, Hashable {
    public enum Domain: String, Sendable, Codable { case cpu, gpu }
    public var name: String
    public var domain: Domain
    /// Start in seconds relative to the frame start.
    public var start: Double
    public var duration: Double
    public var depth: Int
    public var thread: String
}

/// Aggregated statistics for one named scope over the history window.
public struct ScopeStatistics: Sendable, Hashable {
    public var name: String
    public var domain: ProfileSample.Domain
    public var lastMilliseconds: Double
    public var averageMilliseconds: Double
    public var maxMilliseconds: Double
    public var callsPerFrame: Int
}

/// Per-frame rendering counters filled in by the renderer.
public struct RenderCounters: Sendable, Hashable, Codable {
    public var drawCalls = 0
    public var instances = 0
    public var triangles = 0
    public var renderPasses = 0
    public var computeDispatches = 0
    public var pipelineStateChanges = 0
    public var textureBinds = 0
    public var culledObjects = 0
    public var visibleObjects = 0
    public var spriteBatches = 0
    public var sprites = 0
    public var uploadedBytes = 0
    public var rayTracingRays = 0
    public init() {}
}

/// Frame profiler collecting hierarchical CPU scopes, GPU pass timings, render counters
/// and arbitrary named counters (asset loads, physics contacts, …).
///
/// CPU scopes are recorded per thread with negligible overhead (`MonotonicClock` and an
/// array append). Profiling can be disabled entirely at runtime with `isEnabled`, in
/// which case `scope` costs one branch.
public final class Profiler: @unchecked Sendable {
    public static let shared = Profiler()

    public var isEnabled = true
    public let historyLength: Int

    private let lock = NSLock()
    private var frameStart: Double = MonotonicClock.now()
    private var current: [ProfileSample] = []
    private var openDepth: [ObjectIdentifier: Int] = [:]
    private var history: [[ProfileSample]] = []
    private var counterValues: [String: Double] = [:]
    public private(set) var lastFrameCounters: [String: Double] = [:]
    public var renderCounters = RenderCounters()
    public private(set) var lastRenderCounters = RenderCounters()
    public private(set) var frameStatistics = FrameStatistics()
    public private(set) var gpuFrameStatistics = FrameStatistics()

    public init(historyLength: Int = 120) { self.historyLength = max(1, historyLength) }

    /// Marks the boundary between frames. Called by the engine at the start of each frame.
    public func beginFrame() {
        let now = MonotonicClock.now()
        lock.locked {
            if !current.isEmpty || !history.isEmpty {
                history.append(current)
                if history.count > historyLength { history.removeFirst(history.count - historyLength) }
            }
            frameStatistics.add(now - frameStart)
            current.removeAll(keepingCapacity: true)
            lastFrameCounters = counterValues
            counterValues.removeAll(keepingCapacity: true)
            lastRenderCounters = renderCounters
            renderCounters = RenderCounters()
            frameStart = now
        }
    }

    /// Times `body` as a named CPU scope.
    @discardableResult
    public func scope<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let thread = Thread.isMainThread ? "main" : "worker"
        let key = ObjectIdentifier(Thread.current)
        let depth: Int = lock.locked {
            let d = openDepth[key, default: 0]
            openDepth[key] = d + 1
            return d
        }
        let t0 = MonotonicClock.now()
        defer {
            let t1 = MonotonicClock.now()
            lock.locked {
                openDepth[key] = depth
                current.append(
                    ProfileSample(
                        name: name, domain: .cpu, start: t0 - frameStart, duration: t1 - t0, depth: depth,
                        thread: thread))
            }
        }
        return try body()
    }

    /// Records a GPU timing that was resolved asynchronously (e.g. from a command buffer
    /// completion handler or counter sample buffer).
    public func recordGPU(name: String, start: Double = 0, duration: Double) {
        guard isEnabled else { return }
        lock.locked {
            current.append(ProfileSample(name: name, domain: .gpu, start: start, duration: duration, depth: 0, thread: "gpu"))
        }
    }

    /// Records the total GPU time of a frame.
    public func recordGPUFrame(duration: Double) {
        lock.locked { gpuFrameStatistics.add(duration) }
    }

    /// Adds `value` to a named per-frame counter.
    public func count(_ name: String, _ value: Double = 1) {
        guard isEnabled else { return }
        lock.locked { counterValues[name, default: 0] += value }
    }

    public func updateRenderCounters(_ body: (inout RenderCounters) -> Void) {
        lock.locked { body(&renderCounters) }
    }

    /// Samples from the most recently completed frame.
    public var lastFrame: [ProfileSample] { lock.locked { history.last ?? [] } }

    /// Per-scope statistics across the history window, sorted by average cost.
    public func statistics() -> [ScopeStatistics] {
        lock.locked {
            var acc: [String: (ProfileSample.Domain, [Double], Int)] = [:]
            for frame in history {
                var perFrame: [String: (ProfileSample.Domain, Double, Int)] = [:]
                for s in frame {
                    var e = perFrame[s.name] ?? (s.domain, 0, 0)
                    e.1 += s.duration
                    e.2 += 1
                    perFrame[s.name] = e
                }
                for (k, v) in perFrame {
                    var a = acc[k] ?? (v.0, [], 0)
                    a.1.append(v.1)
                    a.2 += v.2
                    acc[k] = a
                }
            }
            let frames = max(1, history.count)
            return acc.map { name, value in
                let ms = value.1.map { $0 * 1000 }
                return ScopeStatistics(
                    name: name, domain: value.0, lastMilliseconds: ms.last ?? 0,
                    averageMilliseconds: ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count),
                    maxMilliseconds: ms.max() ?? 0, callsPerFrame: value.2 / frames)
            }.sorted { $0.averageMilliseconds > $1.averageMilliseconds }
        }
    }

    /// Exports the history in the Chrome trace-event JSON format (open in `chrome://tracing`
    /// or Perfetto) for offline analysis.
    public func exportChromeTrace() -> Data {
        let frames = lock.locked { history }
        var events: [[String: Any]] = []
        var base = 0.0
        for frame in frames {
            var frameEnd = 0.0
            for s in frame {
                events.append([
                    "name": s.name, "cat": s.domain.rawValue, "ph": "X", "pid": 1,
                    "tid": s.thread, "ts": (base + s.start) * 1e6, "dur": s.duration * 1e6,
                ])
                frameEnd = max(frameEnd, s.start + s.duration)
            }
            base += max(frameEnd, 1.0 / 60.0)
        }
        return (try? JSONSerialization.data(withJSONObject: ["traceEvents": events], options: [])) ?? Data()
    }

    public func reset() {
        lock.locked {
            history.removeAll()
            current.removeAll()
            counterValues.removeAll()
            frameStatistics = FrameStatistics()
            gpuFrameStatistics = FrameStatistics()
        }
    }
}

/// Tracks engine-owned allocations by category (GPU buffers, textures, audio, assets).
///
/// Apple Silicon uses unified memory, so GPU allocations compete directly with the
/// application's CPU heap; the renderer and asset system report here so the engine can
/// honour `MemoryBudget` and the editor can display usage.
public final class MemoryTracker: @unchecked Sendable {
    public static let shared = MemoryTracker()
    private let lock = NSLock()
    private var bytes: [String: Int] = [:]
    private var peak: [String: Int] = [:]

    public init() {}

    public func allocate(_ category: String, bytes n: Int) {
        lock.locked {
            let v = bytes[category, default: 0] + n
            bytes[category] = v
            peak[category] = max(peak[category, default: 0], v)
        }
    }
    public func free(_ category: String, bytes n: Int) {
        lock.locked { bytes[category] = max(0, bytes[category, default: 0] - n) }
    }
    public func usage(_ category: String) -> Int { lock.locked { bytes[category, default: 0] } }
    public func peakUsage(_ category: String) -> Int { lock.locked { peak[category, default: 0] } }
    public var total: Int { lock.locked { bytes.values.reduce(0, +) } }
    public var snapshot: [String: Int] { lock.locked { bytes } }
}

/// Memory budget used by the asset streamer to choose texture mip levels and evict caches.
public struct MemoryBudget: Codable, Sendable, Hashable {
    /// Budget for textures in bytes.
    public var textureBytes: Int
    /// Budget for meshes in bytes.
    public var meshBytes: Int
    /// Budget for decoded audio held in memory (streamed audio is not counted).
    public var audioBytes: Int

    public init(textureBytes: Int, meshBytes: Int, audioBytes: Int) {
        self.textureBytes = textureBytes
        self.meshBytes = meshBytes
        self.audioBytes = audioBytes
    }

    /// Derives a conservative budget from the GPU's recommended working set
    /// (`MTLDevice.recommendedMaxWorkingSetSize` on macOS).
    public static func recommended(workingSetBytes: UInt64) -> MemoryBudget {
        let ws = Int(min(workingSetBytes, UInt64(Int.max)))
        return MemoryBudget(textureBytes: ws / 2, meshBytes: ws / 8, audioBytes: min(ws / 32, 512 << 20))
    }
}
