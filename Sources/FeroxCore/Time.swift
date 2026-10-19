import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Monotonic high-resolution clock in seconds.
public enum MonotonicClock {
    #if canImport(Darwin)
        private static let timebase: Double = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return Double(info.numer) / Double(info.denom) * 1e-9
        }()
        /// Seconds since an arbitrary fixed point.
        @inline(__always) public static func now() -> Double { Double(mach_absolute_time()) * timebase }
    #else
        @inline(__always) public static func now() -> Double {
            var ts = timespec()
            clock_gettime(CLOCK_MONOTONIC, &ts)
            return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
        }
    #endif

    /// Nanoseconds since an arbitrary fixed point.
    @inline(__always) public static func nanoseconds() -> UInt64 { UInt64(now() * 1e9) }
}

/// Per-frame timing information handed to game code.
public struct FrameTime: Sendable, Equatable {
    /// Variable delta of this frame in seconds (scaled by `timeScale`, clamped by `maxDelta`).
    public var delta: Double
    /// Unscaled, unclamped wall-clock delta.
    public var unscaledDelta: Double
    /// Scaled game time since start.
    public var elapsed: Double
    /// Monotonic frame counter.
    public var frameIndex: UInt64
    /// Fixed simulation step in seconds.
    public var fixedDelta: Double
    /// Interpolation factor in [0, 1) between the last two fixed steps, used for rendering.
    public var interpolationAlpha: Double

    public init(
        delta: Double = 0, unscaledDelta: Double = 0, elapsed: Double = 0, frameIndex: UInt64 = 0,
        fixedDelta: Double = 1.0 / 60.0, interpolationAlpha: Double = 0
    ) {
        self.delta = delta
        self.unscaledDelta = unscaledDelta
        self.elapsed = elapsed
        self.frameIndex = frameIndex
        self.fixedDelta = fixedDelta
        self.interpolationAlpha = interpolationAlpha
    }

    @inlinable public var deltaF: Float { Float(delta) }
    @inlinable public var fixedDeltaF: Float { Float(fixedDelta) }
    @inlinable public var alphaF: Float { Float(interpolationAlpha) }
}

/// Fixed-timestep accumulator ("Fix Your Timestep", G. Fiedler).
///
/// The simulation advances in exact `step` increments; leftover time is carried to the
/// next frame and exposed as `alpha` for render interpolation. `maxStepsPerFrame` bounds
/// the work done after a hitch so that a slow frame cannot trigger a "spiral of death";
/// time beyond the bound is dropped and reported via `droppedTime`.
public struct FixedTimestep: Sendable, Equatable {
    public var step: Double
    public var maxStepsPerFrame: Int
    public private(set) var accumulator: Double = 0
    public private(set) var droppedTime: Double = 0

    public init(hz: Double = 60, maxStepsPerFrame: Int = 8) {
        precondition(hz > 0, "Fixed timestep frequency must be positive")
        step = 1 / hz
        self.maxStepsPerFrame = max(1, maxStepsPerFrame)
    }

    /// Adds `delta` seconds and returns how many fixed steps to run this frame.
    public mutating func advance(by delta: Double) -> Int {
        accumulator += max(0, delta)
        // A tiny tolerance stops rounding error (e.g. 2 × 1/60 summed as 0.0333…32) from
        // turning a whole step into a fraction and dropping it.
        var steps = Int(accumulator / step + 1e-9)
        if steps > maxStepsPerFrame {
            droppedTime += Double(steps - maxStepsPerFrame) * step
            accumulator -= Double(steps - maxStepsPerFrame) * step
            steps = maxStepsPerFrame
        }
        accumulator -= Double(steps) * step
        // Guard against floating-point drift producing a tiny negative accumulator.
        if accumulator < 0 { accumulator = 0 }
        return steps
    }

    /// Interpolation factor between the previous and current simulation states.
    public var alpha: Double { min(max(accumulator / step, 0), 1) }

    public mutating func reset() {
        accumulator = 0
        droppedTime = 0
    }
}

/// Produces `FrameTime` values from a monotonic clock, applying time scale, pause and clamping.
public struct FrameClock: Sendable {
    public var timeScale: Double = 1
    public var isPaused = false
    /// Deltas above this are clamped (e.g. after a breakpoint or window drag).
    public var maxDelta: Double = 0.25
    public var fixed: FixedTimestep

    private var last: Double?
    private var elapsed: Double = 0
    private var frameIndex: UInt64 = 0

    public init(fixedHz: Double = 60) { fixed = FixedTimestep(hz: fixedHz) }

    /// Advances the clock. Returns the frame time and the number of fixed steps to run.
    public mutating func tick(now: Double = MonotonicClock.now()) -> (FrameTime, fixedSteps: Int) {
        let raw = last.map { now - $0 } ?? 0
        last = now
        let clamped = min(max(raw, 0), maxDelta)
        let scaled = isPaused ? 0 : clamped * timeScale
        elapsed += scaled
        frameIndex &+= 1
        let steps = fixed.advance(by: scaled)
        let ft = FrameTime(
            delta: scaled, unscaledDelta: raw, elapsed: elapsed, frameIndex: frameIndex, fixedDelta: fixed.step,
            interpolationAlpha: fixed.alpha)
        return (ft, steps)
    }

    /// Advances by an explicit delta (deterministic tests, offline rendering, replays).
    public mutating func tick(delta: Double) -> (FrameTime, fixedSteps: Int) {
        // The first explicit tick still counts its delta: start the clock `delta` earlier.
        let base = last ?? 0
        if last == nil { last = base }
        return tick(now: base + delta)
    }

    public mutating func reset() {
        last = nil
        elapsed = 0
        frameIndex = 0
        fixed.reset()
    }
}

/// Rolling frame-time statistics used for frame-pacing diagnostics.
public struct FrameStatistics: Sendable {
    public private(set) var samples: [Double]
    private var cursor = 0
    private var filled = 0

    public init(capacity: Int = 240) { samples = Array(repeating: 0, count: max(1, capacity)) }

    public mutating func add(_ frameSeconds: Double) {
        samples[cursor] = frameSeconds
        cursor = (cursor + 1) % samples.count
        filled = min(filled + 1, samples.count)
    }

    public var count: Int { filled }
    private var valid: ArraySlice<Double> { samples[0..<filled] }

    public var average: Double { filled == 0 ? 0 : valid.reduce(0, +) / Double(filled) }
    public var minimum: Double { valid.min() ?? 0 }
    public var maximum: Double { valid.max() ?? 0 }
    public var averageFPS: Double { average > 0 ? 1 / average : 0 }

    /// Percentile in [0, 100] of frame duration (e.g. 99 → "1% low" frame time).
    public func percentile(_ p: Double) -> Double {
        guard filled > 0 else { return 0 }
        let sorted = valid.sorted()
        let idx = Int((p / 100 * Double(filled - 1)).rounded())
        return sorted[min(max(idx, 0), filled - 1)]
    }

    /// Standard deviation of frame time — the primary frame-pacing ("jitter") metric.
    public var standardDeviation: Double {
        guard filled > 1 else { return 0 }
        let mean = average
        let v = valid.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(filled - 1)
        return v.squareRoot()
    }

    /// Number of frames exceeding `budget` seconds by more than 50 % (visible hitches).
    public func hitchCount(budget: Double) -> Int { valid.filter { $0 > budget * 1.5 }.count }
}
