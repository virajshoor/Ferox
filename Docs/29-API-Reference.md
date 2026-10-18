# API Reference

This document is an index of the main public types in each Ferox module. Each entry has one line, taken or shortened from the type's doc comment. It is a map for finding the right type, not a complete reference: it lists the main types only and does not show members, signatures or every overload.

The index was built from the source with a search for `public` declarations in each `Sources/<Module>` directory. Types marked **(macOS)** are declared inside files guarded by `#if canImport(...)` for an Apple framework, and they exist only on Apple platforms. See [25-Platform-Support.md](25-Platform-Support.md) for the guards.

Full symbol documentation can be generated from these doc comments with DocC. The package does not declare the DocC plugin, so use Xcode's Build Documentation command, or add the `swift-docc-plugin` package to generate it from the command line. This document does not replace that output.

## Contents

1. [FeroxMath](#1-feroxmath)
2. [FeroxCore](#2-feroxcore)
3. [FeroxScene](#3-feroxscene)
4. [FeroxPhysics](#4-feroxphysics)
5. [FeroxAnimation](#5-feroxanimation)
6. [FeroxInput](#6-feroxinput)
7. [FeroxAssets](#7-feroxassets)
8. [FeroxNet](#8-feroxnet)
9. [FeroxAudio](#9-feroxaudio)
10. [FeroxUI](#10-feroxui)
11. [FeroxRender](#11-feroxrender)
12. [Ferox (umbrella)](#12-ferox-umbrella)
13. [Related documents](#13-related-documents)

## 1. FeroxMath

Vector, matrix, geometry and colour types. Platform-independent. Source: `Sources/FeroxMath`.

| Type | Description |
| --- | --- |
| `Vec2`, `Vec3`, `Vec4`, `IVec2`, `UVec2` | Vector typealiases over Swift's SIMD types. `Vec2`, `Vec3` and `Vec4` are `SIMD2<Float>`, `SIMD3<Float>` and `SIMD4<Float>`. |
| `Mat3`, `Mat4` | Column-major matrices. `Mat4` is layout-compatible with Metal's `float4x4`. |
| `Affine2D` | Column-major 2D affine transform, used by the 2D renderer and the UI. |
| `Quat` | Unit quaternion `(x, y, z, w)`, matching glTF and Metal conventions. |
| `TRS` | Translation, rotation and scale, for local and world transforms. |
| `Color` | Linear-space RGBA colour with straight alpha. Use `init(srgb:)` for sRGB input. |
| `Gradient` | Colour gradient with arbitrary stops, evaluated in linear space. |
| `AABB`, `Rect`, `EdgeInsets` | Axis-aligned bounds, 2D rectangles and UI insets. |
| `Ray`, `Sphere`, `Plane`, `Frustum` | Geometry primitives. `Frustum` is extracted from a view-projection matrix. |
| `PCG32` | Deterministic random number generator, suited to replays, networking and tests. |
| `Halton` | Low-discrepancy sequence, used for TAA jitter and sampling. |

## 2. FeroxCore

Configuration, logging, events, timing, profiling and safety types shared by the other modules. Source: `Sources/FeroxCore`.

| Type | Description |
| --- | --- |
| `GraphicsSettings` | User-facing graphics configuration. It expresses intent, which the resolver then checks against the device. |
| `QualityPreset` | The presets `low`, `medium`, `high` and `ultra`. `GraphicsSettings.apply(_:)` applies one. |
| `DeviceCapabilities` | GPU and OS capabilities relevant to feature selection. `baseline` has no optional features. |
| `GraphicsFeatureResolver` | Resolves `GraphicsSettings` against `DeviceCapabilities`. |
| `ResolvedGraphics` | The device-valid configuration that the renderer consumes, with its fallbacks. |
| `GraphicsFallback` | A requested feature that changed during resolution, with the reason. |
| `EventBus` | Synchronous, type-keyed publish and subscribe bus. |
| `Handle`, `HandlePool` | Generation-checked handles into dense storage, so stale handles fail safely. |
| `JSONValue` | Dynamically typed JSON value, for open-schema payloads. |
| `AssetID` | Stable identifier of an asset, stored in its `.meta` sidecar. |
| `Log`, `LogLevel`, `LogRecord`, `LogSink` | Process-wide structured logger, its levels, records and the sink protocol. |
| `ConsoleLogSink`, `RingBufferLogSink` | Writes to standard error, or keeps recent records in memory. |
| `Profiler`, `MemoryTracker` | Frame profiler with CPU and GPU scopes, and tracking of engine-owned allocations. |
| `FrameClock`, `FixedTimestep`, `FrameTime` | Frame timing, a fixed-step accumulator and per-frame timing information. |
| `BackgroundWorker`, `MainThreadDispatcher`, `Jobs` | Serial background work, delivery to the main thread, and data-parallel helpers. |
| `SafePath` | Validates paths from untrusted data so they cannot leave an allowed root. See [26-Security.md](26-Security.md). |
| `DecodeLimits` | Bounds applied when decoding untrusted binary or JSON data. |
| `PathError` | Errors raised by `SafePath`. |
| `FeroxVersion` | The engine version, kept in step with `CHANGELOG.md`. |

## 3. FeroxScene

The entity-component-system, the scene manager and serialisation. Platform-independent. Source: `Sources/FeroxScene`.

| Type | Description |
| --- | --- |
| `World` | Container of entities and their components. The engine owns it, and only one thread may mutate it at a time. |
| `Entity` | Lightweight identifier: an index into the world, plus a generation that changes when the slot is reused. |
| `Component` | Protocol for components, which should be value types holding plain data. |
| `ComponentStorage` | Sparse-set storage for one component type. |
| `System`, `SystemScheduler`, `SystemPhase`, `SystemContext` | A unit of behaviour, the scheduler that runs systems by phase, the phases, and the context each system receives. |
| `TransformSystem` | Computes `WorldTransform` for every entity that has a `Transform`. |
| `Transform`, `WorldTransform` | Local transform relative to the parent, and the world-space matrix with last frame's value. |
| `Name`, `Tags`, `Layer`, `LayerMask`, `Groups` | Core components for naming, tagging and filtering entities. |
| `Parent`, `Children`, `Disabled` | Hierarchy links and the flag that disables an entity's subtree. |
| `PersistentID`, `SceneMember`, `PersistAcrossScenes` | Identity across saves, and scene membership. |
| `Camera` | A camera. The active camera is the enabled one with the highest `priority`. |
| `Light` | A punctual light: directional, point or spot. |
| `MeshRenderer`, `SkinnedMeshRenderer` | Renders a mesh asset, with one material per submesh, or a skinned mesh bound to joint entities. |
| `LODGroup` | Level-of-detail selection by projected screen height. |
| `SpriteRenderer`, `ShapeRenderer`, `Tilemap` | 2D rendering: a textured quad, an untextured shape, and a grid of tiles. |
| `Environment` | Scene environment: sky, image-based lighting and ambient settings. |
| `ReflectionProbe` | Captures surrounding radiance into a prefiltered cubemap for local reflections. |
| `Prefab`, `PrefabInstance` | A reusable entity template, and the marker on an instantiated prefab. |
| `SceneManager` | Loads and unloads scenes into one shared world. |
| `SceneDocument` | On-disk representation of a scene or prefab, in JSON. |
| `SceneSerializer` | Converts between a world and a `SceneDocument`. |
| `ComponentRegistry` | Registry of serialisable component types, by stable name. |
| `SceneError` | Errors raised while loading or validating scene documents. |

## 4. FeroxPhysics

Rigid-body physics for 2D and 3D, and the ECS bridge. Platform-independent. Source: `Sources/FeroxPhysics`. The design is in [13-Physics.md](13-Physics.md).

| Type | Description |
| --- | --- |
| `PhysicsWorld2D` | A 2D rigid-body world on the XY plane. |
| `PhysicsWorld3D` | A 3D rigid-body world, with the same solver design as the 2D world. |
| `SolverSettings` | Solver configuration shared by the 2D and 3D worlds. |
| `BodyDesc2D`, `Body2D`, `BodyDesc3D`, `Body3D` | Construction parameters for a body, and the simulation state of a body. |
| `Shape2D`, `ShapeGeometry2D` | A 2D collision shape, and its geometry. |
| `Shape3D`, `ShapeGeometry3D` | A 3D collision shape with a local offset, and its geometry. |
| `TriangleMesh` | Static triangle mesh collider with a bounding-volume hierarchy. |
| `PhysicsMaterial` | Surface properties combined per contact: friction and restitution. |
| `CollisionFilter` | Category, mask and group filtering. |
| `ContactEvent` | Begin or end of a touching contact or trigger overlap. |
| `JointDesc2D`, `JointDesc3D` | Joint definitions. |
| `RaycastHit2D`, `RaycastHit3D` | Results of a raycast. |
| `RigidBody2D`, `Collider2D`, `Joint2D` | ECS components for a 2D body, its colliders and a joint. |
| `RigidBody3D`, `Collider3D`, `Joint3D` | ECS components for a 3D body, its colliders and a joint. |
| `PhysicsSystem2D`, `PhysicsSystem3D` | The ECS bridge: creates bodies, steps the world and writes poses back. |
| `CharacterController3D` | Kinematic capsule controller that slides along surfaces and steps. |
| `CollisionEvent2D`, `CollisionEvent3D` | Collision and trigger events, published on the engine's `EventBus`. |

## 5. FeroxAnimation

Animation, tweening, timelines and particles. Platform-independent. Source: `Sources/FeroxAnimation`.

| Type | Description |
| --- | --- |
| `AnimationSystem` | Evaluates `Animator` components and writes results to joints, child transforms, materials and sprites. |
| `AnimationLibrary` | Registry of clips and skeletons available to the animation system. |
| `Animator`, `AnimatorController` | A playing animator, and its state-machine definition. |
| `AnimatorState`, `AnimatorTransition`, `AnimatorParameter`, `TransitionCondition` | The parts of a state machine: states, transitions, parameters and conditions. |
| `SkeletonBinding` | Maps skeleton joints to entities. |
| `AnimationClip`, `AnimationChannel`, `AnimationEvent` | A reusable animation asset, one animated property, and a named event at a point in time. |
| `Skeleton`, `Pose` | Joint hierarchy with inverse bind matrices, and local joint transforms. |
| `AnimationCurve`, `Easing`, `Interpolatable` | Keyframed curve, standard easing functions, and the protocol for interpolated values. |
| `Tween`, `TweenSystem` | Simple property animation, and the system that runs tweens. |
| `Timeline`, `TimelineSystem` | Sequenced tracks for cutscenes and scripted moments. |
| `ParticleEmitter` | Serialisable particle emitter configuration. |
| `ParticleSystem`, `ParticlePool` | CPU particle simulation, and its structure-of-arrays storage. |
| `TrailRenderer`, `TrailSystem` | Ribbon trail behind a moving entity, and the system that updates it. |

## 6. FeroxInput

Input state, action maps and rebinding. The macOS backend is Apple-only. Source: `Sources/FeroxInput`. See [14-Input.md](14-Input.md).

| Type | Description |
| --- | --- |
| `InputSystem` | The engine's input hub. It owns the raw input state, evaluates action maps through a context stack, and supports rebinding, recording and haptics. |
| `InputAction`, `ActionMap`, `ActionValue`, `ActionKind` | A named, rebindable action, a set of actions enabled together, and an action's value for the frame. |
| `InputBinding` | A physical control that an action can be bound to. |
| `InputState` | Polled per-frame input state, rebuilt from events at the start of each frame. |
| `InputEvent` | Raw input event from a platform backend or from playback. |
| `Key`, `MouseButton`, `GamepadButton`, `GamepadAxis` | Platform-independent identifiers for controls. |
| `GamepadState`, `DeadZone` | State of one gamepad, and response shaping for analogue inputs. |
| `InputRecorder`, `InputPlayback` | Records input per frame, and replays a recording in place of live input. |
| `HapticsProvider` | Protocol for rumble and haptics backends. |
| `MacInputBackend` **(macOS)** | Translates AppKit events and polls controllers through GameController. |

## 7. FeroxAssets

Asset loading, the project database and the importers. Source: `Sources/FeroxAssets`. See [18-Assets.md](18-Assets.md) and [26-Security.md](26-Security.md) for the limits.

| Type | Description |
| --- | --- |
| `AssetManager` | Runtime loader and cache. Loads run in the background, and completions are delivered on the main thread in `update()`. |
| `AssetHandle`, `AssetState` | Reference-counted handle to a loaded asset, and its loading state. |
| `AssetDatabase` | Project database. It finds source files, maintains `.meta` sidecars with stable ids, and tracks dependencies. |
| `AssetMeta`, `ImportSettings` | Sidecar metadata with the stable `AssetID`, and the import settings it holds. |
| `AssetKind`, `AssetError` | The kinds of asset, and the errors raised by importers and loaders. |
| `GLTFImporter` | glTF 2.0 importer for `.gltf` files with external or data-URI buffers, and for `.glb`. |
| `ImageDecoder`, `ImageData`, `PixelFormat` | Image decoding, the decoded image, and its pixel format. ImageIO on Apple platforms, Netpbm everywhere. |
| `MeshData`, `MaterialData`, `ModelData` | Imported mesh, PBR material and scene graph. |
| `ModelInstantiator` | Creates entity hierarchies from loaded models. |
| `TiledImporter` | Imports Tiled JSON maps into a `Tilemap` component (see `FeroxScene`). |
| `SpriteAtlas` | Texture atlas with named frames. |
| `BuiltinAssets` | Built-in asset identifiers that need no project files. |

## 8. FeroxNet

Networking: packets, messages, server and client, replication and transports. Source: `Sources/FeroxNet`. The model and its limits are in [23-Networking.md](23-Networking.md) and [section 7 of 28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md#7-networking).

| Type | Description |
| --- | --- |
| `NetServer` | Authoritative server over any `NetTransport`. Its handshake is described in its doc comment. |
| `NetClient` | Client that connects to a `NetServer`. |
| `NetConfig` | Shared configuration: protocol id and version, client limits and rate limits. |
| `NetEvent`, `ClientEvent`, `ClientID` | Events raised by the server and the client, and the id of a connected client. |
| `NetConnection`, `NetStats` | One side of a connection, with sequencing, acknowledgements and reliability; and its statistics. |
| `NetChannel` | Delivery guarantee per message: unreliable, unreliable-sequenced or reliable-ordered. |
| `NetMessage`, `NetMessageRegistry` | The protocol for typed messages, and the registry that decodes them by id. |
| `NetWriter`, `NetReader` | Little-endian codec with bounds-checked reads and capped lengths. |
| `NetDecodeError` | Errors raised while decoding untrusted network data. |
| `NetEndpoint`, `NetTransport` | An address, and the datagram transport protocol. |
| `LoopbackTransport`, `LoopbackNetwork`, `NetworkConditioner` | An in-process transport for tests, the network that connects such transports, and simulated latency and loss. |
| `UDPTransport` **(macOS)** | UDP transport over Network.framework, with optional DTLS. |
| `ObjectState`, `SnapshotMessage`, `SpawnMessage`, `InputMessage`, `TextMessage` | Replication messages: object transforms, a per-tick snapshot, spawns and despawns, client input and text. |
| `SnapshotInterpolator` | Client-side interpolation between snapshots, rendering remote objects slightly in the past. |

## 9. FeroxAudio

Audio model and backends. Source: `Sources/FeroxAudio`. See [16-Audio.md](16-Audio.md).

| Type | Description |
| --- | --- |
| `AudioBackend` | Protocol for the audio engine that the rest of Ferox uses. |
| `AVAudioBackend` **(macOS)** | AVAudioEngine implementation, with spatialisation and mixer buses. |
| `SilentAudioBackend` | No-op backend for headless runs and tests. It tracks state so that logic can still be tested. |
| `AudioBus`, `BusSettings` | Fixed mixer buses routed into the master bus, and each bus's volume, mute and attenuation. |
| `PlaybackOptions` | Parameters for starting a sound. |
| `VoiceHandle` | Handle to a playing voice. It becomes invalid when the voice finishes or is stolen. |
| `Attenuation`, `AttenuationModel` | Distance attenuation for positional audio. |
| `VoiceAllocator` | Chooses which voice to steal when all voices are busy. |
| `Decibels` | Conversions between decibels and linear gain. |

## 10. FeroxUI

The in-game UI tree, controls, text and layout. The Core Text provider is Apple-only. Source: `Sources/FeroxUI`. See [15-User-Interface.md](15-User-Interface.md).

| Type | Description |
| --- | --- |
| `UIContext` | Root of the in-game UI. It owns the element tree, performs layout, routes input, manages focus and produces a draw list. |
| `UIElement` | Base class of the UI tree. Elements are reference types, distinct from ECS entities and sprites. |
| `UIStack` | Lays out children along an axis, with spacing, fill weights and cross-axis alignment. |
| `UILabel` | Text label with optional rich-text markup and wrapping. |
| `UIImage` | Image from a texture asset, or a region of an atlas. |
| `UIButton` | Push button with hover, pressed, focus and disabled states. |
| `UIToggle` | Checkbox-style toggle. |
| `UISlider` | Horizontal slider. |
| `UITextField` | Single-line editable text field with caret, placeholder and selection-free editing. |
| `UIScrollView` | Vertically scrolling container. |
| `UIListView` | Virtualised list that instantiates only the rows in view, with fixed row heights. |
| `UIDropdown` | Drop-down selector that opens a popup list. |
| `Anchors`, `SizeSpec`, `UIAlignment` | Unity-style anchors, sizing along one axis, and cross-axis alignment. |
| `UIEvent`, `UIModifiers`, `FeroxInputKey` | Pointer and keyboard events delivered to elements, their modifiers and the keys relevant to the UI. |
| `UIDrawList`, `GlyphQuad`, `UITheme` | Backend-agnostic draw commands, a positioned glyph, and the shared visual theme. |
| `UIFontProvider` | Protocol for text layout into glyph quads. |
| `MonospaceFontProvider` | Deterministic fixed-advance font metrics, for tests and headless use. |
| `CoreTextFontProvider`, `GlyphAtlasPage` **(macOS)** | Core Text layout and glyph rasterisation, and its coverage atlas page. |
| `RichText`, `TextRun`, `TextAlignment` | Minimal markup parser for `<b>`, `<i>`, `<color>` and `<size>`, and its runs and alignment. |
| `UIAnimator`, `UIEasing` | Transitions for UI values, and the easing used for them. |
| `UIClipboard` | Clipboard bridge provided by the platform host. |

## 11. FeroxRender

The renderer. Only the CPU-side types are available everywhere. The Metal renderer is Apple-only. Source: `Sources/FeroxRender`. See [07-Rendering-2D.md](07-Rendering-2D.md) and [08-Rendering-3D.md](08-Rendering-3D.md).

| Type | Description |
| --- | --- |
| `Renderer` **(macOS)** | The Metal renderer. It turns a `World` into a frame, in three command buffers. |
| `RenderDevice` **(macOS)** | The Metal device, its command queue and its probed capabilities. |
| `CapabilityProbe` **(macOS)** | Fills `DeviceCapabilities` from `MTLDevice` queries. |
| `ShaderLibrary` **(macOS)** | Compiles the Metal Shading Language sources at run time, caches pipelines, and hot-reloads them. |
| `RenderOutput`, `RenderFrameStatistics` **(macOS)** | Where a frame is drawn, and measurements of the last completed frame. |
| `RenderHookStage`, `RenderHookContext`, `RenderHookToken` **(macOS)** | Points at which game code can insert GPU work, what a hook may use, and the handle that removes a hook. |
| `RenderError` **(macOS)** | Errors raised while creating GPU objects. |
| `RenderSceneExtractor`, `RenderCamera`, `RenderFrameData` | Extracts the world into the data the 3D passes need, the camera it uses, and the frame's data. |
| `DrawBatch`, `SunLight`, `RenderProbe`, `RayTracingInstance` | The batches, directional light, probes and ray-tracing instances that are extracted for a frame. |
| `SpriteBatcher`, `SpriteFrameData` | Builds the 2D frame data from the world. It is not thread-safe. |
| `UIBatcher`, `UIFrameData` | Converts a `UIDrawList` into vertices and draw batches. |
| `Tessellator` | CPU tessellation of 2D shapes into indexed triangles. |
| `DebugDraw` | Immediate-mode debug lines, drawn on top of the scene. |
| `DynamicResolutionController` | Chooses the render scale from measured GPU frame times. |
| `PostUniformsBuilder`, `RenderDebugView` | Translates post-processing settings into shader constants, and the full-screen debug views. |
| `FrameUniformsBuilder` | Builds the camera- and environment-dependent constants for a frame. |
| `RenderMath` | Pure rendering maths, shared by the Metal backend and the unit tests. |

## 12. Ferox (umbrella)

The runtime that ties the modules together. Source: `Sources/Ferox`. It re-exports every engine module, so `import Ferox` is enough for gameplay code. See [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md).

| Type | Description |
| --- | --- |
| `Engine` | The runtime. It owns the world, the subsystems and the frame loop. It does not depend on Metal or AppKit. |
| `EngineConfiguration` | Everything needed to start an engine, as plain data. |
| `EngineError` | Errors raised when the engine starts, such as a missing asset folder or an unavailable renderer. |
| `Game` | Protocol for game code. Every hook has an empty default, and the hooks run on the main thread. |
| `GameLauncher` | Command-line entry point with `--headless`, `--frames` and `--dt`. |
| `EditorSession` | Platform-independent core of the editor: selection, play mode, undo and redo, and scene files. |
| `GameHost` **(macOS)** | Runs a `Game` in a macOS window, with a Metal view and the renderer. |
| `GameView` **(macOS)** | The Metal view that forwards keyboard, mouse and gesture events to the input backend. |

## 13. Related documents

- [03-Architecture.md](03-Architecture.md): the module graph that this index follows.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): the entity model in more depth.
- [20-Gameplay-API.md](20-Gameplay-API.md): writing game code against these types.
- [22-Editor.md](22-Editor.md): the editor built on `EditorSession`.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): the graphics types in detail.
- [25-Platform-Support.md](25-Platform-Support.md): which types exist on which platforms.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md): limitations that affect the types listed here.
