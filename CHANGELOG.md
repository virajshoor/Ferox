# Changelog

All notable changes to Swift Engine Ferox (Ferox) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Render-target cameras. An active camera with `Camera.renderTarget` set is drawn into a texture (`Renderer.renderedCameraTarget`). The screen camera is still the highest-priority camera with no render target. GPU culling and shadows are off for the offscreen views, and they share the screen view's pixel size.
- Tier-2 material argument buffers (`MaterialRecord` in `Common.metal`, `BufferIndex.materialTable` / `materialIds`) and Metal 3 indirect command buffers for opaque draws when every material in the pass uses that table and every index count is known on the CPU. GPU-culled batches, tier 1, and mixed double-sided batches stay on immediate draws. Immediate draws skip rebinding an unchanged vertex buffer. `MTLIndirectRenderCommand` on the macOS 15 SDK has no indirect-argument draw.
- Optional shader metallib (`FEROX_METALLIB` or bundled `FeroxShaders.metallib`) when hot reload is off, and mesh-pipeline prewarm into `FeroxPipelines.binaryarchive` under the caches directory. No metallib is committed.
- A private `MTLHeap` for render targets, with `TransientHeapPlan` describing which post textures may alias. MSAA attachments stay stored. Offset aliasing of bloom with ambient occlusion is not applied, because those textures are created in different passes.
- GPU mesh eviction against `MemoryBudget.meshBytes` using real buffer sizes, after idle eviction. A mesh drawn this frame stays. Mesh uploads write straight into the shared buffer on unified memory.
- `Renderer.metalFXProbe`: a temporal MetalFX scaler is requested at init for `depth32Float_stencil8`. A nil scaler is recorded and the frame uses Ferox's resolve. Motion scale and jitter live in `MetalFXTemporalMapping`.
- `prepassPickFragment` writes the instance index. The editor picks with `MeshRaycast` on the CPU. There is no GPU readback.
- 3D convex hulls: `ConvexHull3D`, `Shape3D.convex`, and `ColliderShape3D.Geometry.convex(vertices:)`. Dynamic-versus-dynamic continuous collision scales both bodies in a pair.
- `Website/`: the static site for swengine.net, with a landing page, a 404 page, Open Graph and JSON-LD metadata, a sitemap and a web manifest. Package it with `cd Website && zip -r ../dist.zip . -x README.md`.
- The project's full name, Swift Engine Ferox, now appears in the README, the overview, CONTRIBUTING, SECURITY, NOTICE and `Package.swift`. Code names (package, modules, tools) are unchanged.
- Shadows for point and spot lights with `castsShadows`. They are budgeted by the new `ShadowSettings.localShadowSlices` (default 12; a spot light takes one slice, a point light six) and `localResolution` (default 512), nearest lights first, and planned by `LocalShadowPlanner`.
- `TransportSecurity.preSharedKey(identity:passphrase:)`: DTLS 1.2 with a pre-shared key for `UDPTransport`. Untested on hardware.
- `AudioBackend.stopAll(fadeOut:)`, `memoryBudgetBytes` and `decodedBytes`, and `AudioMemoryPolicy`.
- `castsShadows` and `receivesShadows` on `SkinnedMeshRenderer`.
- Tests for local shadow planning, the shadow-receive flag, probe face sizes, viewports, the audio budget, `stopAll` and transport security.

### Changed

- **Source-breaking for external switches:** `ShapeGeometry3D` and `ColliderShape3D.Geometry` gained `.convex`. A `switch` that was exhaustive must handle the new case. Degenerate point sets make `Shape3D.convex` return nil, and the physics system skips a collider it cannot build.
- `ShaderVariant` gained `materialArguments` (default `false`). Existing call sites keep the discrete texture binds.
- A sprite-only frame with tone mapping, bloom, depth of field, SSAO, TAA, motion blur, ray tracing, stencil masks and debug lines all off draws sprites into the LDR target and skips the HDR scene pass. The default tone mapper is AgX, so this path is off unless those features are off.
- CI pins `swift:5.10` and `swift:6.2` by digest, adds a Swift 6.2 job that lints with `swift format` and runs `swift test --enable-xctest`, treats warnings as errors on the Swift 5.10 job, and moves the Mac job to `macos-15` with a required Xcode 16.4. That job compiles every shader with `Scripts/compile-shaders.sh`.
- Sources and tests are formatted with `swift format` (`.swift-format`).

### Fixed

