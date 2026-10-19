/// Tests for the timing utilities in FeroxCore: the fixed-step accumulator, the frame clock
/// (time scale, pause, delta clamping), rolling frame statistics, and the frame profiler.
import Foundation
import XCTest

@testable import FeroxCore

final class FixedTimestepTests: XCTestCase {
    // Advancing by 0.25 s at 10 Hz runs two steps and leaves half a step as interpolation alpha.
    func testStepsAndAlphaFromAccumulator() {
        var ts = FixedTimestep(hz: 10)
        XCTAssertEqual(ts.advance(by: 0.25), 2)
        XCTAssertEqual(ts.alpha, 0.5, accuracy: 1e-9)
    }

    // Frame deltas that are exact multiples of the step must not lose steps to rounding.
    func testExactMultipleDeltasDoNotLoseSteps() {
        var ts = FixedTimestep(hz: 60)
        var steps = 0
        for _ in 0..<30 { steps += ts.advance(by: 1.0 / 30) }
        XCTAssertEqual(steps, 60)
    }

    // Time carries over between calls until a whole step has accumulated.
    func testTimeAccumulatesAcrossCalls() {
        var ts = FixedTimestep(hz: 10)
        XCTAssertEqual(ts.advance(by: 0.06), 0)
        XCTAssertEqual(ts.advance(by: 0.06), 1)
        XCTAssertEqual(ts.alpha, 0.2, accuracy: 1e-9)
    }

    // A large delta is capped at maxStepsPerFrame and the excess is reported as dropped time.
    func testSpiralOfDeathClampDropsExcessTime() {
        var ts = FixedTimestep(hz: 4, maxStepsPerFrame: 4)
        XCTAssertEqual(ts.advance(by: 2.0), 4)
        XCTAssertEqual(ts.droppedTime, 1.0, accuracy: 1e-9)
    }

    // Negative deltas are ignored rather than running backwards.
    func testNegativeDeltaIsIgnored() {
        var ts = FixedTimestep(hz: 10)
        XCTAssertEqual(ts.advance(by: -1), 0)
        XCTAssertEqual(ts.alpha, 0)
    }

    // reset clears both the accumulator and the dropped-time counter.
    func testResetClearsState() {
        var ts = FixedTimestep(hz: 4, maxStepsPerFrame: 1)
        _ = ts.advance(by: 1.0)
        ts.reset()
        XCTAssertEqual(ts.droppedTime, 0)
        XCTAssertEqual(ts.accumulator, 0)
    }
}

final class FrameClockTests: XCTestCase {
    // The first tick reports zero delta because there is no previous timestamp yet.
    func testFirstTickHasZeroDelta() {
        var clock = FrameClock(fixedHz: 4)
        let (ft, steps) = clock.tick(now: 10)
        XCTAssertEqual(ft.delta, 0)
        XCTAssertEqual(steps, 0)
    }

    // Each tick reports the wall-clock delta since the previous tick and produces fixed steps for it.
    func testFixedStepsFromWallClockDelta() {
        var clock = FrameClock(fixedHz: 4)
        _ = clock.tick(now: 0)
        let (ft, steps) = clock.tick(now: 0.25)
        XCTAssertEqual(steps, 1)
        XCTAssertEqual(ft.unscaledDelta, 0.25, accuracy: 1e-12)
        XCTAssertEqual(ft.fixedDelta, 0.25, accuracy: 1e-12)
    }

    // Deltas larger than maxDelta are clamped for the scaled delta, while unscaledDelta keeps the raw value.
    func testDeltaIsClampedToMaxDelta() {
        var clock = FrameClock(fixedHz: 4)
        _ = clock.tick(now: 0)
        let (ft, _) = clock.tick(now: 0.5)
        XCTAssertEqual(ft.delta, clock.maxDelta, accuracy: 1e-12)
        XCTAssertEqual(ft.unscaledDelta, 0.5, accuracy: 1e-12)
    }

    // timeScale multiplies the delta used for simulation time.
    func testTimeScaleAppliesToDelta() {
        var clock = FrameClock(fixedHz: 4)
        clock.timeScale = 0.5
        _ = clock.tick(now: 0)
        let (ft, _) = clock.tick(now: 0.2)
        XCTAssertEqual(ft.delta, 0.1, accuracy: 1e-12)
        XCTAssertEqual(ft.elapsed, 0.1, accuracy: 1e-12)
    }

    // While paused the simulation delta and elapsed time stop, but the wall-clock delta still reports.
    func testPauseStopsSimulationTime() {
        var clock = FrameClock(fixedHz: 4)
        clock.isPaused = true
        _ = clock.tick(now: 0)
        let (ft, steps) = clock.tick(now: 0.1)
        XCTAssertEqual(ft.delta, 0)
        XCTAssertEqual(ft.elapsed, 0)
        XCTAssertEqual(steps, 0)
        XCTAssertEqual(ft.unscaledDelta, 0.1, accuracy: 1e-12)
    }

    // A leftover fraction of a step is exposed as interpolation alpha in [0, 1).
    func testInterpolationAlphaForPartialStep() {
        var clock = FrameClock(fixedHz: 4)
        _ = clock.tick(now: 0)
        let (ft, steps) = clock.tick(now: 0.125)
        XCTAssertEqual(steps, 0)
        XCTAssertEqual(ft.interpolationAlpha, 0.5, accuracy: 1e-12)
    }

    // The frame index increments once per tick, including the first.
    func testFrameIndexIncrements() {
        var clock = FrameClock(fixedHz: 4)
        _ = clock.tick(now: 0)
        _ = clock.tick(now: 0.1)
        let (ft, _) = clock.tick(now: 0.2)
        XCTAssertEqual(ft.frameIndex, 3)
    }

