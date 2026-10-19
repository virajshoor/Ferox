# 3D Rendering

The 3D renderer turns a `World` into one frame of Metal work. This document describes the frame flow in `Sources/FeroxRender/Metal/Renderer.swift`, the render paths and their pass order, the render-target formats, reverse-Z depth, materials and LOD, GPU-driven culling with Hi-Z occlusion, render hooks, offscreen rendering, the quality presets, and the statistics the renderer exposes. Lighting and shadows are described in [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md). Post-processing and anti-aliasing are in [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md). The 2D layer, which shares the main pass, is in [07-Rendering-2D.md](07-Rendering-2D.md). Nothing in this document has been run on a GPU. The statements describe the source.

## Contents

1. [Components of the renderer](#1-components-of-the-renderer)
2. [Frame flow](#2-frame-flow)
3. [Render paths](#3-render-paths)
4. [Render targets and formats](#4-render-targets-and-formats)
5. [Reverse-Z depth](#5-reverse-z-depth)
6. [Meshes, materials and LOD](#6-meshes-materials-and-lod)
7. [Culling](#7-culling)
8. [Transparency](#8-transparency)
9. [Render hooks](#9-render-hooks)
10. [Offscreen rendering](#10-offscreen-rendering)
11. [Quality presets](#11-quality-presets)
12. [Statistics and debug views](#12-statistics-and-debug-views)
13. [Validation status](#13-validation-status)
14. [Limitations](#14-limitations)
15. [Related documents](#15-related-documents)

## 1. Components of the renderer

| Type | File | Responsibility |
| --- | --- | --- |
| `Renderer` | `Metal/Renderer.swift` | Public entry point. Frame and command-buffer management, hooks, settings, statistics. |
| `RenderDevice` | `Metal/RenderDevice.swift` | The Metal device and command queue, and the probed `DeviceCapabilities`. Throws `RenderError.noDevice` when there is no device. |
| `ShaderLibrary` | `Metal/ShaderLibrary.swift` | Compiles the Metal modules and the pipeline states. See [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md). |
| `RenderTargets` | `Metal/RenderTargets.swift` | The size-dependent textures of one view. Reallocated only when the configuration changes. |
| `ScenePasses` | `Metal/ScenePasses.swift` | Shadows, compute culling and clustering, the prepass, Hi-Z, and the main pass. |
| `PostProcessor` | `Metal/PostProcessor.swift` | The HDR-to-LDR chain, anti-aliasing, upscaling, presentation. |
| `OverlayPasses` | `Metal/OverlayPasses.swift` | Particles, the 2D layer, debug lines and the UI. |
| `EnvironmentLighting` | `Metal/EnvironmentLighting.swift` | Sky, irradiance, prefiltered specular and the BRDF lookup table. |
| `ReflectionProbes` | `Metal/ReflectionProbes.swift` | Capture and storage of reflection probes. |
| `RayTracingContext` | `Metal/RayTracingContext.swift` | Acceleration structures and ray-traced effects. See [11-Ray-Tracing.md](11-Ray-Tracing.md). |
| `GPUResources.swift` | `Metal/GPUResources.swift` | `FrameAllocator`, `TexturePool`, `MeshCache`, `TextureCache`, `MaterialBinder` and the fallback textures. |
| `RenderSceneExtractor` | `RenderScene.swift` | Converts the world into a `RenderFrameData`: batches, instances, lights, camera. Contains no Metal code. |
| `FrameUniformsBuilder`, `PostSettings`, `RenderMath` | Render module | Pure Swift that builds uniforms and maths, so it can be tested without Metal. |

The split between `RenderSceneExtractor`, which contains no Metal, and the passes, which encode Metal commands, is deliberate. The extractor decides what is visible and in what order. The passes decide how it is drawn.

## 2. Frame flow

`Renderer.render(world:to:time:deltaTime:ui:)` draws one frame. It returns `false` if the frame was skipped. Its documentation describes three command buffers, which are enqueued in this order and therefore execute in this order:

1. **Uploads.** Mipmap generation for textures first used while this frame is encoded.
2. **Scene.** Environment and probe updates, shadows, compute culling and clustering, GPU particles, the prepass, Hi-Z, SSAO or ray-traced effects, and the main HDR pass.
3. **Post.** Temporal anti-aliasing or upscaling, depth of field, motion blur, exposure, bloom, tone mapping, FXAA or SMAA, spatial upscaling, sharpening, and presentation with the UI on top.

Within `encodeFrame`, the steps are:

1. The render size is chosen. Dynamic resolution, if enabled, scales the base size by the scale from the previous frame's GPU time. The render targets are reallocated if the size, MSAA or the history configuration changed.
2. `RenderSceneExtractor.extract` builds the frame data. CPU frustum culling is on unless GPU-driven culling is on.
3. The camera is chosen. If none is enabled, the output is cleared and the UI is drawn.
4. The temporal history is discarded on a camera cut. A cut is a change of camera entity, a move of more than `cutDistance` (100 world units), or a call to `cameraCut()`.
5. Jitter for temporal anti-aliasing is computed, and the frame uniforms are built from the camera.
6. The environment and reflection probes are updated. At most one probe is captured per frame.
7. `ScenePasses.prepare` builds the per-frame buffers. The `beforeScene` hooks run.
8. Shadow maps are rendered for the sun, one depth pass per cascade.
9. The compute encoder assigns lights to clusters, and runs GPU culling if enabled.
10. GPU particles are updated.
11. The prepass writes depth, normals with roughness, and motion vectors.
12. If Hi-Z is enabled, the depth pyramid is built for the next frame.
13. Ray-traced effects run if enabled. Otherwise SSAO runs if enabled.
14. The main HDR pass draws opaque geometry, the sky for perspective cameras, transparent geometry, particles, the 2D layer and debug lines. The `afterOpaque` and `afterTransparent` hooks run inside it.
15. The post chain runs. The `afterPostProcess` hooks run on the final image.
16. The UI is drawn over the final image, and the drawable is presented.

Each frame has its own slot in the frame allocator, selected by `frameIndex mod maxFramesInFlight`. A slot is reused only after the GPU has finished the frame that used it, which the renderer tracks with a semaphore.

## 3. Render paths

`GraphicsSettings.renderPath` selects the lighting architecture.

| Path | Description |
| --- | --- |
| `clusteredForward` (default) | Forward shading with a view-space cluster grid. The grid has 16 by 9 screen tiles and 24 exponential depth slices. Each cluster holds up to 64 light indices. Supports MSAA, transparency and arbitrary materials. |
| `forward` | Forward shading that iterates over every light for each pixel. No clusters are built. Suited to scenes with few lights. |

In the clustered path, directional lights come first and are not clustered. Only punctual lights (point and spot) are assigned to clusters. The shader variant `USE_CLUSTERS` is selected by the path. If the cluster buffers cannot be allocated, the frame falls back to the non-clustered variant.

## 4. Render targets and formats

The formats are fixed in `TargetFormat` in `RenderTargets.swift`.

| Target | Format | Content |
| --- | --- | --- |
| Scene colour (HDR) | `rgba16Float` | Linear radiance before tone mapping. |
| Depth and stencil | `depth32Float_stencil8` | Reverse-Z depth, and the 2D mask stencil. |
| Normal and roughness | `rgba16Float` | World normal in xyz, encoded as `n × 0.5 + 0.5`, and roughness. |
| Motion vectors | `rg16Float` | Screen-space motion in UV units, current minus previous. |
| Ambient occlusion | `r8Unorm` | One for unoccluded. |
| LDR (ping-pong pair) | `rgba8Unorm` | Tone-mapped sRGB-encoded colour. Viewed as `rgba8Unorm_srgb` for presentation. |
| Drawable | `bgra8Unorm_srgb` | The presentation format, set in `GameHost`. |
| Hi-Z pyramid | `r32Float` | The farthest reverse-Z depth per texel. |

Temporal history, the TAA and temporal-upscaler ping-pong pair, is allocated at output size, in `rgba16Float`. The MSAA colour target is created only when MSAA is active. The render targets are reallocated when the render size, output size, MSAA, history or post-feature set changes, and every allocation is reported to `MemoryTracker`.

Transient colour, depth, multisample, ambient-occlusion and post-scratch textures are placed on one `MTLHeap`. `TransientHeapPlan` gives each resource a lifetime in the frame graph and packs non-overlapping lifetimes onto the same bytes. The two LDR targets overlap for the whole post chain, so they never share an offset. History and the Hi-Z pyramid are read on the next frame and are not in the alias set. Aliased textures are created with hazard tracking off. `RenderTargets.AliasSync` updates a fence at the end of each encoder that touches them and waits on that fence at the start of the next one, including across the scene and post command buffers. MSAA attachments stay stored, because the prepass and the main pass are separate encoders; their memory can still be reused by a scratch that starts after the forward pass. If the placement heap cannot be created, each target is allocated on its own and nothing aliases.

## 5. Reverse-Z depth

Depth uses the reverse-Z convention. `Mat4.perspective` and `Mat4.orthographic` map the near plane to depth 1 and the far plane to depth 0 by default, which is the `reverseZ` parameter's default of `true`. The reason for the convention is the greater precision of floating-point values near zero.

The consequences are visible in the source:

- The prepass clears depth to 0, which is the far plane.
- The main pass tests with `greaterEqual`, and does not write depth, because the prepass already wrote it.
- The Hi-Z pyramid keeps the **minimum** of each footprint, because with reverse-Z the farthest depth is the smallest value.
- Shadow maps use standard depth. Their depth pass clears to 1 and uses `less`, because they are rendered with their own projection, not the camera's.

Any custom pipeline drawn inside the main pass must use the reverse-Z comparison. The `RenderHookContext` documentation says so.

## 6. Meshes, materials and LOD

A `MeshRenderer` draws a mesh asset with one material per submesh.

```swift
let rock = world.createEntity(named: "Rock", transform: Transform(position: Vec3(2, 0, -3)))
var renderer = MeshRenderer(mesh: AssetID("rock"), materials: [AssetID("rock.stone")])
renderer.castsShadows = true
renderer.isStatic = true                   // see section 14: not read by the renderer
world.add(renderer, to: rock)

// Per-instance overrides, without a new material asset:
var overrides = MaterialOverrides()
overrides.baseColor = Color(0.8, 0.2, 0.2)
overrides.roughness = 0.4
world.add(overrides, to: rock)
```

Materials are metallic-roughness PBR, following the glTF 2.0 model. `MaterialData` holds the base colour, metallic and roughness factors, optional textures for base colour, metallic-roughness, normal, occlusion and emission, `alphaMode` (`opaque`, `mask` or `blend`), `alphaCutoff`, `doubleSided`, and `unlit`. `features` selects shader variants, and `floatParameters` and `vectorParameters` carry custom values for user materials. `MaterialOverrides` changes the base colour, emission, metallic or roughness of one entity.

`SkinnedMeshRenderer` binds a skinned mesh to joint entities. Skinned meshes are drawn as their own batches, and are excluded from ray tracing.

`LODGroup` selects a mesh by projected height.

```swift
world.add(LODGroup(levels: [
    .init(mesh: AssetID("tree.high"), screenHeight: 0.25),   // used while the object spans 25 % or more of the height
    .init(mesh: AssetID("tree.low"),  screenHeight: 0.05),
]), to: tree)
```

The levels are sorted by threshold, highest first. The renderer computes the object's projected height from its bounding sphere, and chooses the first level whose threshold is at or below the height multiplied by `lodBias`. If no level qualifies, the object is culled when `cullBelowLastLevel` is `true`, which is the default. Otherwise the last level is used. `GraphicsSettings.lodBias` multiplies the height, so a bias above 1 keeps higher detail at greater distances.

For skinned meshes, the bounding sphere is enlarged by 1.5 times, because the bind-pose bounds do not contain the animated pose.

## 7. Culling

Two culling methods exist. The one used depends on `GraphicsSettings.gpuDrivenCulling`, which defaults to `true`.

**CPU frustum culling.** `RenderSceneExtractor` tests each renderer's bounding sphere against the camera's frustum. It is used when GPU culling is off. Shadow casters within `ShadowSettings.maxDistance` (120 world units by default) are kept even if they are outside the frustum, because they can cast into it.

**GPU-driven culling.** When `gpuDrivenCulling` is on, the CPU does not frustum-cull. Two compute kernels in `Culling.metal` run in order. `cullInstances` tests each instance's bounding sphere against the six frustum planes and, optionally, the Hi-Z pyramid, and writes one visibility flag. `expandVisibleDraws` appends each visible instance to every opaque batch that draws it, including later submeshes of the same mesh and skinned instances that share a mesh. The vertex shader reads the surviving instance index. Each batch's indirect arguments are 32 bytes (eight `uint`s: the five `MTLDrawIndexedPrimitivesIndirectArguments` words plus padding) so every batch offset stays 16-byte aligned. If either kernel fails to compile, the frame draws the CPU index list instead of an uninitialised indirect buffer. When occlusion culling is off, the kernel still receives a 1×1 `r32Float` texture (`FallbackTextures.hiz`), not the RGBA8 white placeholder, and the argument is `access::read`.

**Argument buffers and indirect command buffers.** On devices with argument buffers tier 2, one `MaterialRecord` table covers the opaque pass (`BufferIndex.materialTable` and `materialIds`). On Metal 3, that pass is then encoded into an indirect command buffer when every batch's index count is known on the CPU and the pass uses one cull mode. GPU-driven culling keeps the immediate encoder: `MTLIndirectRenderCommand` on the macOS 15 SDK can only draw with a CPU-side index count, and the culled counts are in the draw-args buffer. Tier 1 devices and mixed double-sided batches also stay immediate. An immediate draw rebinds a vertex buffer only when the buffer identity changes.

**Hi-Z occlusion.** When `occlusionCulling` is on, and GPU culling is on, the depth of the previous frame is copied and reduced into a pyramid. Each texel keeps the minimum of its footprint. The kernel tests each bounding sphere conservatively against this pyramid, using the previous frame's view-projection. An object revealed by fast camera motion can therefore be culled for one frame. The source comment notes that the CPU path is used where this is unacceptable. The CPU path is used whenever GPU culling is off.

```swift
var settings = GraphicsSettings(preset: .high)
settings.gpuDrivenCulling = true      // compute culling into indirect draws
settings.occlusionCulling = true      // Hi-Z, one frame behind
```

The effect of these settings on frame cost has not been measured here. See [21-Performance.md](21-Performance.md).

## 8. Transparency

Opaque meshes are drawn in the main pass with depth testing and writes from the prepass. Materials with `alphaMode` set to `blend` are drawn after the sky, in a separate transparent pass. They do not cast shadows. The `mask` mode is alpha-tested. Its shadow casters discard transparent texels in `shadowAlphaTestFragment`.

Particles, the 2D layer and debug lines are drawn after transparent geometry, in the same encoder. This keeps the multisampled colour target inside one pass, so the renderer does not have to store it.

## 9. Render hooks

`Renderer.addHook(_:_:)` registers a closure that runs at one of four stages. It returns a `RenderHookToken`, which `removeHook(_:)` takes. Hooks run in the order they were added.

| Stage | When | The encoder |
| --- | --- | --- |
| `beforeScene` | Before the shadows, on the scene command buffer. | `nil`. Use for compute work and uploads. |
| `afterOpaque` | Inside the main HDR pass, after opaque geometry. | The open main-pass encoder. Do not end it. |
| `afterTransparent` | Inside the main HDR pass, after the transparent geometry, particles, the 2D layer and debug lines. | The open main-pass encoder. |
| `afterPostProcess` | After tone mapping and anti-aliasing, before the UI. | `nil`. `color` is the final LDR image. |

```swift
let token = renderer.addHook(.afterTransparent) { ctx in
    // Inside the main pass: ctx.encoder is open. Pipelines must match ctx.colorFormat,
    // ctx.depthStencilFormat and ctx.sampleCount, and use reverse-Z depth.
    guard let encoder = ctx.encoder else { return }
    _ = encoder
}
renderer.removeHook(token)   // when the hook is no longer needed
```

`RenderHookContext` carries the command buffer, the encoder where one is open, the frame uniforms, the colour and depth textures, their formats, the sample count and the render size. Inside the main pass, the formats are the HDR colour format and the depth-stencil format, and the sample count is the one in use.

## 10. Offscreen rendering

`Renderer.renderOffscreen(world:width:height:time:deltaTime:ui:)` renders one frame into a new `bgra8Unorm_srgb` texture, and returns it. The width and height are clamped to 1 through 16,384. `renderOffscreen` blocks until the GPU has finished the frame, so the returned texture can be read at once. `readPixels(_:)` copies a 2D `bgra8` or `rgba8` texture into an array of tightly packed rows, four bytes per pixel. It also blocks until the copy has finished. It returns `nil` for any other format or texture type, and when the copy cannot be encoded.

`renderer.waitUntilIdle(timeout:)` waits for all submitted GPU work. It returns `false` if the GPU did not finish within the timeout, which defaults to 5 seconds.

Offscreen rendering is used by `FeroxDiag` and `FeroxBenchmarks`. See [04-Building-and-Testing.md](04-Building-and-Testing.md).

## 11. Quality presets

`GraphicsSettings(preset:)` applies a preset. The values below are those assigned in `GraphicsSettings.apply(_:)`. Everything not listed keeps its default.

| Setting | `low` | `medium` | `high` | `ultra` |
| --- | --- | --- | --- | --- |
| Anti-aliasing | FXAA | TAA | TAA | TAA |
| Upscaling | automatic spatial, performance | automatic temporal, balanced | automatic temporal, quality | native |
| Shadow map resolution | 1024 | 2048 | 2048 | 4096 |
| Cascades | 2 | 3 | 4 | 4 |
| Shadow softness | hard | PCF | PCF | PCSS |
| Local shadow slices, resolution | 0, 256 | 6, 512 | 12, 512 | 24, 1024 |
| Bloom | off | on | on | on |
| Ambient occlusion | off | on, low | on, medium | on, high |
| Ray tracing | off | off | performance | quality |
| Texture quality | low | medium | high | ultra |
| Anisotropy | 2 | 4 | 8 | 16 |
| LOD bias | 0.75 | 1 | 1.25 | 1.5 |
| Depth of field, motion blur | off | off | off | off |

`GraphicsSettings()`, the default, uses the clustered path, TAA, automatic temporal upscaling with the quality preset, four cascades, a 2048 shadow map, AgX tone mapping, and bloom and ambient occlusion on. Those values are the struct's own defaults, which differ from `.high` in some fields. Read the struct before relying on either.

Several settings are clamped by `GraphicsFeatureResolver` before rendering. A shadow map resolution outside 256 to 8192 is clamped. Cascades are clamped to 1 through 4. Anisotropy must be a power of two up to 16. The frames in flight must be 1 through 3. Each adjustment is recorded as a `GraphicsFallback`, which `FeroxDiag` prints.

## 12. Statistics and debug views

`Renderer.statistics` is a `RenderFrameStatistics`, updated each frame. Its fields are:

| Field | Meaning |
| --- | --- |
| `frameIndex` | The renderer's frame counter. |
| `cpuMilliseconds` | CPU time spent in `render`, in milliseconds. |
| `gpuMilliseconds` | GPU time of the most recently completed frame, or `nil`. |
| `renderWidth`, `renderHeight` | The internal render size. |
| `outputWidth`, `outputHeight` | The output size. |
| `dynamicScale` | The dynamic-resolution scale in effect. |
| `visibleObjects`, `culledObjects` | Counts from extraction. |
| `spritesDrawn` | 2D drawables drawn. |
| `debugLines` | Debug lines drawn. |
| `reflectionProbeCaptures` | Probe captures performed so far. |
| `skippedFrames` | Frames skipped because the GPU did not release a slot. |

GPU time is measured from the command buffers' start and end times. The scene and post buffers are timed separately, and the profiler records them as `GPU.Scene` and `GPU.Post`.

`Renderer.debugView` replaces the final image with one of the `RenderDebugView` cases: `none`, `hdrColor`, `depth` (linearised), `normals`, `motion` (scaled ×20), and `ambientOcclusion`. The value `none` is the default.

`Renderer.debugDraw` is a `DebugDraw` instance. Lines added to it are drawn in the main pass. It is cleared at the end of each frame. Lines may be drawn over geometry when `alwaysOnTop` is set.

## 13. Validation status

- The frame flow, pass order, formats and presets are read from `Renderer.swift`, `ScenePasses.swift`, `RenderTargets.swift`, `GraphicsSettings.swift` and the shader files. They have not been executed.
- The Hi-Z and culling descriptions are read from `Culling.metal` and `ScenePasses.prepareCulling`.
- The source files contain comments that cite Apple hardware families for ray tracing, and that describe test coverage. Those statements are not checked here.
- No frame time, memory or culling efficiency figure is given.

## 14. Limitations

- **Limitation: one screen camera.** The image presented to the drawable is the highest-priority enabled camera that is active in the hierarchy and has no `renderTarget`. `Engine.activeCamera()` uses that same choice, including priority ties (lowest entity index). The active camera's `viewport` is honoured: the scene is presented into that normalised rectangle of the drawable (`RenderMath.viewportPixels`), the rest is cleared to black, and UI still covers the whole drawable.
- **Render-target cameras.** Every other active camera with `renderTarget` set is drawn, in priority order, into a private `rgba16Float` texture. `Camera.targetSize` is the pixel size; when it is nil the texture matches the screen. Read it with `Renderer.renderedCameraTarget(_:)`. GPU culling and shadows are off for those views. Each distinct size has its own depth, normal, motion and colour targets, separate from the screen G-buffer. The colour is copied out before the next camera of that size reuses the buffer.
- **Limitation: the sky is drawn only for perspective cameras.** An orthographic camera shows `clearColor`.
- **Limitation: Hi-Z uses the previous frame.** Objects revealed by fast motion can be culled for one frame.
- **Limitation: `MeshRenderer.isStatic` is not read by the renderer.** The value is copied onto ray-traced instances, where nothing reads it. The component's comment says it enables batched submission and BLAS reuse, which the source does not show.
- **Limitation: skinned meshes are not ray-traced.** See [11-Ray-Tracing.md](11-Ray-Tracing.md).
- **Limitation: no offline capture or validation tool.** `FeroxDiag --render` checks that a frame is produced. It does not compare the image to a reference.
- **Limitation: presets set fixed values.** A combination that no preset sets needs a `GraphicsSettings` value built field by field.
- **Limitation: source comments refer to other document names.** Several files point to `Docs/07-3D-Rendering.md`, `Docs/08-Render-Pipeline.md` and similar names. The documents in this series that cover the same material are the ones linked here.

## 15. Related documents

- [03-Architecture.md](03-Architecture.md): where `Renderer` sits relative to `Engine` and `GameHost`.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): the frame that the renderer follows.
- [07-Rendering-2D.md](07-Rendering-2D.md): the 2D layer in the main pass.
- [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md): lights, shadows, image-based lighting and probes.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md): the post chain.
- [11-Ray-Tracing.md](11-Ray-Tracing.md): the ray-traced effects.
- [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md): the render scale.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): the settings in full.
