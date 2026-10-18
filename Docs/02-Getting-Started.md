# Getting Started

This document covers the requirements for building Ferox, the commands that build and run the bundled examples, the command-line options that every game accepts, and the smallest program that uses the engine. The examples are the best reference for working code: `Examples/HelloFerox` is shown in full below, and the other two examples are described briefly. Nothing in this document has been built or run on hardware. The commands and behaviour are taken from `Package.swift`, `Sources/Ferox/Launcher.swift` and the example sources. See [01-Overview.md](01-Overview.md), section 7, for what has and has not been verified.

## Contents

1. [Requirements](#1-requirements)
2. [Building](#2-building)
3. [Running the examples](#3-running-the-examples)
4. [Launcher options](#4-launcher-options)
5. [Writing a minimal game](#5-writing-a-minimal-game)
6. [Running a game without a window](#6-running-a-game-without-a-window)
7. [Configuring a game](#7-configuring-a-game)
8. [Limitations](#8-limitations)
9. [Related documents](#9-related-documents)

## 1. Requirements

| Requirement | Value | Source |
| --- | --- | --- |
| Operating system | macOS 14 or later | `Package.swift`: `platforms: [.macOS(.v14)]` |
| Hardware | Apple Silicon is the primary target. Metal support is required for the window and the renderer. | `CONTRIBUTING.md` |
| Toolchain | Swift 5.10, which ships with Xcode 15.3. | `Package.swift`: `swift-tools-version:5.10` |
| Command-line tools | Installed with `xcode-select --install`. | `CONTRIBUTING.md` |

`CONTRIBUTING.md` and the CI workflow ask for Xcode 15.4, which also provides Swift 5.10. Xcode 15.3 is the minimum that the package manifest requires. Use Xcode 15.4 or later if you want to match CI.

Headless runs need a Swift toolchain on any platform, but only the portable modules are built on Linux in CI. See [04-Building-and-Testing.md](04-Building-and-Testing.md).

## 2. Building

Run these commands from the repository root:

```sh
swift build                 # debug build of every product and target
swift build -c release      # optimised build
swift test                  # runs the test targets that exist (see document 04)
```

To work in Xcode, open `Package.swift` directly. Xcode resolves the package and makes every target available. `CONTRIBUTING.md` gives this as the alternative to the command line.

The package has no third-party dependencies. `swift build` compiles the Metal sources in `Sources/FeroxRender/Shaders` at run time, not at build time. They are copied into the module bundle as resources (`Package.swift`: `resources: [.copy("Shaders")]`). A shader compile error therefore appears when a renderer starts, not when the package builds. See [04-Building-and-Testing.md](04-Building-and-Testing.md).

## 3. Running the examples

Each example is an executable product. Arguments after the product name are passed to the program.

```sh
swift run HelloFerox                 # opens a window (macOS)
swift run Platformer2D               # opens a window (macOS)
swift run Showcase3D                 # opens a window (macOS)

swift run HelloFerox --headless --frames 120
```

| Example | What it shows | Controls |
| --- | --- | --- |
| `HelloFerox` | A lit, spinning copper cube on a grey plane, a directional light, a procedural sky and a frame-rate label. | None. |
| `Platformer2D` | A side-scrolling platformer with 2D physics, trigger pick-ups, an orthographic camera that follows the player, and a coin counter. Uses shapes only. | A/D or the arrow keys (or the left stick) move. Space (or the south button) jumps. |
| `Showcase3D` | A 7 by 7 grid of PBR spheres, falling crates, orbiting point lights, a shadow-casting sun, a reflection probe, and a settings panel for quality presets, anti-aliasing and ray tracing. | W, A, S and D, or the left stick, orbit and zoom the camera. |

`Platformer2D` sets `physics3D = false` and `graphics.post.toneMapper = .none`. `Showcase3D` sets `physics2D = false` and uses `GraphicsSettings(preset: .high)`. The reasons for these choices are in [07-Rendering-2D.md](07-Rendering-2D.md) and [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md).

On macOS without the `--headless` flag, `GameLauncher.main` hands the game to `GameHost`, which opens a window and runs until it is closed. On a platform without AppKit and MetalKit, the launcher always runs headless. The renderer does not exist in that mode, so nothing is drawn.

## 4. Launcher options

Every game that calls `GameLauncher.main(_:configuration:)` accepts these options. The parser ignores anything it does not recognise, so a game may define its own flags.

| Option | Default | Meaning |
| --- | --- | --- |
| `--headless` | off | Run the simulation without a window or renderer. |
| `--frames N` | `600` | Number of frames to simulate in headless mode. Clamped to the range 0 to 10,000,000. |
| `--dt d` | `1/60` | Fixed delta in seconds for each headless frame. Accepted only if finite, greater than 0 and no more than 1. Other values are ignored, and the default is kept. |

A headless run prints one summary line when it finishes:

```text
Hello Ferox: simulated 120 frames (2.00 s game time) in 0.004 s wall time; 3 entities
```

The game time is `frames × dt`, so with the default `dt` it is exact. The wall time and entity count depend on the machine and the game, and are not reported here. If the engine or `Game.setup` throws, the launcher prints an error and exits with status 1.

## 5. Writing a minimal game

A game is a class that conforms to `Game`. Every hook has an empty default, so a game implements only the hooks it needs. `setup(engine:)` builds the scene once. `update(engine:time:)` runs once per rendered frame.

The following program is a complete game. It mirrors `Examples/HelloFerox`, without the frame-rate label.

```swift
import Ferox

final class SpinGame: Game {
    private var cube = Entity.null

    func setup(engine: Engine) throws {
        let world = engine.world

        // Assets can be registered in code, as here, or loaded from a folder
        // (EngineConfiguration.assetRoot). Ids are stable strings.
        let cubeMesh = AssetID("spin.mesh.cube")
        _ = engine.assets.registerMesh(.cube(size: 1), id: cubeMesh)

        cube = world.createEntity(named: "Cube", transform: Transform(position: Vec3(0, 0.5, 0)))
        world.add(MeshRenderer(mesh: cubeMesh), to: cube)

        // Directional lights shine along their entity's forward (-Z) axis.
        let sun = world.createEntity(
            named: "Sun",
            transform: Transform(rotation: .lookRotation(forward: Vec3(-0.4, -1, -0.3).normalized)))
        world.add(Light.directional(intensity: 4, shadows: true), to: sun)

        let camera = world.createEntity(
            named: "Camera",
            transform: Transform(position: Vec3(0, 2, 4.5),
                                 rotation: .lookRotation(forward: Vec3(0, -0.3, -1).normalized)))
        world.add(Camera.perspective(fov: 55), to: camera)

        let environment = world.createEntity(named: "Environment")
        world.add(Environment(), to: environment)
    }

    func update(engine: Engine, time: FrameTime) {
        engine.world.modify(Transform.self, cube) {
            $0.rotation = Quat(angle: Float(time.elapsed), axis: Vec3(0, 1, 0))
        }
    }
}

@main
enum SpinGameMain {
    @MainActor static func main() {
        GameLauncher.main(SpinGame(), configuration: EngineConfiguration(title: "Spin"))
    }
}
```

The pattern has four parts:

1. **Assets.** `engine.assets.registerMesh(_:id:)` registers a generated mesh under an `AssetID`. A `MeshRenderer` refers to the mesh by that id, so the same id works in code and in a scene file.
2. **Entities.** `world.createEntity(named:transform:)` creates an entity with a name and a transform. `world.add(_:to:)` attaches components. The entity is the handle, and the components hold the data. See [06-Scene-and-Entities.md](06-Scene-and-Entities.md).
3. **Per-frame code.** `update(engine:time:)` changes a component through `world.modify`. `FrameTime.elapsed` is scaled game time in seconds.
4. **Entry point.** The `@main` type calls `GameLauncher.main`. The launcher parses the options in section 4, creates the engine, starts the game, and runs the frame loop or the headless loop.

`Engine` is not thread-safe, and `Game` hooks are called on the main thread. Keep game code on the main thread.

## 6. Running a game without a window

Headless simulation is also available from code, which is useful for tests and servers. `Engine` is platform-independent. Its constructor and `simulate(frames:delta:)` do not touch Metal.

```swift
let config = EngineConfiguration(title: "Spin")
let engine = try Engine(configuration: config)
try engine.start(SpinGame())
engine.simulate(frames: 120, delta: 1.0 / 60)
print(engine.world.count(of: Transform.self))
engine.shutdown()
```

`start(_:)` may be called only once per engine. `shutdown()` calls the game's `shutdown(engine:)` and unloads every scene. It is safe to call more than once. The loop itself is described in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md).

`GameLauncher.runHeadless` sets `enableAudio` to `false`. Code that drives an `Engine` directly keeps the configuration's value, which defaults to `true`. If the AVFoundation output cannot be opened, the engine falls back to a silent backend and logs a warning, so no special handling is needed.

## 7. Configuring a game

`EngineConfiguration` is plain data, and every field has a default. The fields most often changed at start-up are:

```swift
var config = EngineConfiguration(title: "Platformer")
config.windowSize = Vec2(1280, 720)           // initial window size in points
config.physics3D = false                      // no 3D physics in a 2D game
config.graphics.post.toneMapper = .none       // 2D art is authored in display colours
config.assetRoot = URL(fileURLWithPath: "Assets", isDirectory: true)
```

Each field is described in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). Quality settings are in `GraphicsSettings`, described in [08-Rendering-3D.md](08-Rendering-3D.md), and in [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md).

## 8. Limitations

- **Limitation: nothing has been built or run in this snapshot.** The commands in this document are taken from the manifest and the sources. They have not been executed. See [01-Overview.md](01-Overview.md), section 7.
- **Limitation: windowed mode is macOS only.** The renderer and `GameHost` need AppKit and Metal.
- **Limitation: a shader compile error appears at run time.** The Metal sources are compiled by the renderer when it starts. See [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md).
- **Limitation: Xcode version.** The manifest requires Swift 5.10. CI selects Xcode 15.4. The two are not stated consistently across the repository.

## 9. Related documents

- [01-Overview.md](01-Overview.md): what the engine is, and what is verified.
- [03-Architecture.md](03-Architecture.md): how the frame loop, the host and the renderer fit together.
- [04-Building-and-Testing.md](04-Building-and-Testing.md): build and test commands, CI, and the tools.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): configuration, hooks, the frame loop, and headless runs.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): the ECS world used in the examples.
- [27-Troubleshooting.md](27-Troubleshooting.md): problems that occur when running the examples.