    // The explicit-delta overload advances the clock relative to the previous tick.
    func testTickWithExplicitDelta() {
        var clock = FrameClock(fixedHz: 4)
        _ = clock.tick(delta: 0)
        let (ft, _) = clock.tick(delta: 0.125)
        XCTAssertEqual(ft.delta, 0.125, accuracy: 1e-12)
    }

    // reset forgets the previous timestamp, so the next tick reports zero delta again.
    func testResetForgetsPreviousTimestamp() {
        var clock = FrameClock(fixedHz: 4)
        _ = clock.tick(now: 0)
        _ = clock.tick(now: 1)
        clock.reset()
        let (ft, _) = clock.tick(now: 5)
        XCTAssertEqual(ft.delta, 0)
    }
}

final class FrameStatisticsTests: XCTestCase {
    // Average, minimum, maximum and count are computed over the samples added so far.
    func testBasicAggregates() {
        var stats = FrameStatistics(capacity: 8)
        for sample in [1.0, 2.0, 3.0] { stats.add(sample) }
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.average, 2, accuracy: 1e-12)
        XCTAssertEqual(stats.minimum, 1)
        XCTAssertEqual(stats.maximum, 3)
    }

    // Once full, the ring buffer keeps only the most recent samples.
    func testCapacityWrapKeepsNewestSamples() {
        var stats = FrameStatistics(capacity: 2)
        for sample in [1.0, 2.0, 3.0] { stats.add(sample) }
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.minimum, 2)
        XCTAssertEqual(stats.average, 2.5, accuracy: 1e-12)
    }

    // Percentile 0 and 100 give the extremes, and the median of three samples is the middle one.
    func testPercentiles() {
        var stats = FrameStatistics(capacity: 3)
        for sample in [1.0, 2.0, 3.0] { stats.add(sample) }
        XCTAssertEqual(stats.percentile(0), 1)
        XCTAssertEqual(stats.percentile(50), 2)
        XCTAssertEqual(stats.percentile(100), 3)
    }

    // Frames at 60 Hz report an average FPS of 60.
    func testAverageFPSFromFrameTimes() {
        var stats = FrameStatistics(capacity: 3)
        for _ in 0..<3 { stats.add(1.0 / 60.0) }
        XCTAssertEqual(stats.averageFPS, 60, accuracy: 1e-6)
    }

    // hitchCount counts frames more than 50 % over the budget.
    func testHitchCountUsesFiftyPercentThreshold() {
        var stats = FrameStatistics(capacity: 3)
        for sample in [0.01, 0.02, 0.04] { stats.add(sample) }
        XCTAssertEqual(stats.hitchCount(budget: 0.01), 2)
    }

    // Sample standard deviation (n - 1 denominator) matches the textbook example.
    func testSampleStandardDeviation() {
        var stats = FrameStatistics(capacity: 8)
        for sample in [2.0, 4, 4, 4, 5, 5, 7, 9] { stats.add(sample) }
        XCTAssertEqual(stats.standardDeviation, (32.0 / 7.0).squareRoot(), accuracy: 1e-9)
    }
}

final class ProfilerTests: XCTestCase {
    // scope runs its body and returns the body's value.
    func testScopeReturnsBodyValue() {
        let profiler = Profiler(historyLength: 4)
        let value = profiler.scope("calc") { 6 * 7 }
        XCTAssertEqual(value, 42)
    }

    // A scope recorded in one frame appears in lastFrame after the next frame begins.
    func testScopeAppearsInLastFrame() {
        let profiler = Profiler(historyLength: 4)
        profiler.beginFrame()
        profiler.scope("work") {}
        profiler.beginFrame()
        XCTAssertEqual(profiler.lastFrame.map(\.name), ["work"])
    }

    // Both the outer and the inner scope of a nested pair are recorded in the frame.
    func testNestedScopesAreAllRecorded() {
        let profiler = Profiler(historyLength: 4)
        profiler.beginFrame()
        profiler.scope("outer") {
            profiler.scope("inner") {}
        }
        profiler.beginFrame()
        XCTAssertEqual(Set(profiler.lastFrame.map(\.name)), ["outer", "inner"])
    }

    // A disabled profiler still runs the body but records nothing.
    func testDisabledProfilerRecordsNothing() {
        let profiler = Profiler(historyLength: 4)
        profiler.isEnabled = false
        profiler.beginFrame()
        XCTAssertEqual(profiler.scope("skipped") { 3 }, 3)
        profiler.beginFrame()
        profiler.beginFrame()
        XCTAssertTrue(profiler.lastFrame.isEmpty)
    }

    // Named counters accumulate within a frame and are reported for the completed frame.
    func testCountersReportLastFrame() {
        let profiler = Profiler(historyLength: 4)
        profiler.beginFrame()
        profiler.count("draws", 2)
        profiler.count("draws", 3)
        profiler.beginFrame()
        XCTAssertEqual(profiler.lastFrameCounters["draws"], 5)
    }

    // Statistics average each scope's calls per frame over the frames in the history window.
    func testStatisticsCallsPerFrame() {
        let profiler = Profiler(historyLength: 8)
        profiler.beginFrame()
        profiler.scope("work") {}
        profiler.beginFrame()
        profiler.scope("work") {}
        profiler.beginFrame()
        let work = profiler.statistics().first { $0.name == "work" }
        XCTAssertEqual(work?.callsPerFrame, 1)
    }

    // The Chrome trace export contains one event per recorded CPU sample.
    func testChromeTraceContainsEvents() throws {
        let profiler = Profiler(historyLength: 4)
        profiler.beginFrame()
        profiler.scope("work") {}
        profiler.beginFrame()
        let data = profiler.exportChromeTrace()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(json["traceEvents"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
    }
}
