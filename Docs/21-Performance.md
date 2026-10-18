# Performance

Ferox has four tools for understanding cost: a frame profiler in `FeroxCore`, renderer counters that the Metal path fills in each frame, memory accounting, and two command-line tools, `FeroxBenchmarks` and `FeroxDiag`. A GitHub Actions workflow can run a quick benchmark on a hosted macOS runner.

Nothing in Ferox has been measured. No macOS machine or Swift toolchain was available while the engine was written, so no benchmark has been compiled, run or timed, and no CI benchmark result exists. This document therefore reports no timings, frame rates, draw counts, memory figures or GPU costs. It explains what each tool records and how to produce your own numbers. Any figure a reader obtains is valid only for the machine, build configuration and power state that produced it.

Frame timing is driven by the engine loop described in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). The renderer that fills the GPU counters is described in [08-Rendering-3D.md](08-Rendering-3D.md) and [07-Rendering-2D.md](07-Rendering-2D.md). Asset memory budgets are covered in [18-Assets.md](18-Assets.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [The frame profiler](#2-the-frame-profiler)
3. [Engine and renderer statistics](#3-engine-and-renderer-statistics)
4. [Memory accounting](#4-memory-accounting)
5. [FeroxBenchmarks](#5-feroxbenchmarks)
6. [FeroxDiag](#6-feroxdiag)
7. [The CI benchmark workflow](#7-the-ci-benchmark-workflow)
8. [Measuring on your own machine](#8-measuring-on-your-own-machine)
9. [Code examples](#9-code-examples)
10. [Limitations](#10-limitations)
11. [Validation status](#11-validation-status)
12. [Related documents](#12-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| `Profiler` (CPU scopes, GPU samples, counters, history, Chrome trace export) | Implemented: `Sources/FeroxCore/Profiler.swift`. Not run. |
| Renderer counters (`RenderCounters`) | Implemented in the Metal path. **Not run on hardware.** |
| Frame and render statistics | Implemented: `FrameStatistics`, `RenderFrameStatistics`. |
| `MemoryTracker` and `MemoryBudget` | Implemented. Texture budget enforced by the asset manager. Audio budget not enforced. |
| `FeroxBenchmarks` | Implemented: `Sources/FeroxBenchmarks/FeroxBenchmarks.swift`. **Never run.** |
| `FeroxDiag` | Implemented: `Sources/FeroxDiag/FeroxDiag.swift`. **Never run.** |
| CI benchmark workflow | Implemented: `.github/workflows/benchmarks.yml`, manual trigger only. **Never run.** |
| Published numbers | **None.** |

## 2. The frame profiler

`Profiler.shared` is a process-wide profiler. It is enabled by default and can be switched off with `isEnabled`. When it is off, `scope` costs one branch and nothing is recorded.

The engine calls `beginFrame()` at the start of every `tick`, which closes the previous frame into a history of `historyLength` frames (120 by default). Within a frame the profiler records three kinds of data:

- **CPU scopes.** `scope(_:_:)` times a closure and records its name, start, duration, nesting depth and thread (`main` or `worker`). Nesting depth is tracked per thread.
- **GPU samples.** `recordGPU(name:start:duration:)` adds a GPU timing that was resolved asynchronously, and `recordGPUFrame(duration:)` adds the total GPU time of a frame to a separate rolling statistic.
- **Counters.** `count(_:_:)` adds a value to a named per-frame counter. Counters reset each frame, and `lastFrameCounters` holds the previous frame's values.

The scopes the engine itself records are:

| Scope | Recorded by |
| --- | --- |
| `Engine.Frame` | `Engine.tick`, around the whole frame. |
| Each system's type name | `SystemScheduler.run`, once per system per phase. |
| `Render.Extract`, `Render.Encode`, `Render.Sprites`, `Render.UI` | `Renderer`. |
| `GPU.Scene`, `GPU.Post` | `Renderer`, as GPU samples when timings are available. |

The counters the engine and renderer increment include `assets.loaded`, `assets.cacheHits`, `assets.evicted`, `scene.loadMs`, `Render.EnvironmentRegenerations`, `Render.ProbeCaptures` and `Render.BLASBuilds`. Note that `scene.loadMs` is a counter that adds milliseconds, not a count.

`statistics()` aggregates every recorded scope over the history window. It returns `ScopeStatistics` values sorted by average cost, with the last, average and maximum milliseconds and the average number of calls per frame. `lastFrame` returns the samples of the most recent completed frame.

`exportChromeTrace()` writes the history in the Chrome trace-event format. The file can be opened in `chrome://tracing` or Perfetto. Each sample becomes a complete event, with frames laid end to end. `reset()` clears the history and the rolling statistics.

## 3. Engine and renderer statistics

Two lightweight statistics are available without the profiler:

- `Engine.frameStatistics` is a `FrameStatistics` over unscaled frame durations. `averageFPS` is the reciprocal of the average, or zero before any frame has been recorded.
- `Renderer.statistics` is a `RenderFrameStatistics`. It holds the frame index, the CPU time spent encoding the frame (`cpuMilliseconds`), the GPU time (`gpuMilliseconds`, optional), the render and output sizes, and the dynamic-resolution multiplier.

The GPU time in `RenderFrameStatistics` is that of the most recently completed frame, not the one being encoded. Frames are pipelined, so the figure lags by design. It comes from command-buffer start and end timestamps.

`Profiler.shared.renderCounters` is filled by the renderer during a frame and copied to `lastRenderCounters` when the next frame begins. `RenderCounters` has these fields:

| Field | Meaning |
| --- | --- |
| `drawCalls`, `instances`, `triangles` | Mesh draws, instances and triangles submitted. |
| `renderPasses`, `computeDispatches` | Render passes encoded and compute dispatches. |
| `pipelineStateChanges`, `textureBinds` | State changes and texture bindings. |
| `culledObjects`, `visibleObjects` | Objects removed or kept by culling. |
| `spriteBatches`, `sprites` | 2D batches and sprites. |
| `uploadedBytes` | Bytes uploaded to the GPU this frame. |
| `rayTracingRays` | Rays traced by the ray-tracing path. |

These are counts. They describe what the renderer asked the GPU to do, which is a useful way to find a bottleneck before any timing is taken. They have not been checked against a real frame.

## 4. Memory accounting

`MemoryTracker.shared` keeps running byte totals by category, with peaks. Categories are created by the code that allocates; the names seen in the source are `audio`, `GPU.ShadowMap`, `GPU.Particles` and `GPU.UIGlyphs`. Calls are `allocate(_:bytes:)` and `free(_:bytes:)`. Queries are `usage(_:)`, `peakUsage(_:)`, `total` and `snapshot`.

`MemoryBudget` holds three limits in bytes: textures, meshes and audio. `MemoryBudget.recommended(workingSetBytes:)` derives a budget from the GPU's recommended working-set size, giving textures half, meshes an eighth and audio the smaller of a thirty-second and 512 MB. `AssetManager` is created with a default budget of 1 GB of textures, 256 MB of meshes and 128 MB of audio.

Enforcement is partial. The asset manager's `update` compares texture memory with `budget.textureBytes` and evicts unreferenced textures in least-recently-used order, logging a warning if the budget is still exceeded. Mesh memory is stored in the budget but no eviction for it was found in the source reviewed. Audio memory is recorded, but nothing reads `audioBytes`. See [16-Audio.md](16-Audio.md).

## 5. FeroxBenchmarks

`FeroxBenchmarks` is an executable target that runs repeatable micro-benchmarks of the engine's hot paths. Run it in release configuration. The tool prints a warning when built in debug.

```bash
swift run -c release FeroxBenchmarks                     # full run, text report
swift run -c release FeroxBenchmarks --quick             # fewer iterations
swift run -c release FeroxBenchmarks --output out.json   # also write JSON
swift run -c release FeroxBenchmarks --filter physics    # matching names only
```

Each benchmark builds fresh state outside the timed region, runs one warm-up iteration, then times repeated runs. Full runs use 20 iterations and quick runs use 5. The report gives the mean, median, minimum and maximum time per iteration in milliseconds, and where a benchmark has a unit (for example `entities/s`), a throughput derived from the median.

The CPU benchmarks are:

| Name | What it does |
| --- | --- |
| `ecs.create+destroy` | Creates and destroys entities with a `Transform`. |
| `ecs.forEach(Transform)` | Iterates every `Transform` and changes its position. |
| `transform.hierarchy` | Moves every root of a forest of four-level chains, the worst case for transform propagation. |
| `physics2d.pile(500).60steps` | Simulates a pile of boxes for 60 steps. The name says 500 bodies, but quick runs use 200. |
| `physics3d.pile(500).60steps` | The same, in 3D. The same quick-run difference applies. |
| `events.enqueue+flush` | Queues and flushes events. |
| `math.mat4-multiply` | Multiplies matrices in a loop. |
| `engine.tick(empty scene)` | Ticks an engine with no content. |

When Metal is available, the tool also creates a renderer for each quality preset and times offscreen frames at 1920 × 1080 of a scene with 400 lit spheres, a shadowed sun and four point lights. These benchmarks are named `gpu.offscreen-1080p.<preset>`, one for each of `low`, `medium`, `high` and `ultra`. They time 60 frames, or 10 in quick mode, and wait for the GPU to finish.

`--output` writes a JSON report with the Ferox version, the date, the operating system, the processor count, the memory size, the build configuration, whether it was a quick run, the GPU name, and one entry per benchmark. The output directory is created if it does not exist. The source comment says only plain paths are accepted, but the code does not check the path beyond creating its parent directory.

## 6. FeroxDiag

`FeroxDiag` prints what Ferox detects on the current machine, and how each quality preset resolves on it. Its output is designed to be pasted into a bug report.

```bash
swift run FeroxDiag            # human-readable report
swift run FeroxDiag --json     # machine-readable
swift run FeroxDiag --render   # also renders one 256 x 256 offscreen frame (macOS)
```

The report includes the operating system, the processor count, the memory size, the Metal availability and device capabilities. It then lists each preset's anti-aliasing mode, upscaler, render scale, the render size for a 2560 × 1440 output, which ray-traced effects are enabled, and any fallbacks the resolver chose. Without Metal, presets are resolved against a baseline capability set, and the report says so. With `--render`, the tool reports whether the frame produced pixels and how many were not black.

Nothing is sent over the network. The report goes to standard output only.

## 7. The CI benchmark workflow

`.github/workflows/benchmarks.yml` runs only when started by hand (`workflow_dispatch`). It runs on a `macos-14` runner, selects Xcode 15.4 if it is present, and then runs:

```bash
swift run -c release FeroxBenchmarks --quick --output BenchmarkResults/ci.json
```

The JSON file is uploaded as the artifact `ferox-benchmarks-ci`. The workflow's own comment says that hosted macOS runners use virtualised GPUs, so the numbers are useful only for spotting large regressions and trends. They are not representative of Apple Silicon hardware, and performance claims should come from local release runs.

The main CI workflow does not run benchmarks. It builds in debug and release on macOS, runs `swift test`, and on Linux builds the engine target and runs a filtered set of portable tests.

## 8. Measuring on your own machine

Follow these steps for any performance question:

1. Build in release configuration. Debug numbers are not representative, and `FeroxBenchmarks` says so.
2. Close other heavy applications, and keep the machine on power and at a stable thermal state.
3. Run `FeroxDiag` and keep its output, so the results can be tied to a device and an OS version.
4. Run `FeroxBenchmarks` with `--output`, several times, and compare medians rather than single runs.
5. For frame behaviour, enable the profiler, run the game for a while, and export a Chrome trace. Read `statistics()` to find the most expensive scopes.
6. Compare runs only on the same machine, configuration and power state. The source comments say the same.

## 9. Code examples

Recording a custom scope and counter in game code, then reading the most expensive scopes:

```swift
let profiler = Profiler.shared
profiler.scope("Gameplay.Pathfinding") {
    findPaths(for: agents)
}
profiler.count("Gameplay.PathRequests", Double(agents.count))

for s in profiler.statistics().prefix(5) {
    print(s.name, s.averageMilliseconds, s.maxMilliseconds, s.callsPerFrame)
}
```

Exporting the recent history for a trace viewer:

```swift
let trace = Profiler.shared.exportChromeTrace()
try trace.write(to: URL(fileURLWithPath: "/path/to/trace.json"))
```

Reading renderer counters and statistics at the end of a frame:

```swift
let counters = Profiler.shared.lastRenderCounters
let stats = engine.frameStatistics
print("draws", counters.drawCalls, "passes", counters.renderPasses, "avg FPS", stats.averageFPS)
```

Checking memory usage by category:

```swift
let tracker = MemoryTracker.shared
print("audio", tracker.usage("audio"), "peak", tracker.peakUsage("audio"), "total", tracker.total)
```

Running a single benchmark in release and writing the result:

```bash
swift run -c release FeroxBenchmarks --filter ecs --output BenchmarkResults/local.json
```

## 10. Limitations

- **Nothing has been measured.** No timing, count or throughput figure in this repository has been produced by running the code.
- **The profiler is global.** `Profiler.shared` is one instance for the whole process, and it is not reset between runs unless `reset()` is called.
- **Scope history is bounded.** The default history is 120 frames. Longer captures must be exported as they go.
- **GPU timings are asynchronous.** GPU samples are resolved after the frame has completed, so they lag the CPU data they belong to.
- **Profiling overhead is not quantified.** The source describes scope overhead as negligible. That has not been checked.
- **Benchmark names can mislead.** Physics benchmark names include the full body count even in quick runs, which use fewer bodies.
- **The benchmark tool has no statistical tests.** It reports a mean, median, minimum and maximum, but does not check for noise or thermal throttling.
- **Hosted runners are not representative.** The CI benchmark runs on virtualised hardware and is only a trend indicator.
- **Audio budget not enforced.** The `audioBytes` limit is declared but unused. See [16-Audio.md](16-Audio.md).
- **Mesh budget not enforced.** The mesh limit is stored, but no mesh eviction was found in the source reviewed.
- **Counters are unlabelled.** Counter names are plain strings with no registry, so a misspelled name silently creates a new counter.
- **Device-dependent paths are unverified.** Ray tracing, MetalFX and the dynamic-resolution controller have not been exercised on hardware.

## 11. Validation status

This document was written from the source. No macOS machine or Swift toolchain was available while the engine was written. None of the benchmark, diagnostic or profiler code has been compiled or run, and the CI benchmark workflow has not been triggered. No performance result is reported or implied anywhere in this document.

The `Tests/` directory contains no tests for `Profiler`, `MemoryTracker` or the benchmark tool. The profiler is referenced only from `Tests/FeroxCoreTests/TimeTests.swift`. `FeroxBenchmarks` and `FeroxDiag` are not test targets, so `swift test` does not run them.

## 12. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md) for the frame whose scopes the profiler records.
- [07-Rendering-2D.md](07-Rendering-2D.md) and [08-Rendering-3D.md](08-Rendering-3D.md) for the passes behind the render counters.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md) and [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md) for the quality settings the benchmarks compare.
- [16-Audio.md](16-Audio.md) for the audio budget that is declared but not enforced.
- [18-Assets.md](18-Assets.md) for the asset budgets and texture eviction.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md) for the presets used by the GPU benchmarks.
- [27-Troubleshooting.md](27-Troubleshooting.md) for using `FeroxDiag` in a bug report.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md) for the wider list of unverified areas.
