# Engine Lifecycle

This document describes the life of an engine: how it is configured, how a game is attached and started, the hooks a game implements, the phases of one frame, the fixed-timestep and interpolation rules, edit mode, shutdown, and headless runs. The frame order is taken from `Engine.tick(delta:)` in `Sources/Ferox/Engine.swift`. The clock is `Sources/FeroxCore/Time.swift`. The window host is `Sources/Ferox/GameHost.swift`. The overall module structure is in [03-Architecture.md](03-Architecture.md), and the systems and scheduler are described in [06-Scene-and-Entities.md](06-Scene-and-Entities.md).

## Contents

1. [Lifecycle at a glance](#1-lifecycle-at-a-glance)
2. [EngineConfiguration](#2-engineconfiguration)
3. [The Game protocol](#3-the-game-protocol)
4. [Frame phases](#4-frame-phases)
5. [Fixed timestep and interpolation](#5-fixed-timestep-and-interpolation)
6. [Time scale and pause](#6-time-scale-and-pause)
7. [Frame statistics](#7-frame-statistics)
8. [Edit mode](#8-edit-mode)
9. [Quitting and shutdown](#9-quitting-and-shutdown)
10. [Headless runs](#10-headless-runs)
11. [Validation status](#11-validation-status)
12. [Limitations](#12-limitations)
13. [Related documents](#13-related-documents)

## 1. Lifecycle at a glance

1. **Configure.** Build an `EngineConfiguration`. It is plain data.
2. **Create.** `Engine(configuration:)` creates the world, the event bus, the scheduler, the scene manager, input, assets, animation, the optional physics systems, audio, the UI context and the frame clock. It registers the built-in component types. It throws `EngineError.assetRootMissing` if `assetRoot` names a folder that does not exist.
3. **Start.** `engine.start(_:)` attaches the game, resets the clock, and calls `Game.setup(engine:)`. It may be called only once per engine.
4. **Run.** Each frame calls `tick`. In a window, `GameHost` calls it once per display frame. A headless run calls `tick(delta:)` in a loop.
5. **Shut down.** `engine.shutdown()` calls `Game.shutdown(engine:)`, unloads all scenes, and stops audio. It is idempotent.

In a window, step 2 and step 3 are made by `GameHost.run`, which also creates the renderer and the window. `GameLauncher.main` calls `GameHost.run` unless `--headless` is given.

## 2. EngineConfiguration

`EngineConfiguration` is a `Sendable` struct. Its initialiser takes only the title, and every other field has a default.

```swift
var config = EngineConfiguration(title: "My Game")
config.windowSize = Vec2(1600, 900)
config.graphics = GraphicsSettings(preset: .high)
config.assetRoot = URL(fileURLWithPath: "Assets", isDirectory: true)
config.hotReloadAssets = true
config.enableAudio = true
config.physics2D = true
config.physics3D = false
config.isEditMode = false
config.shaderDirectory = nil
```

| Field | Default | Effect |
| --- | --- | --- |
| `title` | `"Ferox"` | The window title, the menu entry, and the log prefix. |
| `windowSize` | `1280` by `720` points | The initial content size of the window. The minimum applied by `GameHost` is 320 by 200. |
| `graphics` | `GraphicsSettings()` | The renderer's requested quality. Its `frame.fixedUpdateHz` sets the simulation rate. See section 5. |
| `assetRoot` | `nil` | The asset folder, an `AssetDatabase` root. When `nil`, every asset must be registered in code. |
| `hotReloadAssets` | `false` | Re-imports changed asset files while the game runs. |
| `enableAudio` | `true` | Uses the AVFoundation backend when it is available. Otherwise, or when `false`, a silent backend tracks voices without producing sound. |
| `physics2D` | `true` | Adds `PhysicsSystem2D`. Disable for a game with its own physics. |
| `physics3D` | `true` | Adds `PhysicsSystem3D`, and connects it to the asset manager for mesh colliders. |
| `isEditMode` | `false` | Starts the engine in edit mode. See section 8. |
| `shaderDirectory` | `nil` | A folder of `.metal` sources to compile and hot-reload, instead of the bundled shaders. |

`Engine.graphics` is a live copy of `graphics`. Assigning it notifies the host through `onGraphicsChanged`, and `GameHost` applies the new settings to the renderer before the next frame. The fixed-update rate is read only at construction, so changing `graphics.frame.fixedUpdateHz` later has no effect. See section 12.

## 3. The Game protocol

A game conforms to `Game`. The protocol is class-bound (`AnyObject`), and every hook has an empty default.

| Hook | When | Edit mode |
| --- | --- | --- |
| `setup(engine:) throws` | Once, from `start(_:)`, after the engine exists. A throw stops the start. | Called. |
| `fixedUpdate(engine:dt:)` | Once per fixed step. Zero, one or several times per frame. `dt` is the fixed step, in seconds. | Not called. |
| `update(engine:time:)` | Once per frame, after the fixed steps and the interpolation. | Not called. |
| `lateUpdate(engine:time:)` | Once per frame, after the late-update systems. Camera follow belongs here. | Not called. |
| `shutdown(engine:)` | Once, from `shutdown()`, before the scenes are unloaded. | Called. |

```swift
final class Platformer: Game {
    func setup(engine: Engine) throws {
        // Build the level. Throwing here stops the launch with an alert or an error.
    }

    func fixedUpdate(engine: Engine, dt: Float) {
        // Set forces and velocities here. Physics steps after this hook.
    }

    func update(engine: Engine, time: FrameTime) {
        // Sample input here: input is latched once per frame in `tick`.
    }

    func lateUpdate(engine: Engine, time: FrameTime) {
        // Move the camera after the animation has run.
    }

    func shutdown(engine: Engine) {
        // Release any event subscriptions.
    }
}
```

`Engine.start(_:)` has a precondition that a game is attached at most once. The hooks run on the main thread.

## 4. Frame phases

`SystemPhase` has five cases: `earlyUpdate`, `fixedUpdate`, `update`, `lateUpdate` and `preRender`. Systems in the same phase run in the order given by their `order` value, then in insertion order. Game hooks are not ordered by this mechanism, but run at the points shown in the table below. See [06-Scene-and-Entities.md](06-Scene-and-Entities.md), section 14.

One frame of `Engine.tick`, with the phase or hook at each step:

| Step | Call | Notes |
| --- | --- | --- |
| 1 | `clock.tick` | Produces the `FrameTime` and the number of fixed steps `n`. |
| 2 | `input.beginFrame()` | Latches the input state. |
| 3 | `earlyUpdate` systems | Input mapping and network receive belong here. |
| 4 | For each of the `n` steps: `game.fixedUpdate`, then `flushDeferred`, then `fixedUpdate` systems, then `events.flush()` | The physics systems run in the `fixedUpdate` phase. |
| 5 | Interpolation of physics poses | Uses `alpha`. See section 5. |
| 6 | `game.update`, then `flushDeferred`, then `update` systems | |
| 7 | `lateUpdate` systems, then `game.lateUpdate`, then `flushDeferred` | Animation, tweens and timelines are the `lateUpdate` systems that the engine adds. |
| 8 | `scenes.update(dt:)`, then `TransformSystem.update` | Scene transitions advance, then transforms are propagated. |
| 9 | `preRender` systems, then `events.flush()` | Render-data extraction belongs here. |
| 10 | `assets.update()`, the audio listener, `audio.update`, and `ui.update` | |

The engine adds these systems at construction, in this order:

| System | Phase | Added when |
| --- | --- | --- |
| `PhysicsSystem2D` | `fixedUpdate` | `physics2D` is `true`. |
| `PhysicsSystem3D` | `fixedUpdate` | `physics3D` is `true`. |
| `AnimationSystem` | `lateUpdate` | Always. |
| `TweenSystem` | `lateUpdate` | Always. |
| `TimelineSystem` | `lateUpdate` | Always. |

`ParticleSystem` and `TrailSystem` belong to `FeroxAnimation`, but the engine does not add them. A game adds them to `engine.scheduler` if it uses them.

The scheduler runs a system only when `isEnabled` is `true`. In edit mode it also requires `runsInEditMode`.

After `tick`, the renderer runs in `GameHost`, outside `tick`. See [03-Architecture.md](03-Architecture.md), section 3.

## 5. Fixed timestep and interpolation

The simulation advances in equal steps. Rendering uses the leftover time to blend between the last two steps. Both rules are implemented in `FeroxCore/Time.swift`.

### 5.1 The fixed step

`FixedTimestep` holds the accumulator. Its step is `1 / hz`. The engine creates the clock with `FrameClock(fixedHz:)`, using `graphics.frame.fixedUpdateHz`, which defaults to 60, and a lower bound of 1.

On each frame, `advance(by:)` adds the scaled delta to the accumulator and returns the number of whole steps. The steps are capped at `maxStepsPerFrame`, which defaults to 8. Time beyond the cap is discarded and added to `droppedTime`. The cap prevents a "spiral of death", in which a slow frame causes more steps, which makes the next frame slower still.

### 5.2 Frame delta

`FrameClock` converts wall-clock time into the frame delta.

- The raw delta is `now - last`. The first sample has no predecessor, so its raw delta is `0`.
- The raw delta is clamped to `maxDelta`, which is `0.25` seconds by default. A breakpoint or a window drag therefore cannot advance the game by seconds at once.
- The scaled delta is the clamped delta times `timeScale`, or `0` while `isPaused` is `true`.
- `FrameTime.unscaledDelta` keeps the raw delta, which is what the profiler and the frame statistics use.

With an explicit delta, the clock reads the previous time and adds the delta. Explicit deltas are used by headless runs. They are subject to the same clamp, so a delta above `0.25` is reduced to `0.25`.

```swift
var clock = FrameClock(fixedHz: 60)
_ = clock.tick(delta: 1.0 / 30)                  // the first sample: no previous time, so delta is 0
let (frame, steps) = clock.tick(delta: 1.0 / 30)
// frame.delta is 1/30 seconds, steps is 2, and frame.interpolationAlpha is 0
```

### 5.3 FrameTime

`Engine.tick` returns a `FrameTime` and stores it as `engine.time`. The fields are:

| Field | Meaning |
| --- | --- |
| `delta` | Scaled, clamped frame delta, in seconds. |
| `unscaledDelta` | Raw wall-clock delta, in seconds. |
| `elapsed` | Scaled game time since the first frame, in seconds. |
| `frameIndex` | Monotonic frame counter, starting at 1 on the first tick. |
| `fixedDelta` | The fixed step, in seconds. |
| `interpolationAlpha` | The fraction in [0, 1) of the next fixed step already elapsed. |

The single-precision accessors `deltaF`, `fixedDeltaF` and `alphaF` convert to `Float`.

### 5.4 Interpolation

After the fixed steps, `Engine.tick` calls `interpolate(_:alpha:)` on both physics systems. The alpha is the fraction of the next fixed step already accumulated. For each body that is awake, is not static, and has its `RigidBody2D` or `RigidBody3D` component's `interpolate` flag set (the default, `true`), the physics system writes a pose blended between the last two steps into the entity's `Transform`. Motion then looks smooth when the render rate is not the simulation rate. The simulation itself is not affected. Gameplay code that reads the `Transform` after this point sees the interpolated pose. Sleeping and static bodies keep their last stepped pose.

```swift
// Turn the interpolation off for one body, for example one that teleports.
world.modify(RigidBody2D.self, player) { $0.interpolate = false }
```

Physics behaviour, including the blend, is described in [13-Physics.md](13-Physics.md).

## 6. Time scale and pause

`engine.clock` is a public `var`. Two properties change the simulation without any other code.

```swift
engine.clock.timeScale = 0.5    // half-speed simulation; rendering continues at full rate
engine.clock.isPaused = true    // stops game time; FrameTime.delta becomes 0
```

With `isPaused`, no fixed steps run and `delta` is zero. `unscaledDelta` keeps reporting the wall-clock time, so a pause menu can still animate. `timeScale` multiplies the clamped delta, and the fixed steps are taken from the scaled accumulator.

## 7. Frame statistics

`Engine.frameStatistics` keeps the last 240 unscaled frame durations in a ring buffer. Its source comment names the profiler overlay and `FeroxDiag` as users. In this snapshot, `FeroxDiag` does not read it.

| Member | Result |
| --- | --- |
| `average` | Mean duration, in seconds. |
| `averageFPS` | `1 / average`, or `0` before any sample. |
| `minimum`, `maximum` | The shortest and longest durations in the window. |
| `percentile(_:)` | The duration at a percentile in [0, 100]. `percentile(99)` is the "1 per cent low" duration. |
| `standardDeviation` | The spread of the durations, which measures frame pacing. |
| `hitchCount(budget:)` | The number of frames longer than one and a half times the budget. |

```swift
let stats = engine.frameStatistics
let fps = stats.averageFPS
let worst = stats.percentile(99)   // seconds
```

These figures are measured on the machine that runs the game. This document does not give any expected value. See [21-Performance.md](21-Performance.md).

## 8. Edit mode

Edit mode is a state in which the scene can be edited without being simulated. It is set by the `isEditMode` property, which starts from `configuration.isEditMode`. The editor core, `EditorSession` in `Sources/Ferox/EditorSession.swift`, uses it for Play and Stop. See [22-Editor.md](22-Editor.md).

In edit mode:

- `Game.fixedUpdate`, `Game.update` and `Game.lateUpdate` are not called. `setup` and `shutdown` still are.
- Systems are run only if their `runsInEditMode` property is `true`. The default is `false`. Of the systems in `FeroxAnimation` and `FeroxPhysics`, only `ParticleSystem` sets it to `true`. The physics, animation, tween and timeline systems keep the default, so they do not run in edit mode.
- The fixed-step loop still runs and still flushes events, but with no systems to run it does no simulation.
- `interpolate` is called on the physics systems without an edit-mode check, so awake bodies still have their `Transform` set to the interpolated pose.

```swift
engine.isEditMode = true    // stop: edit the scene, no gameplay hooks
engine.isEditMode = false   // play: hooks and systems run again
```

The flag can be changed at any time from the thread that drives the engine.

## 9. Quitting and shutdown

`engine.requestQuit()` sets `quitRequested`. In a window, `GameHost` closes the window at the end of the frame. A headless loop checks the flag before each tick.

`engine.shutdown()` does the following, once:

1. Sets `isShutDown`, so later calls to `tick` return at once.
2. Calls `Game.shutdown(engine:)`.
3. Releases the game.
4. Calls `scenes.unloadAll()`.
5. Calls `audio.update(dt: 0)`.

In a window, closing the window calls `GameHost.shutdown()`. That method pauses the view, calls `engine.shutdown()`, waits for the GPU to go idle with `renderer.waitUntilIdle()`, and purges the renderer's caches. The application then terminates. Quitting from the menu also reaches `GameHost.shutdown()` through the application delegate. Both paths are idempotent.

## 10. Headless runs

`GameLauncher.runHeadless` is the path for `--headless`. It differs from a window run in four ways:

- audio is disabled, by setting `enableAudio` to `false` on a copy of the configuration;
- there is no renderer, no window and no `GameHost`;
- every frame is `tick(delta:)` with the same delta, so the run is deterministic in its timing;
- the loop stops after `--frames` frames, or earlier if `quitRequested` is set.

The summary line that follows the loop reports the frame count, the game time (`frames × delta`), the wall time, and the number of entities in the world. A failure in `Engine` creation or `start` prints an error and exits with status 1.

A game can also run headless from code, as in [02-Getting-Started.md](02-Getting-Started.md), section 6:

```swift
let engine = try Engine(configuration: EngineConfiguration(title: "Test"))
try engine.start(game)
engine.simulate(frames: 600, delta: 1.0 / 60)
engine.shutdown()
```

Two runs with the same inputs and the same delta follow the same timing. The simulation results may still differ between runs, because the physics solver does not guarantee repeatable contact order. See [13-Physics.md](13-Physics.md).

## 11. Validation status

- The frame order, the configuration fields and the clock arithmetic were read from the source. None of them has been executed.
- The first-sample behaviour and the clamping were checked against the code in `FrameClock.tick(now:)`.
- No frame time, memory or latency figure is given.

## 12. Limitations

- **Limitation: the fixed rate is read once.** `FrameClock` is created from `graphics.frame.fixedUpdateHz` in the initialiser. A later change to `graphics` does not alter the simulation rate. Set it in the configuration before the engine is created.
- **Limitation: a 0.25 second delta clamp.** Longer frames are simulated as 0.25 seconds. Game time runs slower than wall time during a hitch.
- **Limitation: at most 8 fixed steps per frame.** Time beyond the cap is dropped. Long hitches therefore lose game time.
- **Limitation: one game per engine.** `start` may be called once.
- **Limitation: headless timing is fixed.** `--dt` sets the delta for every frame, so headless runs do not show frame-rate effects.

## 13. Related documents

- [03-Architecture.md](03-Architecture.md): the frame in the context of the modules, the host and the renderer.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): systems, phases, the scheduler and deferred changes.
- [08-Rendering-3D.md](08-Rendering-3D.md): what the renderer does with each frame.
- [13-Physics.md](13-Physics.md): the fixed-step physics and interpolation.
- [22-Editor.md](22-Editor.md): the editor core that uses edit mode.
- [21-Performance.md](21-Performance.md): measuring the phases.
