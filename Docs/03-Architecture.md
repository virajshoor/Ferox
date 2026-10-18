# Architecture

This document describes how Ferox is put together at run time. It covers the module layers, the split between `Engine`, `GameHost` and `Renderer`, the order of work in one frame, which objects own which resources, and the threading rules that the code relies on. The module list and dependency graph are in [01-Overview.md](01-Overview.md). The frame phases are summarised here and described in full in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). The source references are to `Sources/Ferox/Engine.swift`, `Sources/Ferox/GameHost.swift`, `Sources/FeroxRender/Metal/Renderer.swift` and the modules named in each section.

## Contents

1. [Layering](#1-layering)
2. [Engine, GameHost and Renderer](#2-engine-gamehost-and-renderer)
3. [The frame in order](#3-the-frame-in-order)
4. [Ownership](#4-ownership)
5. [Threading rules](#5-threading-rules)
6. [Extension points](#6-extension-points)
7. [Validation status](#7-validation-status)
8. [Limitations](#8-limitations)
9. [Related documents](#9-related-documents)

## 1. Layering

The modules form a stack. Each layer depends only on the layers below it. The lowest layers hold values and rules, and the highest layers hold the Metal renderer and the window.

| Layer | Modules | Contents |
| --- | --- | --- |
| Values | `FeroxMath` | Vectors, matrices, quaternions, colour, geometry. No state. |
| Services | `FeroxCore` | Clock and timestep, events, jobs, logging, profiler, capabilities, graphics settings. |
| World | `FeroxScene` | `World`, components, hierarchy, systems, scene documents. |
| Simulation | `FeroxPhysics`, `FeroxAnimation`, `FeroxInput`, `FeroxAudio`, `FeroxNet` | Systems and state that run on the world or on their own. |
| Content and interface | `FeroxAssets`, `FeroxUI` | Asset handles and the UI tree, which read the world and input. |
| Presentation | `FeroxRender` | Reads the world and assets, and writes to a Metal texture. |
| Runtime | `Ferox` | `Engine`, `Game`, `GameLauncher`, `GameHost` and `EditorSession`. Joins the layers into a running program. |

The split is what makes headless runs possible. Nothing below the `Ferox` layer imports the renderer, and `Engine` itself does not import Metal or AppKit. `GameHost` and `GameLauncher.main` add the window and the renderer on macOS.

## 2. Engine, GameHost and Renderer

Three types cooperate in a window. Each has one responsibility.

| Type | File | Platform | Responsibility |
| --- | --- | --- | --- |
| `Engine` | `Sources/Ferox/Engine.swift` | Any | Owns the world and the subsystems. Advances the simulation by one frame in `tick(delta:)`. Knows nothing about windows or GPUs. |
| `GameHost` | `Sources/Ferox/GameHost.swift` | macOS | Owns the application, the window, the `GameView` and the `Renderer`. Calls `engine.tick()` once per display frame, then passes the world to the renderer. |
| `Renderer` | `Sources/FeroxRender/Metal/Renderer.swift` | macOS | Turns a `World` into one frame in a `RenderOutput`. Owns the GPU resources. Knows nothing about the engine's frame loop. |

`GameHost` is the only place where the engine and the renderer meet. Its per-frame method is short:

```swift
// Sources/Ferox/GameHost.swift, paraphrased in order
inputBackend.poll()                                    // platform input into InputState
engine.viewportPoints = Vec2(Float(view.bounds.width), Float(view.bounds.height))
engine.ui.backingScale = window.backingScaleFactor
let time = engine.tick()                               // the whole simulation frame
onFrame?(time)                                         // host hook, for example editor gizmos
if let drawable = view.currentDrawable {               // acquired as late as possible
    renderer.render(world: engine.world,
                    to: RenderOutput(texture: drawable.texture, drawable: drawable),
                    time: time.elapsed,
                    deltaTime: Float(time.unscaledDelta),
                    ui: engine.ui)
}
if engine.quitRequested { window.performClose(nil) }
```

Two details matter. The drawable is requested after the simulation, so it is not held while game code runs. The renderer receives `time.elapsed`, which is scaled game time, for shader animation, and `time.unscaledDelta` for GPU effects such as particles and exposure. Game code therefore affects the picture only through the world, and the renderer never calls game code.

`Engine` does not hold a renderer, and `GameHost` does not run game code except through `engine.tick()`. A different host, such as an editor, can drive the same `Engine` with its own renderer, as long as it calls `tick()` once per frame.

## 3. The frame in order

`Engine.tick(delta:)` performs one simulation frame. The steps below are taken directly from `Engine.tick`, in the order they run. `edit` is `engine.isEditMode`.

1. `clock.tick` produces a `FrameTime` and the number of fixed steps `n` for this frame. `frameStatistics` records the unscaled delta.
2. `Profiler.shared.beginFrame()` starts a profiler frame, and every step below is recorded in the `Engine.Frame` scope.
3. `input.beginFrame()` latches the input state for the frame.
4. `scheduler.run(.earlyUpdate)`. Input mapping and network receive belong here.
5. For each of the `n` fixed steps:
   1. `game.fixedUpdate(engine:dt:)`, unless `edit` is true.
   2. `world.flushDeferred()`, which applies structural changes queued by the game.
   3. `scheduler.run(.fixedUpdate)`. The physics systems run here.
   4. `events.flush()`, which delivers the events enqueued by the fixed systems.
6. `physics2D?.interpolate` and `physics3D?.interpolate` blend the poses of bodies that opted in, using `alpha`, the fraction of the next fixed step already elapsed.
7. `game.update(engine:time:)`, unless `edit` is true. Then `world.flushDeferred()`, then `scheduler.run(.update)`.
8. `scheduler.run(.lateUpdate)`. Animation, tweens, timelines and CPU particles run here. Then `game.lateUpdate(engine:time:)`, then `world.flushDeferred()`.
9. `scenes.update(dt:)` advances scene transitions.
10. `TransformSystem.update(world)` propagates transforms into `WorldTransform`.
11. `scheduler.run(.preRender)`, then `events.flush()`.
12. `assets.update()`, `updateAudioListener()`, `audio.update(dt:)` and `ui.update(input:dt:viewportPoints:)`.

The renderer then runs in `GameHost`, outside `tick`. See [08-Rendering-3D.md](08-Rendering-3D.md) for its internal order.

Three consequences follow from this order:

- **Game code runs before the systems of the same phase.** `game.update` runs before `scheduler.run(.update)`, and `game.lateUpdate` runs after the late systems. A system can therefore see what the game wrote in that frame.
- **Structural changes are applied between stages.** `flushDeferred()` runs after each game hook. An entity destroyed in `update` is gone before `lateUpdate`. See [06-Scene-and-Entities.md](06-Scene-and-Entities.md), section 8.
- **Events are delivered at fixed points.** Events enqueued by the fixed systems are delivered after every fixed step. Events enqueued in any later phase are delivered by the flush that ends the frame, so they are seen in the same frame.

## 4. Ownership

| Object | Owned by | Holds | Notes |
| --- | --- | --- | --- |
| `Engine` | The caller, or `GameLauncher` | Configuration, world, events, scheduler, scenes, input, assets, animation, optional physics systems, audio, UI, clock, the game. | `game` is held strongly until `shutdown()`. |
| `World` | `Engine`, or a test | Entity slots, component storages, resources. | `SystemScheduler` holds the world weakly. |
| `SystemScheduler` | `Engine` | Systems, sorted by phase and order. | Calls `flushDeferred()` after each system. |
| `AssetManager` | `Engine` | Asset handles and the optional asset database. | Also stored as a world resource. |
| `GameHost` | `GameLauncher.main`, or an embedding host | `Engine`, `Renderer`, window, view, input backend. | `@MainActor`. Lives for the duration of `GameHost.run`, which returns when the window closes. |
| `Renderer` | `GameHost` | Device, queue, shader library, caches, render targets, post-processor, ray-tracing context. | Caches are released by `purgeCaches()`. |
| `EditorSession` | The editor, not `Engine` | The engine it drives, selection, undo history. | Uses the edit-mode flag. See [22-Editor.md](22-Editor.md). |

`Engine.init` also calls `Engine.registerBuiltinComponents()`, which registers the physics and animation component types with the shared `ComponentRegistry` once per process. It sets a static flag under a lock, so it is safe to create several engines.

GPU memory is owned by the renderer. It is allocated when a frame needs it, and it is released when the mesh or texture leaves its cache, or when `purgeCaches()` runs. `GameHost.shutdown()` calls `renderer.waitUntilIdle()` before purging, so the GPU is not still reading a buffer that is being freed.

## 5. Threading rules

The rules below are stated in the source documentation and follow from the code. They are not enforced by the compiler, except where a type is annotated `@MainActor`.

- **The simulation runs on one thread.** `Engine` is documented as not thread-safe. Create it and call `tick` on one thread, normally the main thread.
- **`GameHost` and the input backend are main-actor types.** `GameHost` and `MacInputBackend` are annotated `@MainActor`. `GameHost` runs the frame from the `MTKView` delegate method, which AppKit calls on the main thread.
- **Game hooks run on the main thread.** The `Game` protocol documentation states this.
- **`World` has no locks.** It is mutated from one thread at a time. Parallelism is allowed only inside `World.withDenseStorage`, through `Jobs.parallelFor`, and only on indices a worker owns. See [06-Scene-and-Entities.md](06-Scene-and-Entities.md), section 18.
- **`EventBus` is main-thread only.** Use `ThreadSafeQueue` to pass work from another thread to the main thread.
- **The renderer is not thread-safe.** It is created and driven on the main thread.
- **GPU completion runs on other threads.** The renderer's completion handlers run on Metal's threads. They update the GPU timing values under `gpuLock`, and they signal the in-flight semaphore last, so a frame slot is reused only after the GPU has finished with it.
- **Frames in flight are bounded.** The renderer encodes at most `maxFramesInFlight` frames ahead of the GPU. The value is 1 to 3, with 3 as the default. A frame that waits more than one second for a slot is skipped and logged.
- **Shared services are lock-protected or annotated.** `Log`, `Profiler`, `MemoryTracker` and `ComponentRegistry` are annotated `@unchecked Sendable`, which means the author asserts they are safe to share. `ComponentRegistry` takes a lock when a type is registered.

## 6. Extension points

A game or a tool extends the engine in these places. Each is described in full in the document shown.

| Point | Mechanism | Document |
| --- | --- | --- |
| Frame behaviour | Implement `Game`, or add a `System` to `engine.scheduler`. | [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md), [06-Scene-and-Entities.md](06-Scene-and-Entities.md) |
| Components saved in scenes | Conform to `SerializableComponent` and register with `ComponentRegistry.shared`. | [06-Scene-and-Entities.md](06-Scene-and-Entities.md) |
| Assets in code | `engine.assets.registerMesh`, `registerMaterial` and similar. | [18-Assets.md](18-Assets.md) |
| Custom GPU work | `Renderer.addHook(_:_:)` at one of four stages. | [08-Rendering-3D.md](08-Rendering-3D.md) |
| Custom shaders | A `shaderDirectory`, or the `FEROX_SHADER_DIR` environment variable. | [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md) |
| Host-level drawing | `GameHost.onFrame`, called after `tick` and before rendering. | [22-Editor.md](22-Editor.md) |

## 7. Validation status

- No build, test run or rendered frame has been checked against this snapshot. See [01-Overview.md](01-Overview.md), section 7.
- The descriptions above come from reading `Engine.tick`, `GameHost.frame` and `Renderer.render`. The order was compared line by line with the source.
- No measurement of frame time, latency or memory is given.

## 8. Limitations

- **Limitation: one game per engine.** `Engine.start(_:)` may be called once, and it has a precondition that enforces this. Several games need several engines.
- **Limitation: one world per engine.** `Engine` owns one `World`. Several worlds need several engines.
- **Limitation: the renderer's comments point to documents that are not in this series.** The header comment of `Renderer.swift` refers to `Docs/07-3D-Rendering.md` and `Docs/08-Render-Pipeline.md`. The equivalent documents here are [07-Rendering-2D.md](07-Rendering-2D.md) and [08-Rendering-3D.md](08-Rendering-3D.md).
- **Limitation: the renderer takes one camera per frame.** It draws the highest-priority enabled camera. See [08-Rendering-3D.md](08-Rendering-3D.md).
- **Limitation: the host runs on the main thread.** Rendering, input and the game share one thread. A long `update` delays the next frame.
- **Limitation: no timing guarantees.** The frame order does not state how long each phase takes.

## 9. Related documents

- [01-Overview.md](01-Overview.md): the modules and their dependency graph.
- [02-Getting-Started.md](02-Getting-Started.md): running a game.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): the configuration, the hooks, the frame clock and shutdown.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): the world, the scheduler and the deferred-change rules.
- [08-Rendering-3D.md](08-Rendering-3D.md): what happens inside `Renderer.render`.
- [21-Performance.md](21-Performance.md): measuring the frame.
