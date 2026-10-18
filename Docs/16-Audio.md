# Audio

Ferox's audio lives in the `FeroxAudio` module. It has one interface, `AudioBackend`, and two implementations. `AVAudioBackend` is built on `AVAudioEngine` and is used on macOS. `SilentAudioBackend` tracks clips, voices and bus settings without producing sound, and is used for headless runs, tests and any platform where the AVFoundation backend cannot start. The engine creates one backend at startup and exposes it as `Engine.audio`.

The backend plays sound and handles spatial positioning, distance attenuation, looping, fades and voice stealing. Game code talks to it through clip IDs and `VoiceHandle` values, never through `AVAudio` types. Nothing in this module has been run on a Mac. The `AVAudioEngine` graph, the HRTF rendering and device-change recovery are unverified on hardware.

Engine integration (the frame order that calls `audio.update` and the listener update) is described in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). Asset loading of audio files is covered in [18-Assets.md](18-Assets.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [Architecture](#2-architecture)
3. [Loading clips](#3-loading-clips)
4. [Playing and controlling voices](#4-playing-and-controlling-voices)
5. [Voice pool and stealing](#5-voice-pool-and-stealing)
6. [Buses](#6-buses)
7. [Spatialisation and attenuation](#7-spatialisation-and-attenuation)
8. [Looping, fades and completion](#8-looping-fades-and-completion)
9. [Threading and device changes](#9-threading-and-device-changes)
10. [The silent backend](#10-the-silent-backend)
11. [Code examples](#11-code-examples)
12. [Limitations](#12-limitations)
13. [Validation status](#13-validation-status)
14. [Related documents](#14-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| `AudioBackend` protocol and value types | Implemented: `AudioModel.swift`. |
| `AVAudioBackend` (decode, stream, play, bus graph) | Implemented: `AVAudioBackend.swift`, compiled only where `AVFoundation` is available. **Not run on hardware.** |
| `SilentAudioBackend` | Implemented: state tracking only, no output. |
| Spatial audio, distance attenuation | Implemented via `AVAudioEnvironmentNode` for mono clips. **Not verified.** |
| Per-bus volume, mute, attenuation and reverb send | Implemented through the bus environment nodes. |
| Effects other than reverb send (EQ, filters, compression) | **Not implemented.** No effect units are created. |
| Memory budget for audio | Implemented: `memoryBudgetBytes`, set from `MemoryBudget.audioBytes` at engine start. A clip that would exceed it is streamed instead of decoded. |
| Automated tests | `Tests/FeroxSubsystemTests/AudioTests.swift` covers attenuation, decibels, voice allocation, the memory policy and the silent backend. |

## 2. Architecture

`Engine.init` calls a private factory, `makeAudioBackend(enabled:)`. When `EngineConfiguration.enableAudio` is `true` and `AVFoundation` is available, it tries to create an `AVAudioBackend`. If that throws, it logs a warning and falls back to `SilentAudioBackend`. `GameLauncher.runHeadless` always disables audio.

Each engine tick does two things with audio:

1. `updateAudioListener()` looks up the active camera and calls `setListener(position:forward:up:)` with its world transform.
2. `audio.update(dt:)` is called with the unscaled frame delta, so fades and cleanup continue while the game is paused.

`AudioBackend` is a protocol with about twenty methods: loading and unloading clips, `play`, `stop`, `pause`, `resume`, `seek`, `setVolume`, `setPosition`, `setRate`, `isPlaying`, `playbackTime`, listener and bus control, and `update`. `activeVoiceCount` reports voices that are playing and not paused.

`AVAudioBackend` builds this graph for each play:

- An `AVAudioPlayerNode` per voice. There are `maxVoices` of them, 48 by default.
- One `AVAudioEnvironmentNode` per bus, except `master`. Each environment connects to the main mixer.
- The main mixer, whose output volume is set by the `master` bus.

## 3. Loading clips

Clips are loaded from data or a URL. The result is an `AudioClipID`, and `clipInfo(_:)` returns the metadata:

- `loadClip(url:stream:)` opens the file with `AVAudioFile`.
- `loadClip(_:name:stream:)` writes the bytes to a temporary file first, because `AVAudioFile` reads from URLs. The temporary file is removed at once for decoded clips, and kept until `unloadClip` for streamed clips.

With `stream: false` the whole clip is decoded into an `AVAudioPCMBuffer`. A fixed cap rejects files longer than `48_000 * 60 * 10` frames (ten minutes at 48 kHz, slightly longer at lower sample rates). Longer clips must be streamed. With `stream: true` the file is kept open and read in segments.

**Memory budget.** `memoryBudgetBytes` caps the memory held by decoded clips, and `decodedBytes` reports what they hold now. A decoded clip costs frames × channels × 4 bytes (`AudioMemoryPolicy.decodedBytes`). When decoding a clip would push the total over the budget, the backend streams it instead and logs a warning; the clip still plays. A budget of zero or less streams every clip. Streamed clips are not counted. `unloadClip` returns a clip's bytes. `Engine` copies `assets.budget.audioBytes` into the backend once, at start-up; a later change to the asset budget must be copied by hand. Lowering the budget does not affect clips already decoded.

```swift
engine.audio.memoryBudgetBytes = 64 << 20
let ambience = try engine.audio.loadClip(url: ambienceURL, stream: false)
if engine.audio.clipInfo(ambience)?.isStreamed == true { print("over budget: streamed") }
```

`AudioClipInfo` reports the name, duration, sample rate, channel count and whether the clip is streamed. `canSpatialize` is `true` only for mono clips. A stereo clip played with a position is played as 2D.

Supported formats are whatever `AVAudioFile` reads on macOS: WAV, AIFF, CAF, MP3, AAC/M4A, ALAC and FLAC, according to the backend's header comment. Channel counts from 1 to 8 are accepted.

## 4. Playing and controlling voices

`play(_:options:)` takes a `PlaybackOptions` value and returns a `VoiceHandle`. The handle holds an index and a generation, so it becomes invalid when its voice is stopped, stolen or reused. `VoiceHandle.invalid` is returned when the clip is unknown, when the destination bus has no environment, or when every busy voice outranks the request.

`PlaybackOptions` fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `bus` | `.sfx` | Destination bus. `.master` plays through the `sfx` environment. |
| `volume` | `1` | Initial voice volume. |
| `rate` | `1` | Playback rate, clamped to 0.5 to 2. Changes pitch and speed together. |
| `loops` | `false` | Loop the clip. |
| `position` | `nil` | World position. `nil` plays 2D. |
| `priority` | `0` | Used for voice stealing. |
| `startTime` | `0` | Start offset in seconds, clamped to the clip duration. |
| `fadeIn` | `0` | Seconds to fade in from silence. |

Once playing, the handle accepts:

- `stop(_:fadeOut:)`. With a non-zero fade the voice ramps to silence and then stops.
- `stopAll(fadeOut:)` stops every voice, with the same fade rules. `Engine.shutdown()` calls it with no fade.
- `pause` and `resume`, which keep the playback position.
- `seek(_:to:)`, which reschedules the clip from a new time.
- `setVolume`, `setPosition` and `setRate`.
- `isPlaying`, which is `false` for a paused or finished voice, and `playbackTime`, which returns the position in seconds, wrapped for looping voices.

## 5. Voice pool and stealing

Voices are a fixed pool. `VoiceAllocator.choose` picks the first free voice. If none is free, it picks the busy voice with the lowest priority, breaking ties by the oldest start time. That voice is stolen only if its priority is less than or equal to the new voice's priority. Otherwise `play` returns `VoiceHandle.invalid` and nothing plays.

A stolen voice stops at once, and its generation is incremented, so old handles stop working. Completion handlers from an earlier schedule check a schedule ID, so a stale completion cannot finish a newer voice.

## 6. Buses

`AudioBus` has six cases: `master`, `music`, `sfx`, `ui`, `voice` and `ambience`. Each has a `BusSettings` value with:

- `volume` and `muted`.
- `attenuation`, an `Attenuation` value (see the next section).
- `reverbBlend`, a send level from 0 to 1 applied to positional voices started on that bus.

`setBus(_:_:)` on `master` sets the main mixer's output volume (zero when muted). On any other bus it updates that bus's environment node. Changes apply to the environment immediately, but the reverb send is read only when a voice starts, so an existing voice keeps the send it was started with.

The `master` bus has no environment node of its own. Voices addressed to `master` play through the `sfx` environment, so they also receive the `sfx` bus settings. The `master` settings act on the main mixer's output and therefore affect every bus.

## 7. Spatialisation and attenuation

A voice is spatialised when it has a position and its clip is mono. Spatial voices use `HRTFHQ` rendering in the environment node. Other voices use stereo pass-through. The listener is updated every frame from the active camera, with its position and forward and up vectors.

`Attenuation` holds a model, a reference distance, a maximum distance and a rolloff. `AttenuationModel` has three cases, and `Attenuation.gain(at:)` implements the same formulas in plain Swift:

- `inverse`: `ref / (ref + rolloff × (d − ref))`. The default.
- `linear`: falls from 1 at the reference distance to 0 at the maximum.
- `exponential`: `(d / ref)^(−rolloff)`.

The distance is clamped between the reference and maximum distances before the formula is applied. The bus applies these settings to its environment node, so attenuation is per bus, not per voice.

`Decibels.toGain` and `Decibels.fromGain` convert between decibels and linear gain.

## 8. Looping, fades and completion

Decoded clips loop by scheduling the buffer with the `.loops` option. When a voice starts part way through a clip and loops, the remainder is played once and then the whole buffer loops.

Streamed clips loop differently. When a segment finishes, the backend schedules the clip again from the start on the main queue. This is not sample-accurate: there can be a small gap at the loop point. The source comment calls it "gapless-enough".

Fades run in `update(dt:)`. A fade-in starts the voice at zero volume and ramps to the target. A fade-out ramps to zero and then stops the voice. The ramp speed is scaled by the voice's volume, so a quiet voice fades more slowly than a loud one over the same fade time.

When a non-looping voice finishes, `update` stops it and frees its slot. `isPlaying` returns `false` at that point.

## 9. Threading and device changes

Call every `AVAudioBackend` method from the main thread. The source comment says that AVAudioEngine renders on a real-time thread, and that completion callbacks only set flags, with clean-up happening in `update`.

When the output device changes, the backend receives `AVAudioEngineConfigurationChange`, logs a warning and restarts the engine. The code does not reschedule voices that were playing. This path has not been tested on hardware.

`AVAudioBackend.deinit` removes the notification observer, stops the engine and deletes any temporary stream files.

## 10. The silent backend

`SilentAudioBackend` keeps clips, voices and buses in dictionaries. Clips report a fixed duration of one second, a sample rate of 48 kHz and one channel. Each clip is charged its data size against `memoryBudgetBytes`, using the same policy as the AVFoundation backend. Voices advance their playback time in `update` and finish when they reach the duration, unless they loop. `setVolume`, `setPosition`, `setRate` and `setListener` do nothing. It is deterministic, so game logic that depends on `isPlaying` or `activeVoiceCount` can be tested without sound.

## 11. Code examples

Playing music on a loop, with a volume set on its bus:

```swift
let music = try engine.audio.loadClip(url: musicURL, stream: true)
let track = engine.audio.play(music, options: PlaybackOptions(bus: .music, volume: 0.6, loops: true))

var musicBus = engine.audio.bus(.music)
musicBus.volume = 0.5
engine.audio.setBus(.music, musicBus)
```

A positional effect with distance attenuation, a priority, and a fade-out:

```swift
var sfxBus = engine.audio.bus(.sfx)
sfxBus.attenuation = Attenuation(model: .inverse, referenceDistance: 2, maximumDistance: 60, rolloff: 1.2)
engine.audio.setBus(.sfx, sfxBus)

let shot = try engine.audio.loadClip(url: shotURL, stream: false)
var options = PlaybackOptions(bus: .sfx, position: Vec3(4, 0, -2))
options.priority = 5
let voice = engine.audio.play(shot, options: options)

engine.audio.setPosition(voice, Vec3(4.5, 0, -2))
engine.audio.stop(voice, fadeOut: 0.25)
```

Testing game logic against the silent backend:

```swift
let audio = SilentAudioBackend()
let clip = try audio.loadClip(Data(), name: "test.wav", stream: false)
let voice = audio.play(clip, options: PlaybackOptions())
audio.update(dt: 2)                 // the one-second clip has finished
assert(!audio.isPlaying(voice))
```

Choosing a voice to steal, from the allocator's own API:

```swift
let slots = [
    VoiceAllocator.Slot(busy: true, priority: 0, startTime: 1.0),
    VoiceAllocator.Slot(busy: true, priority: 3, startTime: 2.0),
]
let index = VoiceAllocator.choose(slots, priority: 1)   // 0: the lowest-priority voice is stolen
```

## 12. Limitations

- **No effects chain.** The backend creates no equaliser, filter or compressor units. The reverb send is the only per-voice effect.
- **Stereo clips cannot be positioned.** A stereo clip with a position plays 2D.
- **Streamed loops are not sample-accurate.** Looping is rescheduled on the main queue.
- **The budget streams, it does not evict.** Over-budget clips are streamed rather than decoded, and no decoded clip is ever evicted, because that would invalidate its `AudioClipID`. The budget is copied from `MemoryBudget.audioBytes` only at engine start.
- **The decode cap is a frame count.** The ten-minute limit is a fixed 28.8 million frames, which is ten minutes at 48 kHz and a little longer at lower rates.
- **Bus reverb send is read at start.** Changing `reverbBlend` does not affect voices already playing.
- **Main thread only.** The backend is marked `@unchecked Sendable` and is not safe to call from other threads.
- **Device-change recovery is untested.** Voices in flight are lost on a restart.
- **Silent backend ignores volume and position.** Logic that depends on those values cannot be checked with it.

## 13. Validation status

This document was written from the source. No macOS machine or Swift toolchain was available while the engine was written, so nothing in the audio path has been compiled, run or listened to. No latency, CPU cost or voice-count figures are reported.

`Tests/FeroxSubsystemTests/AudioTests.swift` tests `Attenuation`, `Decibels`, `VoiceAllocator`, `AudioMemoryPolicy` and `SilentAudioBackend`, including its budget accounting and `stopAll`. `AVAudioBackend` needs AVFoundation and audio hardware and has no automated tests. None of the tests have been run yet. The HRTF rendering, bus routing and device-change restart have not been verified on hardware.

## 14. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md) for the frame order in which audio is updated.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md) for the entities that carry positions for spatial sources.
- [18-Assets.md](18-Assets.md) for asset loading and the `MemoryBudget` type.
- [20-Gameplay-API.md](20-Gameplay-API.md) for how a `Game` reaches `engine.audio`.
- [21-Performance.md](21-Performance.md) for the memory tracker and profiler.
- [25-Platform-Support.md](25-Platform-Support.md) for which platforms get the AVFoundation backend.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md) for the wider list of known gaps.
