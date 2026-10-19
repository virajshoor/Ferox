# Building and Testing

This document describes how to build Ferox, which test targets the package declares and what they cover, what the continuous integration (CI) workflows check, how the two command-line tools `FeroxDiag` and `FeroxBenchmarks` are used, and how Metal shaders are validated. The commands are those in `Package.swift`, `.github/workflows/ci.yml`, `.github/workflows/benchmarks.yml`, `CONTRIBUTING.md` and the tool sources. None of them has been run against this snapshot. See [01-Overview.md](01-Overview.md), section 7.

## Contents

1. [Toolchain](#1-toolchain)
2. [Building](#2-building)
3. [Test targets](#3-test-targets)
4. [Running tests](#4-running-tests)
5. [Continuous integration](#5-continuous-integration)
6. [FeroxDiag](#6-feroxdiag)
7. [FeroxBenchmarks](#7-feroxbenchmarks)
8. [Shader validation](#8-shader-validation)
9. [Code style](#9-code-style)
10. [Validation status](#10-validation-status)
11. [Limitations](#11-limitations)
12. [Related documents](#12-related-documents)

## 1. Toolchain

| Item | Value | Source |
| --- | --- | --- |
| Swift tools version | 5.10 | `Package.swift` |
| Xcode | 15.4 or later (CI selects 15.4 when present) | `CONTRIBUTING.md`, `ci.yml` |
| macOS | 14 or later | `Package.swift` |
| Swift upcoming features | `BareSlashRegexLiterals`, `ConciseMagicFile`, `ExistentialAny` | `Package.swift`: `swiftSettings` |
| Debug-only define | `FEROX_DEBUG`, set in the debug configuration | `Package.swift`: `swiftSettings` |

`FEROX_DEBUG` is read by `Sources/FeroxCore/Logging.swift`. `FeroxBenchmarks` also checks `#if DEBUG` to warn that a debug build produces numbers that are not representative.

## 2. Building

```sh
swift build                       # debug build, every product and target
swift build -c release            # optimised build
swift build --target FeroxMath --target FeroxCore    # the portable modules only
swift run HelloFerox --headless --frames 120
```

The third form is the one the Linux job runs. `--target` restricts the build to the named targets and their dependencies. The last form is a smoke test that CI does not run. Benchmarks need a release build, because the tool warns that a debug build's numbers are not representative. See section 7.

The package has no external dependencies, so there is no resolution step. Metal sources are not compiled by the build. See section 8.

## 3. Test targets

`Package.swift` declares seven test targets. Every one has sources under `Tests/`.

| Test target | Depends on | Covers |
| --- | --- | --- |
| `FeroxMathTests` | `FeroxMath` | Vectors, quaternions, matrices, geometry, colour, random numbers |
| `FeroxCoreTests` | `FeroxCore` | Time, events, logging, graphics settings and the feature resolver, safe paths, decode limits, handle pools |
| `FeroxSceneTests` | `FeroxScene`, `FeroxCore` | World, hierarchy and transforms, serialisation, systems, scene manager |
| `FeroxPhysicsTests` | `FeroxPhysics`, `FeroxScene`, `FeroxCore` | Both physics worlds and the ECS bridge |
| `FeroxSubsystemTests` | `FeroxInput`, `FeroxAnimation`, `FeroxAssets`, `FeroxNet`, `FeroxUI`, `FeroxAudio`, `FeroxScene`, `FeroxCore` | Input, animation and CPU particles, assets, networking, UI layout, audio maths and the silent backend |
| `FeroxRenderTests` | `FeroxRender`, `Ferox` | The CPU side of the renderer: render maths, uniforms, dynamic resolution, tessellation, debug drawing, sprite batching, scene extraction |
| `FeroxIntegrationTests` | `Ferox` | Engine lifecycle, editor session (undo, Play/Stop, save and load), launcher |

The portable tests need no GPU, so all seven targets run on Linux. The suite is 537 XCTest tests on Swift 6.2.3 (Linux). `MetalDeviceTests` is compiled only where Metal exists: it constructs a `Renderer` (which compiles the shaders) and probes MetalFX, and it skips with a stated reason when `MTLCreateSystemDefaultDevice()` is nil. On Swift 6.2, `swift test` without `--enable-xctest` can exit 0 after running zero tests, so use the flag below. An earlier Mac run of a previous suite (504 tests, Swift 6.4) passed.

## 4. Running tests

```sh
swift test --enable-xctest                 # every XCTest target (required on Swift 6.2)
swift test --enable-xctest --parallel       # what the macOS CI job should run
swift test --filter FeroxPhysicsTests       # one target
swift test --filter "FeroxMathTests|FeroxCoreTests|FeroxSceneTests|FeroxPhysicsTests|FeroxSubsystemTests|FeroxRenderTests|FeroxIntegrationTests"
                                            # what the Linux CI job runs
```

`CONTRIBUTING.md` requires that a pull request includes tests for new behaviour and that `swift test` passes locally. Pass `--enable-xctest` on Swift 6 so the runner cannot report success after executing zero tests. Swift 5.10 does not have that flag; XCTest is its only runner. `swift format lint --strict --recursive Sources Tests Package.swift` matches the Swift 6.2 CI job (configuration in `.swift-format`).

## 5. Continuous integration

Three workflows are defined under `.github/workflows`.

### 5.1 `ci.yml`

The workflow runs on pushes to `main` and on every pull request. Concurrent runs for the same ref are cancelled. It has three jobs.

| Job | Runner | Steps |
| --- | --- | --- |
| `build-and-test` | `macos-15` | Requires `/Applications/Xcode_16.4.app` (`xcode-select` fails the job if it is missing). Builds in debug, runs `swift test --enable-xctest --parallel`, compiles every `.metal` module with `Scripts/compile-shaders.sh` (`xcrun metal`, Common.metal prepended, `-std=metal3.0`), then builds in release. |
| `linux-swift-5-10` | `ubuntu-latest`, `swift:5.10` pinned by digest | Tools-version floor. Builds `Ferox` and runs all seven test targets with `-warnings-as-errors`. Does not pass `--enable-xctest` (that flag is not in Swift 5.10). |
| `linux-swift-6-2` | `ubuntu-latest`, `swift:6.2` pinned by digest | `swift format lint --strict` on `Sources`, `Tests` and `Package.swift`, then `swift test --enable-xctest --parallel`. |
| `docs` | `ubuntu-latest` | Runs `lycheeverse/lychee-action` with `--offline --no-progress README.md "Docs/**/*.md"` and fails on any broken link. |

One point follows from the file as written:

- **The `docs` job checks local links only.** With `--offline`, lychee does not check remote URLs, but it does check relative paths, so each relative link in `README.md` and `Docs/` must point to a file that exists.

### 5.2 `benchmarks.yml`

The workflow is started by hand (`workflow_dispatch`). It runs `swift run -c release FeroxBenchmarks --quick --output BenchmarkResults/ci.json` on `macos-15` with Xcode 16.4 required, and uploads the JSON as an artifact.

The workflow's own comment states that hosted macOS runners use virtualised GPUs, and that the numbers "are useful for spotting large regressions and trends only. They are not representative of Apple Silicon hardware." Performance claims must come from local release runs. See section 7.

### 5.3 Pull request template and checklist

`CONTRIBUTING.md` lists what a pull request must contain: tests, documentation updates including `///` comments on public API, an entry in `CHANGELOG.md` under `[Unreleased]`, no secrets, no generated files, and a formatting check. The checklist is not enforced by a workflow in this snapshot.

## 6. FeroxDiag

`FeroxDiag` prints what Ferox detects on the machine and how each quality preset resolves against it. It is intended to be attached to bug reports. It sends nothing over a network.

```sh
swift run FeroxDiag            # human-readable report
swift run FeroxDiag --json     # machine-readable, sorted keys, pretty-printed
swift run FeroxDiag --render   # also renders one offscreen frame as a smoke test
swift run FeroxDiag --help     # usage line
```

The report contains:

- the Ferox version (`FeroxVersion.string`), the operating system, the processor count and the memory size;
- whether Metal is available, and if so the GPU name, the Apple GPU family, Metal 3 support, unified memory, ray-tracing support, MetalFX support, supported MSAA counts, the working set and the maximum buffer length;
- for each of the four presets `low`, `medium`, `high` and `ultra`: the anti-aliasing mode, the MSAA sample count, the upscaler, the render scale, the internal size for a 2560 by 1440 output, the ray-traced effects, and the fallbacks the resolver applied.

Without Metal, the presets are resolved against `DeviceCapabilities.baseline`, which has no optional features. `ultra` is resolved with the `balanced` ray-tracing preset, as the source defines it.

`--render` creates a renderer, draws a lit cube into a 256 by 256 offscreen texture, reads the pixels back, and reports the count of non-black pixels. It is a smoke test. It reports that the path works, not that the image is correct. It needs Metal.

## 7. FeroxBenchmarks

`FeroxBenchmarks` runs repeatable micro-benchmarks of the engine's hot paths, and on macOS a set of offscreen GPU frames. Every number it prints is measured on the machine that runs it.

```sh
swift run -c release FeroxBenchmarks                     # full run, text report
swift run -c release FeroxBenchmarks --quick             # fewer iterations, as in CI
swift run -c release FeroxBenchmarks --output out.json   # also writes JSON
swift run -c release FeroxBenchmarks --filter physics    # only names containing the text
swift run -c release FeroxBenchmarks --help
```

The CPU benchmarks, by name, are:

| Name | Unit |
| --- | --- |
| `ecs.create+destroy` | entities/s |
| `ecs.forEach(Transform)` | components/s |
| `transform.hierarchy` | entities/s |
| `physics2d.pile.60steps` | body-steps/s |
| `physics3d.pile.60steps` | body-steps/s |
| `events.enqueue+flush` | events/s |
| `math.mat4-multiply` | products/s |
| `engine.tick(empty scene)` | ticks/s |

On a machine with Metal, one GPU benchmark per quality preset is added: `gpu.offscreen-1080p.<preset>`, measured in frames per second. Each one renders 1920 by 1080 frames. The `--quick` form renders 10 frames, and the full run renders 60. Each preset gets its own renderer, created before timing starts, so that pipeline compilation is not measured.

Each result records the mean, median, minimum and maximum time per iteration in milliseconds, and an optional throughput with its unit. The JSON report records the Ferox version, the date, the operating system, the processor count, the memory size, the build configuration (`debug` or `release`), whether `--quick` was used, the GPU name, and the results.

Two rules come from the tool's documentation. A debug build prints a warning, and its numbers should not be used. Results are comparable only between runs on the same machine, configuration and power state. The results of a run are not claims about Apple Silicon in general, and this document does not quote any.

## 8. Shader validation

There is no separate shader validator in the repository, and the build does not compile Metal code. Shaders are compiled at run time.

- **Where the sources are.** `Sources/FeroxRender/Shaders` holds `Common.metal` and the modules `Mesh`, `Post`, `Sky`, `Clusters`, `Culling`, `Debug`, `Particles`, `Sprite`, `UI` and `RayTracing`. `ShaderLibrary.modules` lists the modules in compilation order. `Common.metal` is not listed, because it is prepended as text to every module when that module is compiled.
- **How they are compiled.** `ShaderLibrary` reads each module's source, prepends `Common.metal`, and calls `device.makeLibrary(source:options:)` with Metal language version 3.0 and `preserveInvariance` on. The renderer compiles all modules when it is created. A module that fails to compile is recorded in `ShaderLibrary.failures` with the compiler's message. On a hot reload, the previous library is kept.
- **Required modules.** `ShaderLibrary.requiredModules` is `Mesh`, `Post`, `Sky`, `Sprite`, `UI` and `Debug`. The renderer cannot run without these. Other modules, such as `RayTracing`, are optional.
- **Where a development copy comes from.** Setting the environment variable `FEROX_SHADER_DIR`, or passing `shaderDirectory` through `EngineConfiguration`, makes the library read from that directory and enables hot reload. Without either, the sources are read from the module bundle, and hot reload is off.
- **What a failure looks like.** The renderer logs the compiler output, keeps running with the previous library, and bumps `generation` when a module changes. It does not stop the game.

`CONTRIBUTING.md` asks for a test that compiles a new shader or builds the pipeline that uses it. No such test exists yet: `FeroxRenderTests` covers only CPU-side code. Because the modules are compiled when a renderer is created, any run that creates a `Renderer`, such as the `Showcase3D` example or `FeroxDiag --render`, exercises the compile step. The macOS CI job would catch a compile error only if a test or a run creates a renderer.

The steps for adding a shader are in [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md).

## 9. Code style

- **Formatting.** `.swift-format` at the repository root defines the style. Check with `swift format lint --recursive Sources Tests`, and apply with `swift format format --in-place --recursive Sources Tests`. The commands are given in `CONTRIBUTING.md`.
- **Indentation and line endings.** Four spaces, and LF line endings, as set in `.editorconfig`.
- **Documentation.** Every public declaration has a `///` comment, as `CONTRIBUTING.md` requires.

## 10. Validation status

- No build, test run, lint run or benchmark has been performed. The statements above describe what the files say.
- The benchmark names and the diagnostic outputs are taken from the tool sources.

## 11. Limitations

- **Limitation: the current suite is verified on Linux.** 537 XCTest tests pass on Swift 6.2.3. An earlier suite of 504 tests passed on an M1 Max, macOS 27, Swift 6.4. The macOS CI job compiles shaders and runs the suite, including `MetalDeviceTests` when the runner has a GPU. That is not a frame capture on Apple Silicon.
- **Limitation: no GPU tests.** Shaders and render passes are exercised only by running the examples or `FeroxDiag --render` on a Mac.
- **Limitation: shader compile is not a GPU run.** The macOS job compiles every module with `xcrun metal`. It does not execute the shaders, and it does not construct a `Renderer` unless a later test does.
- **Limitation: no benchmark figures are published here.** Use the tool, in release configuration, on the machine of interest.
- **Limitation: CI benchmarks run on virtualised GPUs.** The workflow says so itself.

## 12. Related documents

- [02-Getting-Started.md](02-Getting-Started.md): requirements and the first run.
- [03-Architecture.md](03-Architecture.md): the modules that the tests cover.
- [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md): shader sources, hot reload and the `FEROX_SHADER_DIR` variable.
- [21-Performance.md](21-Performance.md): how to measure frame cost, and how to read the profiler.
- [27-Troubleshooting.md](27-Troubleshooting.md): reporting a problem with `FeroxDiag` output.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md): what is planned.