- The luminance histogram is a shared buffer. `makeBuffer(bytes:)` with private storage returns nil, so renderer init failed on the macOS 15 CI GPU before any frame was encoded.
- **Breaking:** `UDPTransport(listenOn:dtls:)` and `UDPTransport(connectingTo:dtls:)` are replaced by `init(listenOn:security:)` and `init(connectingTo:security:)`. Both throw on an invalid security configuration.
- CPU hot paths fetch component stores once per pass, reuse scratch buffers, gather active physics contacts in one pass, and give 2D drawables and shadowed lights a total sort order. Results are unchanged; no timings have been measured. See [section 10 of Docs/21-Performance.md](Docs/21-Performance.md#10-cpu-hot-paths).

### Fixed

- GPU culling compiles and covers every opaque submesh. `cullInstances` takes the Hi-Z pyramid as `access::read` and writes a visibility flag; `expandVisibleDraws` builds indirect arguments for every batch, including later submeshes. Indirect draws are 32 bytes so each batch offset is 16-byte aligned. If a cull kernel fails to compile, the frame draws the CPU index list. Occlusion-off binds a 1×1 `r32Float` texture.
- `Engine.activeCamera()` is `RenderSceneExtractor.mainCamera`: hierarchy, `renderTarget == nil`, priority, then lowest entity index.
- Discrete-GPU textures are staged into private storage with a blit. Managed fallback textures are synchronized before the GPU reads them.
- Contact keys are `(body, shape)` pairs. Shape 256 no longer aliases shape 0, and tilemaps are not capped at 255 boxes.
- `MeshBudgetTests` declared `weak let`. Swift 5.10 (the Xcode 15.4 toolchain used by macOS CI) rejects that, so the test target failed to compile and the suite never ran. The witness is now a `weak var` assigned on the next line, which also stays warning-free on Swift 6.2+.
- `SafePath` stores its root as a `String`. `URL` is not `Sendable` on the Swift 5.10 Linux SDK, and the floor CI job treats that warning as an error. `root` is still a `URL`. `LoadedScene` and `EngineConfiguration` are `@unchecked Sendable` for the same reason. Their fields are unchanged.
- The Hi-Z fallback texture is filled through a local so `FallbackTextures.init` does not capture `self` before every stored property is set. That was a macOS compile error.
- First build with a real Swift compiler (6.1.3, Linux): fixed compile errors in `SceneManager`, `Collision3D`, `AssetDatabase`, `RenderScene`, the examples and `EngineTests`. All 491 tests pass on Linux.
- `FrameClock.tick(delta:)` dropped the first frame's delta, and rounding error could drop a fixed step. Fixed steps are now frame-rate independent.
- `ShadowSoftness.hard` rendered the same as `.pcf`. It now takes a single comparison.
- The audio memory budget (`MemoryBudget.audioBytes`) was not enforced. A clip that would exceed it is now streamed instead of decoded.
- `Engine.shutdown()` left voices playing until the backend was released. It now stops them all.
- `MeshRenderer.receivesShadows` was ignored. It now turns off sun, local and ray-traced shadows for that object.
- `Camera.viewport` was ignored. The scene is now presented into the viewport rectangle.
- `ReflectionProbe.resolution` was ignored. Probes now share a face size taken from the largest request (32–256 px).

## [0.1.0] - Unreleased

This version has not been released yet.

### Added

- Initial engine foundation:
  - Math library
  - ECS scene system
  - Metal renderer, with 2D sprite batching and 3D PBR forward+ rendering
  - Physics for 2D and 3D
  - Input
  - UI
  - Audio
  - Animation
  - Particles
  - Asset pipeline
  - Hybrid ray tracing
  - Anti-aliasing: MSAA, FXAA, SMAA and TAA
  - MetalFX upscaling
  - Editor
  - Networking foundations
  - Benchmarks (`FeroxBenchmarks`)
- Editor application (`FeroxEditor`) with hierarchy, inspector, Play/Pause/Step/Stop, snapshot undo/redo and scene files.
- Diagnostics tool (`FeroxDiag`) reporting GPU capabilities and resolved graphics presets.
- Examples: `HelloFerox`, `Platformer2D` and `Showcase3D`, all runnable headless.
- Test targets for every module, plus integration tests for the engine, editor and launcher.
- Documentation: README and 29 guides under `Docs/`.

### Fixed

- `RenderMath.groups` returned a wrong dispatch size when the group size was zero or negative.
- `EventBus.flush` could loop without bound when handlers kept queuing events. Each flush now delivers at most `maxEventsPerFlush` events, carries the rest to the next flush, and ignores nested calls.
- Scene files, glTF documents and asset sources were read fully before their size was checked. `DecodeLimits.readFile` now checks the size before reading.
- `SnapshotMessage.maxObjects` was 128, which could never fit the 1024-byte message limit. It is now 22, and `SnapshotMessage.split` divides larger worlds across several messages.
- Benchmark names no longer embed a count that did not match the workload.
- Source comments that pointed at renamed documentation pages.

### Removed

- The unused `DynamicResolutionController` in `FeroxCore`, which clashed with the renderer's type of the same name in `FeroxRender`.

### Known issues

- The code has not yet been compiled or run on Apple hardware. See [Limitations and Roadmap](Docs/28-Limitations-and-Roadmap.md).
