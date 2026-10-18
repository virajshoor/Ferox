# Gameplay API

A Ferox game is a class that conforms to the `Game` protocol. The game receives an `Engine` in its hooks and uses it to create entities, register assets, read input and drive the UI. The `Ferox` umbrella module, which games import, owns three pieces that sit around that class: `Engine`, which runs the frame; `GameHost`, which opens a macOS window and drives the engine once per display refresh; and `GameLauncher`, which parses command-line flags and chooses between the two.

This document describes the public surface a game programmer uses. It is written from the source and the three examples in `Examples/`. Nothing here has been compiled or run on macOS. The examples are not verified to build or to open a window, and no frame rates or timings are reported.

The frame order and the phase model are explained in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). Entities and components are in [06-Scene-and-Entities.md](06-Scene-and-Entities.md). Input actions are in [14-Input.md](14-Input.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [The Game protocol](#2-the-game-protocol)
3. [Configuring the engine](#3-configuring-the-engine)
4. [Engine lifecycle](#4-engine-lifecycle)
5. [Frame order](#5-frame-order)
6. [Systems](#6-systems)
7. [Running a game](#7-running-a-game)
8. [The macOS host](#8-the-macos-host)
9. [Runtime graphics settings](#9-runtime-graphics-settings)
10. [The examples](#10-the-examples)
11. [Code examples](#11-code-examples)
12. [Threading and ownership rules](#12-threading-and-ownership-rules)
13. [Limitations](#13-limitations)
14. [Validation status](#14-validation-status)
15. [Related documents](#15-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| `Game` protocol and default hooks | Implemented: `Engine.swift`. |
| `Engine` (tick, simulate, lifecycle) | Implemented: `Engine.swift`. Platform-independent. |
| `EngineConfiguration` | Implemented: `Engine.swift`. |
| `GameLauncher` (flags, headless run) | Implemented: `Launcher.swift`. The headless path creates no renderer and no window. |
| `GameHost` (window, Metal view, frame pacing) | Implemented: `GameHost.swift`, macOS only. **Not run on hardware.** |
| Examples | Three programs in `Examples/`. **Not built or run.** |
| Automated tests | `Tests/FeroxIntegrationTests/EngineTests.swift` drives `Engine` headlessly. It has not been run here. |

## 2. The Game protocol

`Game` is a class-bound protocol with five hooks. Every hook has an empty default in an extension, so a game implements only what it needs:

```swift
public protocol Game: AnyObject {
    func setup(engine: Engine) throws
    func fixedUpdate(engine: Engine, dt: Float)
    func update(engine: Engine, time: FrameTime)
    func lateUpdate(engine: Engine, time: FrameTime)
    func shutdown(engine: Engine)
}
```

| Hook | When | Use it for |
| --- | --- | --- |
| `setup` | Once, after the engine is ready. Throws to abort startup. | Creating the world, registering assets, subscribing to events, building the UI. |
| `fixedUpdate` | Zero to many times per frame, at the fixed rate. | Deterministic gameplay that must agree with physics. |
| `update` | Once per rendered frame. | Variable-rate gameplay, input sampling, HUD text. |
| `lateUpdate` | Once per frame, after animation. | Camera follow. |
| `shutdown` | Once, before the engine stops. | Unsubscribing from events and releasing resources. |

Hooks run on the main thread. `Engine.start(_:)` attaches the game and calls `setup`. Only one game can be attached; a second call is a precondition failure. The engine holds the game strongly until `shutdown()`.

## 3. Configuring the engine

`EngineConfiguration` is plain data. Build it in code, or load it from your own project file.

| Property | Default | Effect |
| --- | --- | --- |
| `title` | `"Ferox"` | Window title on macOS and the log prefix. |
| `windowSize` | 1280 × 720 | Initial window content size in points. |
| `graphics` | `GraphicsSettings()` | Renderer quality. `graphics.frame.fixedUpdateHz` sets the simulation rate. |
| `assetRoot` | `nil` | Folder that an `AssetDatabase` reads. `nil` means assets must be registered in code. |
| `hotReloadAssets` | `false` | Re-imports changed asset files while running. |
| `enableAudio` | `true` | Uses `AVAudioBackend` where available. `false` gives a silent backend. |
| `physics2D` / `physics3D` | `true` | Adds the built-in physics systems. Disable them if the game has its own. |
| `isEditMode` | `false` | Edit mode: only systems that opt in run, and game hooks are skipped. |
| `shaderDirectory` | `nil` | Compiles and hot-reloads shaders from this folder. See [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md). |

`Engine.init(configuration:)` throws `EngineError.assetRootMissing` if the asset folder does not exist. It also registers the built-in component types with the serialisation registry, which is safe to repeat.

## 4. Engine lifecycle

The sequence a game goes through is:

1. Create the engine: `try Engine(configuration:)`.
2. Attach the game: `try engine.start(game)`. This calls `setup`.
3. Run frames: `engine.tick()` on a real clock, or `engine.tick(delta:)` for deterministic stepping.
4. Stop: `engine.requestQuit()` asks the host to close after the current frame. `engine.shutdown()` calls `shutdown` on the game, unloads every scene and updates the audio backend once with zero delta.

`tick(delta:)` runs one frame and returns its `FrameTime`. Passing `nil` reads the monotonic clock. `simulate(frames:delta:)` runs a fixed number of frames with an explicit delta, which is how headless tests and servers step the world. After `shutdown()` the engine ignores further ticks.

Useful properties include `time` (the last frame's `FrameTime`), `frameStatistics` (a rolling window, with `averageFPS`), `quitRequested`, `isShutDown` and `isEditMode`. `activeCamera()` returns the enabled camera with the highest priority, which the renderer and the audio listener both use.

The engine's subsystems are public properties: `world`, `events`, `scheduler`, `scenes`, `input`, `assets`, `animation`, `physics2D`, `physics3D`, `audio` and `ui`. `clock` is a `FrameClock`. Setting `clock.timeScale` slows or speeds the simulation, and setting `clock.isPaused` pauses it while rendering continues.

## 5. Frame order

`Engine.tick` runs the frame in this order. The comments in `Engine.swift` describe the same sequence.

1. `earlyUpdate` systems.
2. For each fixed step (0 to N per frame): `fixedUpdate(engine:dt:)` on the game, a `flushDeferred()` on the world, the `fixedUpdate` systems (physics runs here), then `events.flush()`.
3. Physics interpolation for bodies that opt in, using `FrameTime.interpolationAlpha`.
4. `update(engine:time:)` on the game, then a `flushDeferred()`, then the `update` systems.
5. `lateUpdate` systems (animation), then `lateUpdate(engine:time:)` on the game, then a `flushDeferred()`.
6. Scene manager update, transform propagation, `preRender` systems, and an event flush.
7. Asset manager update, audio listener update, audio backend update, and UI update and layout.

In edit mode, step 2's game hook and steps 4 and 5's game hooks are skipped. Systems run only if they opt in with `runsInEditMode`.

Deferred structural changes made in a hook, such as destroying an entity while iterating, are applied at the next `flushDeferred()`. The scheduler also calls `flushDeferred()` after each system it runs. The examples use `world.deferStructural { ... }` for this when they react to events.

## 6. Systems

A system is a unit of behaviour that runs in a `SystemPhase`. The phases, in order, are `earlyUpdate`, `fixedUpdate`, `update`, `lateUpdate` and `preRender`. Systems in the same phase run in ascending `order`. The built-in physics, animation, tween and timeline systems are systems too.

The `System` protocol has a `phase`, an `order`, a `runsInEditMode` flag, an `isEnabled` flag, an `update(world:context:)` method and `attach` and `detach` calls, which are called when the system is added to or removed from a scheduler. The scheduler sorts systems by phase, then `order`, then insertion order, and runs each one inside a profiler scope named after its type. `ClosureSystem` wraps a closure, which is enough for most game logic:

```swift
engine.scheduler.add(ClosureSystem("Spin", phase: .update, order: 10) { world, context in
    world.forEach(Transform.self) { _, t in
        t.rotation = t.rotation * Quat(angle: context.dt, axis: Vec3(0, 1, 0))
    }
})
```

Use a hook when the logic is specific to the game object. Use a system when the logic applies to every entity that has a set of components, or when it must run in a particular phase relative to the built-in systems.

## 7. Running a game

`GameLauncher.main(_:configuration:arguments:)` is the usual entry point. It parses the process arguments and either opens a window or runs headless:

```swift
@main
enum MyGameMain {
    @MainActor static func main() {
        GameLauncher.main(MyGame(), configuration: EngineConfiguration(title: "My Game"))
    }
}
```

The launcher understands three flags, and ignores anything else so that a game can add its own:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--headless` | off | Simulate without a window or renderer. Audio is disabled. |
| `--frames N` | 600 | Number of frames to simulate in headless mode. Clamped to 0 to 10 000 000. |
| `--dt S` | 1/60 | Fixed delta in seconds for headless mode. Must be greater than 0 and at most 1. |

Headless runs print one summary line: the title, the number of frames, the game time simulated, the wall-clock time and the entity count. The wall-clock figure is whatever the machine produced; this documentation does not report one.

`GameLauncher.runHeadless(_:configuration:options:)` is the same path called directly, which is convenient in tests.

## 8. The macOS host

`GameHost` is the window and Metal front end. `GameHost.run(_:configuration:configure:)` creates the `Engine`, the host and the renderer, attaches the game, and starts the application loop. The optional `configure` closure runs after the host exists and before `setup`; the editor uses it to install its panels. Fatal startup errors are shown in an alert and the process exits with status 1.

Each display refresh the host:

1. Polls input and sets the viewport size and backing scale on the UI.
2. Calls `engine.tick()`.
3. Calls the `onFrame` hook, if one is set.
4. Acquires the drawable as late as possible, then renders the world with the UI.
5. Closes the window if `quitRequested` is set.

Frame pacing follows `graphics.frame`. `targetFPS` of `nil` means the display's maximum refresh rate, capped by the screen. `vsync` maps to the layer's display-sync setting. `maxFramesInFlight` bounds how many frames the CPU can run ahead of the GPU. `applyFramePacing()` reapplies these after a change.

Closing the window calls `GameHost.shutdown()`, which shuts the engine down, waits for the GPU and purges the renderer's caches. Quitting from the application menu does the same through the application delegate.

## 9. Runtime graphics settings

`engine.graphics` is a live copy of `GraphicsSettings`. Assigning to it calls `onGraphicsChanged` when the value actually changes, and the host forwards the new settings to the renderer and reapplies frame pacing before the next frame. A headless engine simply stores the value.

The Showcase example uses this to switch presets and anti-aliasing live:

```swift
var g = engine.graphics
g.apply(QualityPreset.high)
engine.graphics = g
```

`GraphicsSettings.apply(_:)` sets the group of values that a preset implies. Individual fields can then be changed, as the Showcase does with `antiAliasing.mode` and `rayTracing.enabled`.

## 10. The examples

Three executables in `Examples/` are declared in `Package.swift`. Each is a complete program.

| Example | File | Shows |
| --- | --- | --- |
| `HelloFerox` | `Examples/HelloFerox/HelloFerox.swift` | Procedural meshes and materials, a directional light, a camera, an environment, a UI label, and a per-frame `update` hook that spins the cube. Headless run: `swift run HelloFerox --headless --frames 120`. |
| `Platformer2D` | `Examples/Platformer2D/Platformer2D.swift` | 2D physics with static and dynamic bodies, triggers and collision events, action-mapped movement, a following orthographic camera, and a score HUD. Disables 3D physics and tone mapping. |
| `Showcase3D` | `Examples/Showcase3D/Showcase3D.swift` | PBR material sweep, rigid-body crates, animated point lights, a reflection probe, fog, and a settings panel with presets, an anti-aliasing dropdown and a ray-tracing toggle. Disables 2D physics. |

The examples are written to show the API, not to be a template for production code. `Platformer2D` shows the usual split: physics velocities are set in `fixedUpdate`, input is sampled in `update` so a tap between fixed steps is not lost, and the camera follows in `lateUpdate`. Its controls are A/D or the arrow keys, and Space to jump.

## 11. Code examples

A complete game that spins a cube and subscribes to a collision event:

```swift
import Ferox

final class SpinGame: Game {
    private var cube = Entity.null
    private var subscription: Subscription?

    func setup(engine: Engine) throws {
        _ = engine.assets.registerMesh(.cube(size: 1), id: AssetID("spin.cube"))
        cube = engine.world.createEntity(named: "Cube", transform: Transform(position: Vec3(0, 1, 0)))
        engine.world.add(MeshRenderer(mesh: AssetID("spin.cube")), to: cube)

        subscription = engine.events.subscribe(CollisionEvent2D.self) { event in
            print("contact began: \(event.phase)")
        }
    }

    func update(engine: Engine, time: FrameTime) {
        engine.world.modify(Transform.self, cube) {
            $0.rotation = Quat(angle: Float(time.elapsed), axis: Vec3(0, 1, 0))
        }
    }

    func shutdown(engine: Engine) {
        if let subscription { engine.events.unsubscribe(subscription) }
    }
}
```

Running it headless for a deterministic number of frames, which is how a server or a test would use it:

```swift
var options = GameLauncher.Options()
options.frames = 120
options.delta = 1.0 / 60
GameLauncher.runHeadless(SpinGame(), configuration: EngineConfiguration(title: "Spin"), options: options)
```

Stepping the engine directly in a unit test, with audio off:

```swift
var config = EngineConfiguration(title: "Test")
config.enableAudio = false
let engine = try Engine(configuration: config)
try engine.start(SpinGame())
engine.simulate(frames: 60, delta: 1.0 / 60)
engine.shutdown()
```

Reading the active camera, for a game that needs to know where the view is:

```swift
if let cam = engine.activeCamera() {
    print("camera entity \(cam.entity), priority \(cam.camera.priority)")
}
```

## 12. Threading and ownership rules

- Create, drive and mutate the engine from one thread: the main thread when there is a window. `Engine` is documented as not thread safe.
- Every game hook runs on the main thread. The examples use `@MainActor` on the entry point because `GameHost` and `GameLauncher.main` are main-actor isolated.
- Event handlers run synchronously when an event is flushed. Use `events.enqueue(_:)` for deferred delivery and `events.publish(_:)` for immediate delivery.
- Structural changes to the world during iteration should go through `world.deferStructural { ... }` and are applied at the next flush.
- Subscriptions and closures that capture the engine should use `[weak engine]` where they could outlive it, as the examples do.
- The game is held strongly by the engine. `shutdown()` releases it.

## 13. Limitations

- **One game per engine.** `start(_:)` can be called once. There is no runtime switching of games; scenes handle level changes instead.
- **No built-in configuration file.** `EngineConfiguration` is not `Codable`, so loading it from a file is left to the game.
- **Headless output is text.** `runHeadless` prints one summary line. It does not write frames, traces or metrics.
- **Windowed mode is macOS only.** `GameHost` and the window path are compiled only where AppKit and MetalKit exist. Other platforms run headless.
- **The examples are unverified.** They are not built in this review, and their window behaviour has not been seen.
- **`GameHost.run` does not return.** Closing the window terminates the application, so code after the call does not run. Put clean-up in `Game.shutdown(engine:)`.
- **No render hook on `Game`.** The game hooks do not include a rendering step. `GameHost.onFrame` is the host-level hook, documented for drawing such as editor gizmos.
- **Audio shutdown is partial.** `Engine.shutdown()` updates the audio backend but does not stop voices. See [16-Audio.md](16-Audio.md).
- **Frame statistics are simple.** `frameStatistics` is a rolling average. Detailed timing is in [21-Performance.md](21-Performance.md).

## 14. Validation status

This document was written from the source. No macOS machine or Swift toolchain was available while the engine was written, so none of the three examples has been built, and no window has been opened. The headless path is simpler and is the one most likely to be exercised first, but it too has not been run.

`Tests/FeroxIntegrationTests/EngineTests.swift` exercises the headless engine, and `Tests/FeroxIntegrationTests/EditorSessionTests.swift` exercises the editor core. Neither has been run for this document. The CI workflow runs `swift test` on macOS, and on Linux it runs only a filtered set that includes the integration tests. No test covers `GameHost` or `GameLauncher.main`.

## 15. Related documents

- [01-Overview.md](01-Overview.md) for what Ferox is and how its modules fit.
- [02-Getting-Started.md](02-Getting-Started.md) for building and running the examples.
- [03-Architecture.md](03-Architecture.md) for the module graph.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md) for the frame and its phases in more depth.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md) for the world, entities and components.
- [14-Input.md](14-Input.md) for actions, the input state and controllers.
- [15-User-Interface.md](15-User-Interface.md) for the UI that the game drives.
- [18-Assets.md](18-Assets.md) for registering and loading assets.
- [22-Editor.md](22-Editor.md) for the editor, which is built on the same engine in edit mode.
- [29-API-Reference.md](29-API-Reference.md) for the complete list of public types.
