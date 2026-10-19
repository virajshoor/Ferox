# Limitations and Roadmap

This document lists what Ferox does not do yet, or does only partly, and what the project may do next. The limitations come from the source's doc comments and from the review that produced these documents. Each one is stated as a fact about the current code. The roadmap in [section 8](#8-roadmap-plans-not-commitments) is a set of plans. It is not a list of commitments, and it has no dates.

The most important limitation is the first one: Ferox has been verified on one Apple Silicon Mac only.

## Contents

1. [Verification status](#1-verification-status)
2. [Rendering](#2-rendering)
3. [Lighting, post-processing and tone mapping](#3-lighting-post-processing-and-tone-mapping)
4. [Particles](#4-particles)
5. [Ray tracing](#5-ray-tracing)
6. [Editor](#6-editor)
7. [Networking](#7-networking)
8. [Roadmap (plans, not commitments)](#8-roadmap-plans-not-commitments)
9. [Related documents](#9-related-documents)

## 1. Verification status

- **Limitation: one machine verified for a drawn frame.** The package has been built on an M1 Max running macOS 27 with Swift 6.4. That run's suite was 504 XCTest tests, the Metal renderer drew an offscreen frame, and the HelloFerox, Platformer2D and Showcase3D examples ran. The current portable suite is 542 XCTest tests on Swift 6.2.3 (Linux). The macOS CI job compiles shaders and can construct a `Renderer` when the runner has a GPU. That does not replace a frame capture on Apple Silicon. No Intel Macs or iOS devices have been tested. See [25-Platform-Support.md](25-Platform-Support.md).
- **Limitation: MetalFX upscaling is probed, not frame-captured.** At init the renderer asks `MTLFXTemporalScalerDescriptor` for a scaler with the prepass depth format (`depth32Float_stencil8`) at 16×16 → 32×32 and stores the result on `Renderer.metalFXProbe`. A nil scaler falls back to Ferox's temporal resolve. Motion scale and jitter conversion live in `MetalFXTemporalMapping` and are unit-tested. No temporal frame has been captured on hardware in this change.
- No benchmark numbers, frame rates or timings are quoted anywhere in these documents, because none have been measured. The method is in [21-Performance.md](21-Performance.md).

## 2. Rendering

- **Limitation: one screen camera.** The drawable shows one camera: the enabled camera with the highest `priority` and no `renderTarget`, and the lowest entity index on a tie. Other active cameras that set `renderTarget` are drawn into textures (`Renderer.renderedCameraTarget`) at `Camera.targetSize`, or at the screen size when that is nil. Each distinct size has its own G-buffer. Those textures are not a second presented view, so split-screen of two drawables is still one renderer per view.
- **Limitation: the sky is drawn only for perspective cameras.** For an orthographic camera the background is the clear colour (`Renderer`'s doc comment).
- **Limitation: changing `maxFramesInFlight` needs the renderer recreated.** The renderer logs a warning when the value changes at run time. See [section 7 of 24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md#7-changing-settings-at-run-time).
- **Limitation: the monospace font provider renders white boxes.** `MonospaceFontProvider` emits glyph quads with placeholder texture coordinates, so the glyphs do not show. The engine uses it only where CoreText is unavailable. On macOS, the engine uses `CoreTextFontProvider` instead.
- **Limitation: reflection probes share one face size and are capped at 16.** All probes share one cube array, so the face size is the largest `ReflectionProbe.resolution` among the probes, rounded up to a power of two and clamped to 32–256 px. A change of size re-captures every probe. At most 16 probes are captured, and extra probes are ignored with a warning. Where probes overlap, the innermost one wins, and nothing is blended.
- **Limitation: Hi-Z occlusion can pop for one frame.** Occlusion culling uses a Hi-Z pyramid built from the previous frame's depth, so objects can pop in or out for one frame.
- **Limitation: local shadows are budgeted.** Point and spot lights with `castsShadows` get shadow maps, nearest to the camera first, until `ShadowSettings.localShadowSlices` runs out (a spot light takes one slice, a point light six). Lights beyond the budget are lit without shadows. PCSS applies to the sun only; local shadows use hard or PCF filtering.
- **Limitation: the mesh memory budget is split.** `MemoryBudget.meshBytes` evicts unreferenced cached models. Meshes registered in memory (built-ins, procedural meshes and model sub-meshes) are counted and warned about, and the asset manager does not remove them. The GPU mesh cache evicts by idle time and then by real buffer bytes against the same budget, keeping anything drawn this frame. Textures are evicted under `textureBytes`, and audio clips that would exceed `audioBytes` are streamed from disk instead of decoded.
- **Limitation: indirect draw counters are an upper bound.** The counts are known only on the GPU after culling. The CPU counters report the upper bound.
- **Limitation: indirect command buffers do not carry GPU-culled draws.** `MTLIndirectRenderCommand` on the macOS 15 SDK draws with a CPU-side index count. Batches whose counts were written by the culling kernels stay on the immediate indirect-draw path. The command buffer is used when GPU culling is off for that pass, the device is Metal 3, argument buffers were built, and the pass has one cull mode.
- **Limitation: skinned motion vectors use the current pose.** Motion vectors for skinned meshes are taken from the current pose.

## 3. Lighting, post-processing and tone mapping

- **Limitation: auto exposure is relative to the camera EV.** The camera's `exposureEV100` is the exposure used when auto exposure is off. With auto exposure on, the adapted exposure is relative to the camera's EV. The code reviewed does not document how the two combine in detail.
- **Limitation: 2D scenes should use `toneMapper` `.none`.** The default tone mapper is `.agx`. For 2D scenes, set `post.toneMapper` to `.none`.

## 4. Particles

- **Limitation: GPU particle colour is constant over lifetime.** The GPU path evaluates the colour-over-lifetime curve at time 0 and uses that colour for the whole life of the particle. Size over lifetime is handled.
- **Limitation: local-space GPU particles don't follow the emitter.** Their positions are converted to world space when they spawn. After that they stay where they were created, even if the emitter moves.

The CPU simulation, `ParticleSystem`, is described in [17-Animation-and-Particles.md](17-Animation-and-Particles.md).

## 5. Ray tracing

- **Limitation: ray tracing is opaque-only and excludes skinned meshes.** Ray-tracing geometry is built as opaque. Skinned meshes are left out, because their bind pose would be wrong in the acceleration structure. Hit shading uses constant per-instance materials.

See [11-Ray-Tracing.md](11-Ray-Tracing.md) for the budget rules, and [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md) for how the resolver reduces the budget on devices without ray-tracing hardware.

## 6. Editor

- **Limitation: picking is CPU-side.** Left-clicking in the viewport selects the nearest entity. A mesh with indices is tested with a front-face triangle raycast (`MeshRaycast`); a mesh without indices uses its world bounds. Lights and cameras without a mesh use a 0.3-unit marker sphere. `prepassPickFragment` can write an instance id into an `r32Uint` attachment, and `InstancePickMap` turns that id into an entity, but the editor does not read a GPU attachment back. The editor's own guide is [22-Editor.md](22-Editor.md).

## 7. Networking

- **Limitation: networking is limited in scope.** The points below come from the doc comments in `Sources/FeroxNet`.
  - **Plain UDP is unencrypted and unauthenticated.** `UDPTransport` can wrap traffic in DTLS-PSK when `security: .preSharedKey(identity:passphrase:)` is passed. That option is off by default, and the handshake has not been tested on hardware. Game-level validation is still needed when DTLS is on.
  - **The handshake is not authentication.** It deters spoofed and flooded connection requests, and nothing more. See [section 6 of 26-Security.md](26-Security.md#6-networking).
  - **Message and packet sizes are fixed.** A message payload is limited to 1024 bytes, a packet payload to 1150 bytes, and a UDP datagram to 1400 bytes. Larger data has to be split by the game.
  - **Snapshots carry at most 22 objects each.** `SnapshotMessage.maxObjects` is 22, so a full snapshot fits the 1024-byte message limit. `SnapshotMessage.split` divides larger sets across messages; there is no delta compression.
  - **A server holds at most 16 clients by default.** `NetConfig.maxClients` is 16.
  - **Client input is untrusted.** The server should validate each `InputMessage` before using it, for example by clamping movement vectors.
  - **Interpolation is client-side and bounded.** `SnapshotInterpolator` renders remote objects 0.1 seconds in the past by default. It extrapolates for at most 0.25 seconds when snapshots run out.
  - **No NAT traversal, relay or matchmaking.** The networking module contains none of these. A game that needs them has to supply them.
  - **The loopback transport is for tests.** `LoopbackTransport` connects endpoints in one process, with time supplied by the caller, and is used to test networking code deterministically.

## 8. Roadmap (plans, not commitments)

The items below are plans. They are based on gaps that the source records or that this review found. They are not commitments, they have no dates, and they may change or be dropped.

- **Verify on more hardware.** The package has been built, tested and rendered on one M1 Max. Repeat the build, the tests and `FeroxDiag --render` on other named Apple Silicon Macs and on other GPUs. Record the Mac model, chip, macOS version and commit, as [CONTRIBUTING.md](../CONTRIBUTING.md) asks, and then update [25-Platform-Support.md](25-Platform-Support.md) and this document.
- **Verify MetalFX on a captured frame.** The probe records whether a temporal scaler can be created for the prepass depth format. A captured frame on hardware that supports MetalFX, and on hardware that does not, is still needed.
- **Two presented views.** Render-target cameras draw at their own resolution into their own G-buffer. Presenting two viewports in one drawable is not done.
- **Sky for other projections.** Draw the sky for orthographic cameras, or document the clear-colour behaviour as the intended design.
- **Reflection probes.** Support per-probe face sizes, blending between overlapping probes, and review the limit of 16 probes.
- **GPU particles.** Support colour over lifetime on the GPU path, and let local-space emitters follow the emitter.
- **More glTF features.** The importer's header lists what it rejects or skips: sparse accessors, morph target rendering (weights are imported only as animation channels), non-triangle primitives, Draco and meshopt compression, and `KHR_texture_transform`. Any of these could be supported in a later version.
- **Stronger transport security.** Verify the DTLS-PSK handshake on hardware, and consider per-player credentials so that one leaked passphrase does not expose every session.
- **Physics.** Convex hulls, edge-edge axes, hull-versus-mesh manifolds, and dynamic-versus-dynamic sweeps are in. The remaining gap in [13-Physics.md](13-Physics.md), section 14, is a less conservative core sweep.

## 9. Related documents

- [01-Overview.md](01-Overview.md): what Ferox is and what it aims to do.
- [21-Performance.md](21-Performance.md): how to measure, which is what the verification items need.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): the settings and fallbacks behind several of these limitations.
- [25-Platform-Support.md](25-Platform-Support.md): what is and is not verified on each platform.
- [26-Security.md](26-Security.md): the security limits of the networking and asset code.
- [27-Troubleshooting.md](27-Troubleshooting.md): what to do when one of these limitations causes a problem.
- [29-API-Reference.md](29-API-Reference.md): the public types that these limitations affect.
