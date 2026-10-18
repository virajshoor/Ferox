# Limitations and Roadmap

This document lists what Ferox does not do yet, or does only partly, and what the project may do next. The limitations come from the source's doc comments and from the review that produced these documents. Each one is stated as a fact about the current code. The roadmap in [section 8](#8-roadmap-plans-not-commitments) is a set of plans. It is not a list of commitments, and it has no dates.

The most important limitation is the first one: nothing in Ferox has been verified on Apple hardware yet.

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

- **Limitation: no hardware verification yet.** No macOS or Swift toolchain was available while these documents were written. The Metal renderer, the macOS CI job and every rendering result have not been checked on a Mac. The Linux job covers only the portable modules, as [25-Platform-Support.md](25-Platform-Support.md) describes.
- **Limitation: MetalFX upscaling is unverified on hardware.** Its code paths and the fallbacks in [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md) follow the resolver's rules. How they behave on a real device is not known.
- No benchmark numbers, frame rates or timings are quoted anywhere in these documents, because none have been measured. The method is in [21-Performance.md](21-Performance.md).

## 2. Rendering

- **Limitation: single active camera.** The renderer picks one camera for each frame: the enabled camera with the highest `priority`, and the lowest entity index on a tie. The source calls it the active camera.
- **Limitation: Camera viewport and renderTarget are ignored.** The renderer's doc comment says that `Camera.viewport` and `Camera.renderTarget` "are not yet honoured". `viewport` is meant for split-screen and picture-in-picture. A camera that sets `renderTarget` is skipped when the main camera is chosen.
- **Limitation: the sky is drawn only for perspective cameras.** For an orthographic camera the background is the clear colour (`Renderer`'s doc comment).
- **Limitation: changing `maxFramesInFlight` needs the renderer recreated.** The renderer logs a warning when the value changes at run time. See [section 7 of 24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md#7-changing-settings-at-run-time).
- **Limitation: the monospace font provider renders white boxes.** `MonospaceFontProvider` emits glyph quads with placeholder texture coordinates, so the glyphs do not show. The engine uses it only where CoreText is unavailable. On macOS, the engine uses `CoreTextFontProvider` instead.
- **Limitation: reflection probes are fixed at 128 px and at most 16.** Each probe face is 128 × 128, whatever `ReflectionProbe.resolution` says. At most 16 probes are captured, and extra probes are ignored with a warning. Where probes overlap, the innermost one wins, and nothing is blended.
- **Limitation: Hi-Z occlusion can pop for one frame.** Occlusion culling uses a Hi-Z pyramid built from the previous frame's depth, so objects can pop in or out for one frame.
- **Limitation: indirect draw counters are an upper bound.** The counts are known only on the GPU after culling. The CPU counters report the upper bound.
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

- **Limitation: the editor has no viewport picking.** Entities are selected from the hierarchy panel. Clicking an object in the viewport does not select it. The viewport camera orbits, zooms and pans, as the `FeroxEditor` doc comment describes. The editor's own guide is [22-Editor.md](22-Editor.md).

## 7. Networking

- **Limitation: networking is limited in scope.** The points below come from the doc comments in `Sources/FeroxNet`.
  - **Plain UDP is unencrypted and unauthenticated.** `UDPTransport` can wrap traffic in DTLS when `dtls: true` is passed. That option is off by default. The transport's doc comment says that game-level validation is still needed when DTLS is on.
  - **The handshake is not authentication.** It deters spoofed and flooded connection requests, and nothing more. See [section 6 of 26-Security.md](26-Security.md#6-networking).
  - **Message and packet sizes are fixed.** A message payload is limited to 1024 bytes, a packet payload to 1150 bytes, and a UDP datagram to 1400 bytes. Larger data has to be split by the game.
  - **Snapshots carry at most 128 objects.** `SnapshotMessage.maxObjects` is 128.
  - **A server holds at most 16 clients by default.** `NetConfig.maxClients` is 16.
  - **Client input is untrusted.** The server should validate each `InputMessage` before using it, for example by clamping movement vectors.
  - **Interpolation is client-side and bounded.** `SnapshotInterpolator` renders remote objects 0.1 seconds in the past by default. It extrapolates for at most 0.25 seconds when snapshots run out.
  - **No NAT traversal, relay or matchmaking.** The networking module contains none of these. A game that needs them has to supply them.
  - **The loopback transport is for tests.** `LoopbackTransport` connects endpoints in one process, with time supplied by the caller, and is used to test networking code deterministically.

## 8. Roadmap (plans, not commitments)

The items below are plans. They are based on gaps that the source records or that this review found. They are not commitments, they have no dates, and they may change or be dropped.

- **Verify on hardware.** Build the package, run the tests, and run `FeroxDiag --render` on named Apple Silicon Macs. Record the Mac model, chip, macOS version and commit, as [CONTRIBUTING.md](../CONTRIBUTING.md) asks, and then update [25-Platform-Support.md](25-Platform-Support.md) and this document.
- **Verify MetalFX.** Check the spatial and temporal MetalFX paths on devices that support them and on devices that do not, and confirm each fallback.
- **Camera viewports and render targets.** Honour `Camera.viewport` and render to `renderTarget`, and support more than one camera in a frame. This would enable split-screen and picture-in-picture.
- **Sky for other projections.** Draw the sky for orthographic cameras, or document the clear-colour behaviour as the intended design.
- **Reflection probes.** Honour `ReflectionProbe.resolution`, support blending between overlapping probes, and review the limit of 16 probes.
- **GPU particles.** Support colour over lifetime on the GPU path, and let local-space emitters follow the emitter.
- **Editor viewport picking.** Select entities by clicking them in the viewport.
- **More glTF features.** The importer's header lists what it rejects or skips: sparse accessors, morph target rendering (weights are imported only as animation channels), non-triangle primitives, Draco and meshopt compression, and `KHR_texture_transform`. Any of these could be supported in a later version.
- **Stronger transport security.** Make DTLS a documented option for real deployments, and consider authenticated messages on top of the handshake.
- **Correct stale references.** Some source comments refer to documents that are not in this repository: `Docs/07-3D-Rendering.md` in `ReflectionProbes.swift`, `Docs/08-Ray-Tracing.md` in `RayTracingContext.swift`, `Docs/11-Anti-Aliasing.md` and `Docs/12-MetalFX-Upscaling.md` in `Capabilities.swift`, and `Docs/26-Networking.md` in `Transport.swift`. The matching documents here are [08-Rendering-3D.md](08-Rendering-3D.md), [11-Ray-Tracing.md](11-Ray-Tracing.md), [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md), [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md) and [23-Networking.md](23-Networking.md).
- **Physics.** The gaps in [13-Physics.md](13-Physics.md), section 14, include continuous collision detection and 3D convex hulls. Those are candidates for later work as well.

## 9. Related documents

- [01-Overview.md](01-Overview.md): what Ferox is and what it aims to do.
- [21-Performance.md](21-Performance.md): how to measure, which is what the verification items need.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): the settings and fallbacks behind several of these limitations.
- [25-Platform-Support.md](25-Platform-Support.md): what is and is not verified on each platform.
- [26-Security.md](26-Security.md): the security limits of the networking and asset code.
- [27-Troubleshooting.md](27-Troubleshooting.md): what to do when one of these limitations causes a problem.
- [29-API-Reference.md](29-API-Reference.md): the public types that these limitations affect.
