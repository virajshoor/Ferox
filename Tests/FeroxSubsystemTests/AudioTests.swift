/// Tests for the platform-independent audio model: distance attenuation formulas, decibel conversion,
/// voice slot allocation, bus settings, and the SilentAudioBackend playback lifecycle. No AVFoundation
/// or audio hardware is involved.
import XCTest
import FeroxCore
@testable import FeroxAudio

final class AudioTests: XCTestCase {

    /// Inverse attenuation halves gain at one rolloff step and clamps distances to the valid range.
    func testInverseAttenuationFollowsFormulaAndClamps() {
        let attenuation = Attenuation(model: .inverse, referenceDistance: 1, maximumDistance: 100, rolloff: 1)
        XCTAssertEqual(attenuation.gain(at: 1), 1, accuracy: 1e-5)
        XCTAssertEqual(attenuation.gain(at: 0.5), 1, accuracy: 1e-5)
        XCTAssertEqual(attenuation.gain(at: 3), 1.0 / 3.0, accuracy: 1e-5)
        XCTAssertEqual(attenuation.gain(at: 500), attenuation.gain(at: 100), accuracy: 1e-5)
    }

    /// Linear and exponential attenuation reach their documented values at sample distances.
    func testLinearAndExponentialAttenuationValues() {
        let linear = Attenuation(model: .linear, referenceDistance: 1, maximumDistance: 11, rolloff: 1)
        XCTAssertEqual(linear.gain(at: 6), 0.5, accuracy: 1e-5)
        XCTAssertEqual(linear.gain(at: 11), 0, accuracy: 1e-5)

        let exponential = Attenuation(model: .exponential, referenceDistance: 2, maximumDistance: 100, rolloff: 2)
        XCTAssertEqual(exponential.gain(at: 4), 0.25, accuracy: 1e-5)
    }

    /// Decibel conversion matches standard reference points and round-trips.
    func testDecibelConversionMatchesReferencePoints() {
        XCTAssertEqual(Decibels.toGain(0), 1, accuracy: 1e-5)
        XCTAssertEqual(Decibels.toGain(-6.0206), 0.5, accuracy: 1e-3)
        XCTAssertEqual(Decibels.toGain(20), 10, accuracy: 1e-3)
        XCTAssertEqual(Decibels.fromGain(0.1), -20, accuracy: 1e-3)
        XCTAssertEqual(Decibels.fromGain(Decibels.toGain(-12)), -12, accuracy: 1e-3)
    }

    /// A free slot is preferred, and when all slots are busy only a lower-priority voice is evicted.
    func testVoiceAllocatorPrefersFreeThenEvictsLowerPriority() {
        let slots = [
            VoiceAllocator.Slot(busy: true, priority: 5, startTime: 1),
            VoiceAllocator.Slot(busy: false, priority: 0, startTime: 0),
        ]
        XCTAssertEqual(VoiceAllocator.choose(slots, priority: 0), 1)

        let full = [
            VoiceAllocator.Slot(busy: true, priority: 5, startTime: 1),
            VoiceAllocator.Slot(busy: true, priority: 1, startTime: 2),
        ]
        XCTAssertEqual(VoiceAllocator.choose(full, priority: 3), 1)
        XCTAssertNil(VoiceAllocator.choose(full, priority: 0))
    }

    /// Among equally prioritised busy voices the oldest one is evicted first.
    func testVoiceAllocatorEvictsOldestOfLowestPriority() {
        let slots = [
            VoiceAllocator.Slot(busy: true, priority: 0, startTime: 5),
            VoiceAllocator.Slot(busy: true, priority: 0, startTime: 2),
        ]
        XCTAssertEqual(VoiceAllocator.choose(slots, priority: 0), 1)
    }

    /// Clips loaded into the silent backend report their metadata and can be unloaded; playing an unknown clip is invalid.
    func testSilentBackendLoadsAndUnloadsClips() throws {
        let backend = SilentAudioBackend()
        let clip = try backend.loadClip(Data(), name: "boom", stream: false)
        let info = try XCTUnwrap(backend.clipInfo(clip))
        XCTAssertEqual(info.name, "boom")
        XCTAssertEqual(info.channels, 1)
        XCTAssertTrue(info.canSpatialize)
        XCTAssertFalse(info.isStreamed)

        backend.unloadClip(clip)
        XCTAssertNil(backend.clipInfo(clip))
        XCTAssertEqual(backend.play(clip, options: PlaybackOptions()), .invalid)
    }

    /// Pause, resume, seek and time advance behave as a simple playback clock.
    func testSilentVoicePlaybackClock() throws {
        let backend = SilentAudioBackend()
        let clip = try backend.loadClip(Data(), name: "tone", stream: false)
        let voice = backend.play(clip, options: PlaybackOptions())
        XCTAssertTrue(backend.isPlaying(voice))

        backend.pause(voice)
        XCTAssertFalse(backend.isPlaying(voice))
        backend.resume(voice)
        XCTAssertTrue(backend.isPlaying(voice))

        backend.seek(voice, to: 0.5)
        backend.update(dt: 0.25)
        XCTAssertEqual(try XCTUnwrap(backend.playbackTime(voice)), 0.75, accuracy: 1e-6)

        backend.update(dt: 0.5)
        XCTAssertFalse(backend.isPlaying(voice))
        XCTAssertNil(backend.playbackTime(voice))
    }

    /// A looping voice wraps its playback time at the clip duration instead of ending.
    func testLoopingVoiceWrapsPlaybackTime() throws {
        let backend = SilentAudioBackend()
        let clip = try backend.loadClip(Data(), name: "loop", stream: false)
        let voice = backend.play(clip, options: PlaybackOptions(loops: true))
        backend.update(dt: 1.5)
        XCTAssertTrue(backend.isPlaying(voice))
        XCTAssertEqual(try XCTUnwrap(backend.playbackTime(voice)), 0.5, accuracy: 1e-6)
    }

    /// Stopping a voice removes it from the active count; only playing voices are counted.
    func testActiveVoiceCountTracksStoppedVoices() throws {
        let backend = SilentAudioBackend()
        let clip = try backend.loadClip(Data(), name: "sfx", stream: false)
        let first = backend.play(clip, options: PlaybackOptions(bus: .sfx))
        _ = backend.play(clip, options: PlaybackOptions(bus: .ui))
        XCTAssertEqual(backend.activeVoiceCount, 2)

        backend.stop(first, fadeOut: 0)
        XCTAssertEqual(backend.activeVoiceCount, 1)
        XCTAssertFalse(backend.isPlaying(first))
    }

    /// Bus settings are stored per bus, and unconfigured buses report defaults.
    func testBusSettingsAreStoredPerBus() {
        let backend = SilentAudioBackend()
        var music = BusSettings()
        music.volume = 0.5
        music.muted = true
        backend.setBus(.music, music)

        XCTAssertEqual(backend.bus(.music).volume, 0.5, accuracy: 1e-6)
        XCTAssertTrue(backend.bus(.music).muted)
        XCTAssertEqual(backend.bus(.sfx).volume, 1, accuracy: 1e-6)
        XCTAssertFalse(backend.bus(.sfx).muted)
    }
}
