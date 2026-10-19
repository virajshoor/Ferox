# Platform Support

Ferox is a Swift package for macOS. Its primary target is Apple Silicon Macs running macOS 14 or later, as stated in [CONTRIBUTING.md](../CONTRIBUTING.md). Most of the engine is ordinary Swift with no platform dependency, so the simulation core can be built and tested on Linux. The Metal renderer, windowing, and several system backends exist only on Apple platforms.

This document lists what each platform gets, where the platform boundaries are in the source, and what the continuous integration (CI) workflow builds. The package has been built and run on one Apple Silicon Mac, an M1 Max with macOS 27 and Swift 6.4, as section 8 records. No CI result is quoted. This document was first written without a macOS or Swift toolchain available.

## Contents

1. [Targets and minimum versions](#1-targets-and-minimum-versions)
2. [What runs where](#2-what-runs-where)
3. [Compile-time guards](#3-compile-time-guards)
4. [Apple Silicon and GPU capability tiers](#4-apple-silicon-and-gpu-capability-tiers)
5. [Continuous integration](#5-continuous-integration)
6. [Running without Metal](#6-running-without-metal)
7. [Limitations](#7-limitations)
8. [Validation status](#8-validation-status)
9. [Related documents](#9-related-documents)

## 1. Targets and minimum versions

| Item | Value | Source |
| --- | --- | --- |
| Swift tools version | 5.10 | `Package.swift`, first line |
| Minimum platform | macOS 14 (`.macOS(.v14)`) | `Package.swift`, `platforms` |
| Primary hardware | Apple Silicon | `CONTRIBUTING.md` |
| Architecture restriction in the package | None declared | `Package.swift` |
| Third-party package dependencies | None declared | `Package.swift` has no `.package(...)` entries |
| Debug-only compile flag | `FEROX_DEBUG`, defined in the debug configuration | `Package.swift`, `swiftSettings` |

No architecture-specific code path was found in `Sources`. A search for `arm64`, `x86_64`, `Rosetta` and `Intel` found only comments. Apple Silicon is therefore the stated target and not an enforced one.

The shared `swiftSettings` also enable three upcoming Swift features, `BareSlashRegexLiterals`, `ConciseMagicFile` and `ExistentialAny`, for the library, tool and example targets. The test targets do not take these settings.

## 2. What runs where

The package header in `Package.swift` says that every module is platform-independent except `FeroxRender`, the audio and input backends, and the platform backends of `FeroxUI`. The table below lists the portable part and the Apple-only part of each module.

| Module | Portable part | Apple-only part |
| --- | --- | --- |
| `FeroxMath` | All of it. | None. |
| `FeroxCore` | Logging, events, profiler, time, path validation, graphics settings and capability resolution. | Monotonic clock uses `Darwin` where available. Unified logging uses `os`, but only when `ConsoleLogSink(useUnifiedLogging: true)` is set. |
| `FeroxScene` | ECS, serialisation, scene manager and systems. | None. |
| `FeroxPhysics` | 2D and 3D worlds and the ECS bridge. | None. |
| `FeroxAnimation` | Clips, animators, tweens, timelines and particle simulation on the CPU. | None. |
| `FeroxInput` | `InputSystem`, action maps, recording and playback. | `MacInputBackend` (AppKit and GameController). |
| `FeroxAssets` | Asset database, glTF importer, Netpbm and PFM image decoder, Tiled importer. | ImageIO decoding of PNG, JPEG, HEIC and other formats. |
| `FeroxNet` | Protocol, connections, server, client, replication and loopback transport. | `UDPTransport` (Network.framework). |
| `FeroxAudio` | Audio model, mixer rules and `SilentAudioBackend`. | `AVAudioBackend` (AVFoundation). |
| `FeroxUI` | Layout, controls, draw lists and `MonospaceFontProvider`. | `CoreTextFontProvider`. |
| `FeroxRender` | CPU-side batching, tessellation, render maths and GPU type layouts. | Everything under `Sources/FeroxRender/Metal`, which is the Metal renderer. |
| `Ferox` | `Engine`, `Game`, `EditorSession`, `GameLauncher` in headless mode. | `GameHost` and `GameView` (AppKit and MetalKit). |
| `FeroxEditor` | The editing logic in `EditorSession`. | The window and the Metal view. On other platforms it explains that it needs Metal and exits. |
| `FeroxDiag` | The report and the preset table. | `--render` and the device probe. |

## 3. Compile-time guards

The table lists each `#if` guard found by searching `Sources` for `canImport`, with the code it controls.

| Guard | File | Controls |
| --- | --- | --- |
| `canImport(Darwin)` | `Sources/FeroxCore/Time.swift` | Monotonic clock source. |
| `canImport(os)` | `Sources/FeroxCore/Logging.swift` | Unified logging in the console sink. |
| `canImport(ImageIO) && canImport(CoreGraphics)` | `Sources/FeroxAssets/ImageDecoder.swift` | ImageIO decoding. Without it, only Netpbm and PFM decode, and other formats raise `unsupportedFormat`. |
| `canImport(AVFoundation)` | `Sources/FeroxAudio/AVAudioBackend.swift`, `Sources/Ferox/Engine.swift` | `AVAudioBackend`. Without it, `SilentAudioBackend` is used. |
| `canImport(Network)` | `Sources/FeroxNet/Transport.swift` | `UDPTransport`. |
| `canImport(AppKit) && canImport(GameController)` | `Sources/FeroxInput/MacInputBackend.swift` | macOS input backend. |
| `canImport(CoreText) && canImport(CoreGraphics)` | `Sources/FeroxUI/CoreTextFonts.swift` | `CoreTextFontProvider` and its glyph atlas page. |
| `canImport(CoreText)` | `Sources/Ferox/Engine.swift`, `Sources/FeroxRender/Metal/Renderer.swift` | The engine picks `CoreTextFontProvider`, or `MonospaceFontProvider` when CoreText is missing. |
| `canImport(Metal)` | 11 files in `Sources/FeroxRender/Metal/` | The whole Metal renderer. The guard is at the top of each file. |
| `canImport(MetalFX)` | `PostProcessor.swift`, `RenderDevice.swift` | MetalFX scalers. Inside the Metal guard. |
| `canImport(AppKit) && canImport(MetalKit)` | `Sources/Ferox/GameHost.swift`, `Sources/Ferox/Launcher.swift`, `Sources/FeroxEditor/FeroxEditor.swift` | The window host. `GameLauncher` runs headless when this is missing. |
| `canImport(Metal)` | `Sources/FeroxDiag/FeroxDiag.swift`, `Sources/FeroxBenchmarks/FeroxBenchmarks.swift` | Device probing and the render smoke test. |

`FeroxRender` declares no Metal import outside the guarded folder. Its portable files do not depend on Metal, so the Linux build of `Ferox` can compile them.

## 4. Apple Silicon and GPU capability tiers

`DeviceCapabilities.appleFamily` records the highest `MTLGPUFamily.appleN` the device supports, as the source comment states: 7 for M1 and A14, 8 for M2 and A15 to A16, and 9 for M3, M4 and A17 or later. The renderer does not assume a family. It checks each optional feature through a runtime query. Two consequences follow:

- `hasHardwareRayTracing` is true only when ray tracing is supported and the family is 9 or later. On devices that support ray tracing but do not have it, the resolver keeps the effects and reduces their budget, as the source comment says the shader cores run them. See [11-Ray-Tracing.md](11-Ray-Tracing.md).
- MetalFX is used only when the device reports support for it. Otherwise the automatic upscaler selects Ferox's own scaler. See [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md).

The full capability model, and the rules that map settings onto it, are in [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md).

## 5. Continuous integration

The workflow is `.github/workflows/ci.yml`. It has four jobs. Image tags are pinned by digest. See [04-Building-and-Testing.md](04-Building-and-Testing.md).

**macOS build and test** runs on `macos-15`. It requires `/Applications/Xcode_16.4.app` and fails if that bundle is missing. It then builds in debug, runs `swift test --enable-xctest --parallel`, compiles every shader module with `Scripts/compile-shaders.sh`, and builds in release.

**Linux Swift 5.10** is the tools-version floor (`swift:5.10` by digest). It builds `Ferox` and runs all seven test targets with warnings as errors. It does not pass `--enable-xctest`.

**Linux Swift 6.2** (`swift:6.2` by digest) lints with `swift format` and runs `swift test --enable-xctest --parallel`.

**Markdown links** runs lychee in offline mode over `README.md` and `Docs/**/*.md`, and fails on a broken relative link.

The workflow says what it runs, not what it found. This document does not cite any CI result. The benchmark workflow, `.github/workflows/benchmarks.yml`, has a comment that hosted macOS runners use virtualised GPUs. Its numbers are for spotting large regressions only, and the same applies to any timing taken on a hosted runner.

## 6. Running without Metal

On a system without Metal, or on Linux, the following still work:

- `swift run FeroxDiag` prints the report with the baseline capability set. See [27-Troubleshooting.md](27-Troubleshooting.md).
- `GameLauncher` runs a game with `--headless` and simulates a fixed number of frames. The launcher's doc comment calls this the only mode on platforms without Metal. Other arguments are ignored and belong to the game.
- Audio falls back to `SilentAudioBackend`. The engine logs a warning when AVFoundation output is unavailable.
- Text uses `MonospaceFontProvider`. See [section 7](#7-limitations) for its limits.
- Networking works through `LoopbackTransport`. `UDPTransport` is available only where Network.framework is.

The editor needs Metal. Its launcher explains that and exits.

## 7. Limitations

- Only one Mac has been tested: an M1 Max running macOS 27. The Metal renderer draws offscreen there. MetalFX and the macOS CI job are unverified, and other Macs and GPUs are untested.
- The monospace text provider is a placeholder: it renders white boxes, as recorded in [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md). Only platforms without CoreText use it.
- The `Ferox` target depends on `FeroxRender`, so the Linux build of `Ferox` depends on the Metal-guarded files compiling to nothing. Whether that build succeeds has not been confirmed in this snapshot.

## 8. Validation status

- A local macOS build (`swift build --build-tests`, zero warnings) and full `swift test` run pass on the M1 Max. No CI result is cited.
- The Linux portable build and tests are configured in CI but are not reported here.
- No benchmark numbers are given. Measurements should be taken on a named Mac, as [CONTRIBUTING.md](../CONTRIBUTING.md) asks.

## 9. Related documents

- [02-Getting-Started.md](02-Getting-Started.md): installing the toolchain and building the first target.
- [04-Building-and-Testing.md](04-Building-and-Testing.md): build and test commands, including the Linux subset.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): capability-driven resolution.
- [26-Security.md](26-Security.md): the platform-dependent security surface, such as the UDP transport.
- [27-Troubleshooting.md](27-Troubleshooting.md): what to do when a platform cannot provide a feature.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md): verification status and known gaps.
