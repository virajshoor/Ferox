# Ray Tracing

Ferox uses Metal ray tracing for three effects: shadows from the sun, ambient occlusion, and reflections. The rest of the frame stays rasterised. Primary visibility comes from the depth and normal prepass, and the rays are traced from there. The effects run as compute kernels at a fraction of the render resolution, accumulate over time, and are denoised before the forward pass reads them. Every effect has a fallback to the rasterised technique it replaces. This document describes the settings, the capability checks and fallbacks, the acceleration structures, the effects and their denoising, and the limitations. The code is in `Sources/FeroxRender/Metal/RayTracingContext.swift` and `Sources/FeroxRender/Shaders/RayTracing.metal`, and the settings are in `Sources/FeroxCore/GraphicsSettings.swift`. Nothing here has been run on hardware that supports ray tracing.

## Contents

1. [Settings and presets](#1-settings-and-presets)
2. [Capability checks](#2-capability-checks)
3. [Fallbacks](#3-fallbacks)
4. [Acceleration structures](#4-acceleration-structures)
5. [The effects](#5-the-effects)
6. [Denoising and accumulation](#6-denoising-and-accumulation)
7. [Integration with the frame](#7-integration-with-the-frame)
8. [Validation status](#8-validation-status)
9. [Limitations](#9-limitations)
10. [Related documents](#10-related-documents)

## 1. Settings and presets

`GraphicsSettings.rayTracing` holds a `RayTracingSettings`.

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Turns ray tracing on. Nothing is traced when this is `false`. |
| `shadows` | `true` | Ray-traced sun shadows. |
| `reflections` | `true` | Ray-traced reflections. |
| `ambientOcclusion` | `true` | Ray-traced ambient occlusion. |
| `raysPerPixel` | `1` | Rays per pixel for each effect. Clamped to 1 through 8. |
| `maxBounces` | `1` | Maximum reflection bounces. Clamped to 1 through 4. |
| `resolutionScale` | `0.5` | The ray-tracing resolution relative to the internal render size. Clamped to 0.25 through 1. |
| `denoise` | `true` | Enables the spatio-temporal denoiser. |
| `aoRadius` | `1.5` | The maximum ray distance for ambient occlusion, in world units. |
| `maxReflectionRoughness` | `0.6` | Surfaces rougher than this use the prefiltered environment, not traced reflections. |

`RayTracingSettings(preset:)` sets the values for four presets.

| Preset | `enabled` | Reflections | Rays per pixel | Bounces | Resolution scale |
| --- | --- | --- | --- | --- | --- |
| `.off` | `false` | unchanged | unchanged | unchanged | unchanged |
| `.performance` | `true` | `false` | 1 | 1 | 0.5 |
| `.balanced` | `true` | unchanged (`true`) | 1 | 1 | 0.5 |
| `.quality` | `true` | unchanged (`true`) | 2 | 2 | 1 |

Quality presets choose a ray-tracing preset. `low` and `medium` use `.off`, `high` uses `.performance`, and `ultra` uses `.quality`. See [08-Rendering-3D.md](08-Rendering-3D.md), section 11.

```swift
var settings = GraphicsSettings(preset: .medium)
settings.rayTracing = RayTracingSettings(preset: .balanced)   // turns ray tracing on
settings.rayTracing.reflections = false                       // keep the other two effects
```

## 2. Capability checks

`GraphicsFeatureResolver` decides what runs, from the requested settings and `DeviceCapabilities`.

1. If `rayTracing.enabled` is `true` and `supportsRaytracing` is `false`, ray tracing is disabled for the whole frame, and every effect falls back. The fallback is recorded, and `FeroxDiag` prints it.
2. If `supportsRaytracing` is `true`, the three effects are enabled according to the settings.
3. `DeviceCapabilities.hasHardwareRayTracing` is `supportsRaytracing && appleFamily >= 9`. When it is `false`, the resolver reduces the budget: one ray per pixel, a resolution scale of at most 0.5, and one bounce. Each reduction is recorded as a fallback.
4. The ray-tracing values are then clamped to their ranges: rays 1 to 8, bounces 1 to 4, and resolution scale 0.25 to 1.

The `DeviceCapabilities` documentation describes the hardware split. It says that Apple family 9, which it associates with M3 and later, runs ray tracing on dedicated hardware, and that earlier families run Metal's intersection API on the shader cores. It says the second case is correct but markedly slower. This is the source's statement. It has not been measured here.

`DeviceCapabilities.supportsRaytracingFromRender` is recorded from the device, and the resolver does not read it. The effects are compute kernels, so they do not depend on ray queries in render functions.

## 3. Fallbacks

Each effect has a rasterised technique that it replaces.

| Effect | Ray-traced version | Fallback when ray tracing is unavailable |
| --- | --- | --- |
| Sun shadows | Ray-traced visibility from each pixel to the sun. | Cascaded shadow maps. See [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md). |
| Ambient occlusion | Ray-traced occlusion within `aoRadius`. | Screen-space ambient occlusion. See [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md). |
| Reflections | Traced reflections, for surfaces up to `maxReflectionRoughness` in roughness. | Reflection probes and image-based lighting. |

The resolver records each fallback as a `GraphicsFallback`. For example, when ray tracing is not supported, it notes that shadows fall back to shadow maps, reflections to probes and IBL, and ambient occlusion to SSAO.

When a single effect is turned off in the settings, its fallback is used, and the other effects continue. A rough surface uses the prefiltered environment even when reflections are on.

## 4. Acceleration structures

The renderer builds two levels of acceleration structure, as the `RayTracingContext` documentation describes.

- **Bottom level (BLAS).** One primitive acceleration structure for each mesh. It is built the first time the mesh is used by a ray-traced frame, and stored on the mesh's GPU resource. It is therefore released when the mesh leaves the cache.
- **Top level (TLAS).** Rebuilt every frame from the ray-traced instances the extractor collected. There is one TLAS per frame-in-flight slot, so that a rebuild never overwrites a structure that the GPU is still reading. The TLAS and its scratch buffer grow by a factor of 3 over 2, so that a change in instance count does not reallocate every frame.

Each instance is built with the opaque flag and triangle culling disabled, and with a mask of `0xFF`. The instance transform is the entity's world matrix. Meshes that have a skin are excluded: `buildScene` skips them, because their bind pose would be wrong.

Ray-traced instances are collected only when ray tracing is in use for the frame, through `ExtractionOptions.collectRayTracingInstances`. The `isStatic` flag of a `MeshRenderer` is copied onto each ray-traced instance, but `RayTracingContext` does not read it. The bottom-level structure is shared per mesh whatever the flag says.

## 5. The effects

Three compute kernels trace the effects in `RayTracing.metal`:

- `rtShadows` traces a ray from each pixel towards the sun, within the sun's cone, and writes a visibility value.
- `rtAO` traces short rays from each pixel over the hemisphere, up to `aoRadius`, and writes an occlusion value.
- `rtReflections` traces a reflection ray from each pixel, shades the hit with the instance's constant material, and writes the reflected colour. Surfaces rougher than `maxReflectionRoughness` are not traced.

Each effect traces at `resolutionScale` of the internal render size, clamped to 0.25 through 1. The shader's comments say that each kernel writes a noisy, low-sample signal. The result is made stable by the denoiser in section 6.

Reflection hits are shaded with constant values for each instance, not textures. The `RTInstanceMaterial` structure holds, per instance, an albedo and a roughness, and an emission and a metallic value. The hit does not sample the material's textures, and it uses a sun and ambient term only. The source calls this a deliberate cost trade.

## 6. Denoising and accumulation

When `denoise` is on, each effect's signal passes through two stages.

1. **Temporal accumulation** (`rtTemporal`) blends the current signal with the previous frame's result, after reprojecting it with the motion vectors. The blend uses a fixed current-frame weight. The history is kept in a ping-pong pair, and is valid only when the previous frame's history was written.
2. **À-trous filter** (`rtAtrous`) is a wavelet-style filter that removes the remaining noise. It is applied three times, with steps of 1, 2 and 4 texels. Its weights depend on depth and on the normal, so that the filter does not blur across edges.

Camera cuts reset the history. `RayTracingContext.resetHistory()` is called on every history invalidation in the renderer, which includes a settings change and a camera cut.

## 7. Integration with the frame

When the resolver enables ray-traced effects, the scene passes change in these ways:

- **Shadows.** The shadow-map cascades are not built, because the ray-traced shadow buffer is read instead. The shader selects it by an effect flag.
- **Ambient occlusion.** SSAO is not computed, because `screenSpaceAO` is set only when ray-traced ambient occlusion is off.
- **Reflections.** The forward shader reads the ray-traced reflection buffer. When it is not in use, the reflection term comes from probes and IBL.

The effects run in the scene command buffer, after the prepass and the Hi-Z build, and before the main pass. The effect flags are written into the frame uniforms before the forward pass reads them, so the main pass always sees the right inputs.

## 8. Validation status

- The capability rules, fallbacks, acceleration-structure policy and denoising pipeline were read from the Swift and Metal sources. They have not been run.
- The hardware-family statement comes from the source's documentation. No Mac with ray-tracing hardware was available, and the statement has not been checked.
- The shader header states that ray tracing applies to Apple family 6 and later. The capability documentation uses family 9 for dedicated hardware. The two statements are in the source as written. They have not been reconciled here.
- No frame time, noise level or memory figure is given.

## 9. Limitations

- **Limitation: opaque geometry only.** The acceleration structures treat every instance as opaque. Alpha-tested foliage casts solid shadows, and transparent surfaces block rays as if they were solid.
- **Limitation: no skinned meshes.** Skinned meshes are excluded from the acceleration structure, so they cast no ray-traced shadows or reflections. They are drawn by the rasterised path, and their pixels use the screen-space results like any other pixel.
- **Limitation: constant material at hits.** Reflection hits use one albedo, roughness and emission per instance, with no texture lookups. Reflections of textured surfaces look flat.
- **Limitation: rough surfaces are not traced.** Above `maxReflectionRoughness`, the prefiltered environment is used.
- **Limitation: a single sun for shadows.** Ray-traced shadows use the sun only, as shadow maps do.
- **Limitation: denoising can lag.** Temporal accumulation reacts to change with a delay, and disocclusions show noise until the history rebuilds.
- **Limitation: ray tracing needs hardware support.** Without `supportsRaytracing`, every effect falls back. Nothing in the snapshot tests the fallback path on a device that lacks support.
- **Limitation: no measured cost.** See [21-Performance.md](21-Performance.md).

## 10. Related documents

- [08-Rendering-3D.md](08-Rendering-3D.md): the frame in which the ray-traced effects run, and the presets that enable them.
- [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md): the shadow maps and probes that the fallbacks use.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md): SSAO, the fallback for ambient occlusion.
- [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md): the upscalers, which run after the effects.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): the settings in full.
