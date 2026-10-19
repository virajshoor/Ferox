<div align="center">

# Ferox

**Swift Engine Ferox: forged in Swift, fired by Metal.**

The open-source game engine for macOS and Apple Silicon.

**[swengine.net](https://swengine.net)** · [Documentation](Docs/01-Overview.md) · [Quick start](#quick-start)

2D and 3D · physically based rendering · hybrid ray tracing · temporal upscaling · physics · editor

[![CI](https://github.com/virajshoor/Ferox/actions/workflows/ci.yml/badge.svg)](https://github.com/virajshoor/Ferox/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange.svg)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)

</div>

---

> [!IMPORTANT]
> **Project status: pre-release (0.1.0, unreleased).** An earlier commit was verified on a Mac
> (Apple M1 Max, macOS 27, Swift 6.4): every target built with no warnings, 504 tests passed, the
> Metal renderer drew offscreen frames, and the examples ran. The current portable suite is 515
> XCTest tests on Swift 6.2.3 (Linux, `swift test --enable-xctest`). On Swift 6.2, plain
> `swift test` can exit 0 without running this suite. The Linux CI builds the engine without
> executing Metal. Testing so far covers one machine, so please report build errors or rendering
> issues on other Macs.

## Contents

- [Why Ferox](#why-ferox)
- [Features](#features)
- [Quick start](#quick-start)
- [A first game](#a-first-game)
- [Tools](#tools)
- [Modules](#modules)
- [Documentation](#documentation)
- [Platform support](#platform-support)
- [Contributing](#contributing)
- [Licence](#licence)

## Why Ferox

Swift Engine Ferox, or Ferox for short, is an open-source engine (Apache 2.0) built for Apple Silicon. It renders only through Metal and avoids cross-platform abstraction layers, so the renderer can use what the hardware offers:

- unified memory;
- tile memory for transient attachments;
- argument buffers;
- Metal ray tracing;
- MetalFX.

When a feature is unavailable, Ferox checks for that at run time and falls back cleanly.

The engine is a set of small Swift modules. The parts that do not need Metal are platform-independent and are tested on Linux in CI: maths, ECS, physics, animation, UI layout, asset decoding, networking, and the CPU side of the renderer.

## Features

| Area | What is there |
| --- | --- |
| **Core** | Archetype-free sparse-set ECS, hierarchy, fixed-timestep loop with interpolation, events, job system, profiler, logging |
| **2D** | Batched sprites, shapes, tilemaps (chunk cached), 2D lights with normal maps, sprite masks, parallax, pixel-perfect cameras |
| **3D** | Forward+ clustered PBR (metallic-roughness, glTF compatible), skinned meshes, LOD, frustum culling, GPU-driven culling with Hi-Z occlusion |
| **Lighting** | Cascaded shadow maps (stable, PCF and PCSS), point and spot lights, image-based lighting, reflection probes, procedural sky |
| **Ray tracing** | Hybrid ray-traced shadows, reflections and ambient occlusion where the GPU supports them, with raster fallbacks |
| **Post-processing** | Bloom, SSAO, depth of field, motion blur, colour grading, auto exposure, tone mapping (Reinhard, ACES, AgX) |
| **Anti-aliasing** | MSAA, FXAA, SMAA, TAA |
| **Upscaling** | Ferox temporal upscaler, MetalFX spatial and temporal upscaling, dynamic resolution, quality presets |
| **Physics** | Built-in 2D and 3D rigid bodies: sequential impulses, joints, triggers, queries, character controller |
| **Gameplay** | `Game` protocol hooks, input actions and contexts, retained-mode UI, spatial audio, animation clips and state machines, CPU and GPU particles |
| **Assets** | glTF 2.0, PNG and JPEG decoding, a validated asset database, memory budgets, hot reload |
| **Shaders** | Metal Shading Language with run-time hot reload |
| **Editor** | Hierarchy, inspector, Play/Pause/Step/Stop, snapshot undo/redo, scene files |
| **Networking** | Scoped foundations: transport, reliable channels, snapshot replication |

Every row has limits, which are listed honestly in [Limitations and Roadmap](Docs/28-Limitations-and-Roadmap.md).

## Quick start

You need macOS 14 or later and Xcode 15.3 or later (which provides Swift 5.10). Apple Silicon is recommended.

```sh
git clone https://github.com/virajshoor/Ferox.git
cd Ferox
swift build
swift test
swift run HelloFerox
```

Every example also runs headless, without a window. This mode works on Linux too:

```sh
swift run HelloFerox --headless --frames 120
```

## A first game

```swift
import Ferox

final class Spinner: Game {
    private var cube = Entity.null

    func setup(engine: Engine) throws {
        let mesh = AssetID("spinner.cube")
        engine.assets.registerMesh(.cube(), id: mesh)

        cube = engine.world.createEntity(named: "Cube")
        engine.world.add(MeshRenderer(mesh: mesh), to: cube)

        let camera = engine.world.createEntity(named: "Camera",
                                               transform: Transform(position: Vec3(0, 1, 4)))
        engine.world.add(Camera.perspective(fov: 60), to: camera)

        let sun = engine.world.createEntity(named: "Sun")
        engine.world.add(Light.directional(intensity: 4, shadows: true), to: sun)
    }

    func update(engine: Engine, time: FrameTime) {
        engine.world.modify(Transform.self, cube) {
            $0.rotation = Quat(angle: Float(time.elapsed), axis: Vec3(0, 1, 0))
        }
    }
}

@main enum Main {
    @MainActor static func main() {
        GameLauncher.main(Spinner(), configuration: EngineConfiguration(title: "Spinner"))
    }
}
```

There are three complete examples in [`Examples/`](Examples):

- `HelloFerox` is the smallest lit 3D scene.
- `Platformer2D` covers sprites, tilemaps, 2D physics and a character controller.
- `Showcase3D` covers PBR, shadows, probes, particles, ray tracing and the graphics presets.

## Tools

| Command | Purpose |
| --- | --- |
| `swift run FeroxEditor` | The editor: hierarchy, inspector, gizmos, Play/Stop, undo, and opening and saving `.fxscene` files |
| `swift run FeroxDiag [--json] [--render]` | Reports the GPU's capabilities, which features each preset enables, and optionally an offscreen render smoke test |
| `swift run -c release FeroxBenchmarks [--quick] [--output file.json]` | Measured CPU and offscreen GPU benchmarks, with JSON output |

Run benchmarks in release mode. Benchmark results are produced on your own machine; this repository publishes none.

## Modules

```
FeroxMath ─┐
FeroxCore ─┼─ FeroxScene ─┬─ FeroxPhysics
           │              ├─ FeroxAnimation
           │              ├─ FeroxAssets ── FeroxRender (Metal)
           │              └─ FeroxUI
           ├─ FeroxInput, FeroxAudio, FeroxNet
           └──────────────────────────────── Ferox (umbrella: Engine, GameHost, EditorSession)
```

Importing `Ferox` gives you every module. The individual modules can also be used on their own.

## Documentation

| | | |
| --- | --- | --- |
| [01 Overview](Docs/01-Overview.md) | [11 Ray Tracing](Docs/11-Ray-Tracing.md) | [21 Performance](Docs/21-Performance.md) |
| [02 Getting Started](Docs/02-Getting-Started.md) | [12 Upscaling & Dynamic Resolution](Docs/12-Upscaling-and-Dynamic-Resolution.md) | [22 Editor](Docs/22-Editor.md) |
| [03 Architecture](Docs/03-Architecture.md) | [13 Physics](Docs/13-Physics.md) | [23 Networking](Docs/23-Networking.md) |
| [04 Building & Testing](Docs/04-Building-and-Testing.md) | [14 Input](Docs/14-Input.md) | [24 Graphics Settings & Presets](Docs/24-Graphics-Settings-and-Presets.md) |
| [05 Engine Lifecycle](Docs/05-Engine-Lifecycle.md) | [15 User Interface](Docs/15-User-Interface.md) | [25 Platform Support](Docs/25-Platform-Support.md) |
| [06 Scene & Entities](Docs/06-Scene-and-Entities.md) | [16 Audio](Docs/16-Audio.md) | [26 Security](Docs/26-Security.md) |
| [07 Rendering 2D](Docs/07-Rendering-2D.md) | [17 Animation & Particles](Docs/17-Animation-and-Particles.md) | [27 Troubleshooting](Docs/27-Troubleshooting.md) |
| [08 Rendering 3D](Docs/08-Rendering-3D.md) | [18 Assets](Docs/18-Assets.md) | [28 Limitations & Roadmap](Docs/28-Limitations-and-Roadmap.md) |
| [09 Lighting & Shadows](Docs/09-Lighting-and-Shadows.md) | [19 Shaders & Hot Reload](Docs/19-Shaders-and-Hot-Reload.md) | [29 API Reference](Docs/29-API-Reference.md) |
| [10 Post-Processing & AA](Docs/10-Post-Processing-and-Anti-Aliasing.md) | [20 Gameplay API](Docs/20-Gameplay-API.md) | |

## Platform support

| Platform | Status |
| --- | --- |
| macOS 14+, Apple Silicon | Primary target: full renderer, ray tracing and MetalFX where the GPU supports them |
| macOS 14+, Intel with a Metal GPU | Intended to work, with features chosen by run-time capability checks |
| Linux | The platform-independent modules build and are tested in CI. There is no renderer, window or audio; the headless mode works |

See [Platform Support](Docs/25-Platform-Support.md).

## Contributing

Contributions are welcome. First builds on real hardware are especially valuable. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, follow [SECURITY.md](SECURITY.md).

Ferox collects no telemetry and sends no data anywhere.

## Licence

Ferox is licensed under the [Apache License 2.0](LICENSE). Third-party attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
