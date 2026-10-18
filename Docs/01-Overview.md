# Overview

Ferox is a game engine for macOS, written in Swift. Its renderer uses Metal, and its simulation runs on the CPU. The engine is divided into small Swift modules. Most of them are platform-independent and can be built and tested without a GPU. Only the renderer and the macOS windowing and input backends depend on Metal and AppKit. This document describes what the engine provides, how its modules depend on one another, which platforms it targets, and what this repository snapshot has and has not verified. Each subsystem is described in full in the document linked from its section.

## Contents

1. [What Ferox is](#1-what-ferox-is)
2. [Modules and dependency graph](#2-modules-and-dependency-graph)
3. [Products, tools and examples](#3-products-tools-and-examples)
4. [Feature summary](#4-feature-summary)
5. [Platform support](#5-platform-support)
6. [Repository layout](#6-repository-layout)
7. [What is and is not verified](#7-what-is-and-is-not-verified)
8. [Limitations](#8-limitations)
9. [Related documents](#9-related-documents)

## 1. What Ferox is

Ferox provides the parts a small or medium 2D or 3D game normally needs: an entity-component-system (ECS) world, a fixed-timestep frame loop, rigid-body physics, a Metal renderer, input mapping, a UI layer, audio output, animation, an asset pipeline, and networking foundations. A game is a class that conforms to the `Game` protocol. It is started either in a macOS window through `GameLauncher`, or headless, which runs the simulation without a window or renderer.

The main types a game author uses are:

| Type | Module | Purpose |
| --- | --- | --- |
| `Engine` | `Ferox` | Owns the world, the subsystems and the frame loop. |
| `Game` | `Ferox` | Protocol with the hooks the engine calls. |
| `GameLauncher` | `Ferox` | Parses `--headless`, `--frames` and `--dt`, then runs the game. |
| `World` | `FeroxScene` | The ECS world: entities, components, resources and queries. |
| `Renderer` | `FeroxRender` | Turns a `World` into a frame. macOS only. |
| `PhysicsWorld2D`, `PhysicsWorld3D` | `FeroxPhysics` | Rigid-body simulation. |

The engine is designed so that the simulation can be driven without a renderer. `Engine.tick(delta:)` advances one frame with an explicit delta, which makes the timing of a run repeatable in tests and on servers. See [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md).

## 2. Modules and dependency graph

`Package.swift` declares one library target per module. The dependencies below are copied from the target declarations, not inferred from imports.

| Module | Role | Depends on |
| --- | --- | --- |
| `FeroxMath` | Vectors, matrices, quaternions, colour, geometry, transforms, random numbers. | None |
| `FeroxCore` | Time and frame clock, events, jobs, logging, profiler, graphics settings, device capability model, JSON values, handles, safe paths. | `FeroxMath` |
| `FeroxScene` | ECS world, sparse-set storage, hierarchy, transforms, system scheduler, scene serialisation, scene manager, render-facing component data. | `FeroxMath`, `FeroxCore` |
| `FeroxPhysics` | 2D and 3D rigid bodies, joints, queries, character controller, ECS bridge. | `FeroxMath`, `FeroxCore`, `FeroxScene` |
| `FeroxAnimation` | Animation clips and animator, tweens, timelines, CPU and GPU particles. | `FeroxMath`, `FeroxCore`, `FeroxScene` |
| `FeroxInput` | Keys, gamepads, action maps and contexts, input recording and playback, macOS input backend. | `FeroxMath`, `FeroxCore` |
| `FeroxAssets` | Asset manager, asset database, glTF import, image decoding, binary coding, model instantiation. | `FeroxMath`, `FeroxCore`, `FeroxScene`, `FeroxAnimation` |
| `FeroxNet` | Transport, connections, peers, replication and message coding. | `FeroxCore` |
| `FeroxAudio` | Audio model and the AVFoundation backend. | `FeroxMath`, `FeroxCore` |
| `FeroxUI` | Controls, labels, layout anchors, draw lists, text and fonts. | `FeroxMath`, `FeroxCore`, `FeroxInput` |
| `FeroxRender` | Metal renderer: frame graph, passes, lighting, post-processing, ray tracing, 2D batching. | `FeroxMath`, `FeroxCore`, `FeroxScene`, `FeroxAssets`, `FeroxAnimation`, `FeroxUI` |
| `Ferox` | Umbrella: `Engine`, `Game`, `GameLauncher`, the macOS `GameHost`, and the editor core `EditorSession`. Re-exports the modules above. | All of the modules above |

The graph has no cycles. Grouped by layer, with each module's dependencies in brackets:

```
Layer 0   FeroxMath
Layer 1   FeroxCore       [FeroxMath]
Layer 2   FeroxScene      [FeroxMath, FeroxCore]
          FeroxInput      [FeroxMath, FeroxCore]
          FeroxAudio      [FeroxMath, FeroxCore]
          FeroxNet        [FeroxCore]
Layer 3   FeroxPhysics    [FeroxMath, FeroxCore, FeroxScene]
          FeroxAnimation  [FeroxMath, FeroxCore, FeroxScene]
          FeroxUI         [FeroxMath, FeroxCore, FeroxInput]
Layer 4   FeroxAssets     [FeroxMath, FeroxCore, FeroxScene, FeroxAnimation]
Layer 5   FeroxRender     [FeroxMath, FeroxCore, FeroxScene, FeroxAssets, FeroxAnimation, FeroxUI]
Layer 6   Ferox           [every module above]
```

`Ferox` depends on every module and re-exports them, so a game needs only `import Ferox`. The re-exports are declared in `Sources/Ferox/Exports.swift`. The layering itself is described in [03-Architecture.md](03-Architecture.md).

The header comment of `Package.swift` states that every module except `FeroxRender`, the AVFoundation backend of `FeroxAudio`, and the platform backends of `FeroxInput` and `FeroxUI` is platform-independent Swift, so that the simulation core can be tested on any platform with a Swift toolchain.

## 3. Products, tools and examples

`Package.swift` declares these executable products and targets in addition to the libraries.

| Name | Kind | Source | Purpose |
| --- | --- | --- | --- |
| `FeroxEditor` | Executable | `Sources/FeroxEditor` | Declared as a target. Its source directory is **not present** in this snapshot. |
| `FeroxDiag` | Executable | `Sources/FeroxDiag` | Prints the detected GPU and how each quality preset resolves. See [04-Building-and-Testing.md](04-Building-and-Testing.md). |
| `FeroxBenchmarks` | Executable | `Sources/FeroxBenchmarks` | Repeatable CPU and offscreen GPU benchmarks with optional JSON output. |
| `HelloFerox` | Executable | `Examples/HelloFerox` | A lit, spinning cube on a plane. The smallest complete program. |
| `Platformer2D` | Executable | `Examples/Platformer2D` | A side-scrolling platformer built from shapes, with physics and triggers. |
| `Showcase3D` | Executable | `Examples/Showcase3D` | A 3D tour of PBR materials, lights, physics and quality presets. |

The examples are described in [02-Getting-Started.md](02-Getting-Started.md).

## 4. Feature summary

The list below states what the source implements. Each item links to the document that describes it. Where a feature has a known limitation, the limitation is described in that document, not here.

- **Scenes and entities.** Generational entity handles, sparse-set component storage, parent-child hierarchy with transform propagation, a phase-ordered system scheduler, a JSON scene and prefab format with validation, and a scene manager with additive loads and fades. See [06-Scene-and-Entities.md](06-Scene-and-Entities.md).
- **Engine loop.** Fixed-timestep simulation with render interpolation, a frame clock with time scale and pause, edit mode, and headless runs. See [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md).
- **Physics.** Sequential-impulse rigid bodies in 2D and 3D, with warm starting, Coulomb friction, speculative contacts, sleep islands, joints, a capsule character controller and collision events. Continuous collision detection is not implemented. See [13-Physics.md](13-Physics.md).
- **Input.** Keyboard, mouse and gamepad state, action maps and contexts, and input recording and playback. See [14-Input.md](14-Input.md).
- **Rendering, 2D.** CPU-batched sprites, shapes, tilemaps, stencil masks and 2D lights in the same HDR pass as 3D. See [07-Rendering-2D.md](07-Rendering-2D.md).
- **Rendering, 3D.** A clustered forward or forward renderer with metallic-roughness PBR materials, LOD groups, GPU-driven instance culling with Hi-Z occlusion, reverse-Z depth, and render hooks for custom GPU work. See [08-Rendering-3D.md](08-Rendering-3D.md).
- **Lighting.** Directional, point and spot lights, cascaded shadow maps for the sun with PCF and a simplified PCSS mode, image-based lighting from procedural, texture or colour skies, exponential fog, and up to 16 reflection probes. See [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md).
- **Post-processing and anti-aliasing.** SSAO, bloom, auto exposure, depth of field, motion blur, tone mapping with Reinhard, ACES or AgX operators (or none), colour grading, and anti-aliasing with MSAA, FXAA, a simplified SMAA and TAA. See [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md).
- **Ray tracing.** Hybrid ray-traced shadows, ambient occlusion and reflections, with fallbacks to the rasterised techniques. See [11-Ray-Tracing.md](11-Ray-Tracing.md).
- **Upscaling.** Ferox spatial and temporal upscalers, MetalFX spatial and temporal scalers, and a dynamic resolution controller. See [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md).
- **UI, audio, animation, assets and networking.** These are described in [15-User-Interface.md](15-User-Interface.md), [16-Audio.md](16-Audio.md), [17-Animation-and-Particles.md](17-Animation-and-Particles.md), [18-Assets.md](18-Assets.md) and [23-Networking.md](23-Networking.md).
- **Shaders.** Metal sources are compiled at run time, and can be hot-reloaded from a directory. See [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md).
- **Editor core.** `EditorSession`, in `Sources/Ferox/EditorSession.swift`, provides selection, play, pause and stop, undo and redo, and scene files without any UI. See [22-Editor.md](22-Editor.md).

## 5. Platform support

| Platform | Status |
| --- | --- |
| macOS 14 or later | The target platform. `Package.swift` declares `.macOS(.v14)`. |
| Apple Silicon | The primary target, according to `CONTRIBUTING.md`. |
| Linux | The CI runs a portable job that builds `FeroxMath` and `FeroxCore` and runs the test filters for the portable modules. The rest of the package is not built there. |
| iOS, tvOS, visionOS | Not declared in `Package.swift`. Not supported by this snapshot. |

Hardware requirements and build instructions are in [02-Getting-Started.md](02-Getting-Started.md). Platform detail is in [25-Platform-Support.md](25-Platform-Support.md).

## 6. Repository layout

| Path | Contents |
| --- | --- |
| `Package.swift` | The package manifest. Declares every product and target, the Swift settings, and the macOS platform. |
| `Sources/` | One directory per module, plus `Sources/Ferox` for the umbrella. `Sources/FeroxRender/Shaders` holds the Metal sources. |
| `Examples/` | `HelloFerox`, `Platformer2D` and `Showcase3D`. Each is declared with an explicit `path` in the manifest. |
| `Tests/` | Test directories. Only `Tests/FeroxPhysicsTests` and `Tests/FeroxSubsystemTests` exist, and both are empty. See section 7. |
| `Docs/` | This documentation series. |
| `.github/workflows/` | `ci.yml` for build, test and link checks, and `benchmarks.yml` for a manual benchmark run. |
| `CHANGELOG.md`, `CONTRIBUTING.md` | Release history and contributor rules. |

The snapshot has no `README.md`, although the documentation link check in `ci.yml` refers to one.

## 7. What is and is not verified

This documentation was written from the source code of this repository snapshot. The environment used to write it had no Swift toolchain and no Mac with a Metal device. The following statements therefore hold:

- **Not built.** No build of the package was run against this snapshot, so compile errors, manifest errors and link errors are not ruled out.
- **Not run.** No example was run, in a window or headless. No frame was rendered.
- **Not tested.** Most declared test targets have no source directory in the snapshot (see [04-Building-and-Testing.md](04-Building-and-Testing.md)). No test result is cited.
- **Not measured.** No benchmark result, frame time or memory figure is given in any document of this series. The benchmark tool exists, but its output has not been recorded here. See [21-Performance.md](21-Performance.md).
- **Not checked on hardware.** Every rendering, lighting, upscaling and ray-tracing behaviour described in sections 07 to 12 is derived from the Swift and Metal source. None has been observed on a Mac. Statements about hardware tiers repeat what the source comments say, and are marked as such where they appear.
- **Source-level only.** Where a document describes an algorithm, it describes what the code does. It does not claim that the output is correct or that it is efficient.

Two parts of the snapshot are incomplete. The `FeroxEditor` executable target is declared without a source directory. Several declared test targets have no directory. Whether the package loads in SwiftPM in this state has not been checked.

## 8. Limitations

- **Limitation: no verification in this snapshot.** Section 7 applies to every document in this series.
- **Limitation: incomplete package.** The `FeroxEditor` source directory and most test directories are absent, so `swift build` and `swift test` may not succeed on a clean checkout of this snapshot.
- **Limitation: Linux is partial.** Only the portable modules are built in CI on Linux. The renderer and the examples require macOS.
- **Limitation: no UI for the editor in this snapshot.** `EditorSession` is the non-visual core. Its window and panels are in the missing `FeroxEditor` target.

## 9. Related documents

- [02-Getting-Started.md](02-Getting-Started.md): requirements, building and running the examples, writing a first game.
- [03-Architecture.md](03-Architecture.md): module layering, the `Engine`, `GameHost` and `Renderer` split, and threading rules.
- [04-Building-and-Testing.md](04-Building-and-Testing.md): build commands, test targets, CI, and the diagnostic and benchmark tools.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): configuration, the `Game` hooks and the frame phases.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): the ECS world, scheduling and scene files.
- [29-API-Reference.md](29-API-Reference.md): the complete API listing.
