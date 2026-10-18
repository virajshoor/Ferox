# Graphics Settings and Presets

`GraphicsSettings` is Ferox's user-facing graphics configuration. It lives in `FeroxCore`, is plain `Codable`, `Sendable` and `Hashable` data, and expresses intent: what the game would like, not what the device will do. The renderer never reads it directly. `GraphicsFeatureResolver` resolves it against `DeviceCapabilities` and produces a `ResolvedGraphics` value, which carries the effective configuration and a list of `GraphicsFallback` entries that say what changed and why. Because all of this is platform-independent, the resolution rules can be unit tested without a GPU.

Nothing in this document has been run on hardware yet. It describes the source as it stands, and it quotes no frame rates, timings or memory figures. The Metal side is covered in [08-Rendering-3D.md](08-Rendering-3D.md), and the feature areas are covered in [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md), [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md), [11-Ray-Tracing.md](11-Ray-Tracing.md) and [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md).

## Contents

1. [Where the settings live](#1-where-the-settings-live)
2. [Top-level fields](#2-top-level-fields)
3. [Quality presets](#3-quality-presets)
4. [Setting groups](#4-setting-groups)
5. [Resolution against device capabilities](#5-resolution-against-device-capabilities)
6. [Device capabilities](#6-device-capabilities)
7. [Changing settings at run time](#7-changing-settings-at-run-time)
8. [Inspecting the resolved configuration](#8-inspecting-the-resolved-configuration)
9. [Code examples](#9-code-examples)
10. [Limitations](#10-limitations)
11. [Validation status](#11-validation-status)
12. [Related documents](#12-related-documents)

## 1. Where the settings live

| Item | Location |
| --- | --- |
| `GraphicsSettings`, presets, setting groups | `Sources/FeroxCore/GraphicsSettings.swift` |
| `DeviceCapabilities`, `GraphicsFeatureResolver`, `ResolvedGraphics`, `GraphicsFallback` | `Sources/FeroxCore/Capabilities.swift` |
| `EngineConfiguration.graphics` and `Engine.graphics` | `Sources/Ferox/Engine.swift` |
| Capability probing from `MTLDevice` | `CapabilityProbe` in `Sources/FeroxRender/Metal/RenderDevice.swift` |
| Applying settings to the renderer | `Renderer.applySettings` in `Sources/FeroxRender/Metal/Renderer.swift` |

A game sets its starting configuration on `EngineConfiguration.graphics`. At run time it changes `Engine.graphics`.

## 2. Top-level fields

`GraphicsSettings()` starts from the defaults below. `GraphicsSettings(preset:)` starts from the same defaults and then calls `apply(_:)`.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `renderPath` | `RenderPath` | `.clusteredForward` | `clusteredForward` (Forward+ with a view-space cluster grid) or `forward` (per-pixel iteration over all lights). |
| `antiAliasing` | `AntiAliasingSettings` | mode `.taa` | Anti-aliasing mode and its parameters. |
| `upscaling` | `UpscalingSettings` | `.automaticTemporal`, quality `.quality` | Upscaler mode and render-scale preset. |
| `dynamicResolution` | `DynamicResolutionSettings` | `enabled = false` | Moves the render scale towards a GPU frame-time target. |
| `rayTracing` | `RayTracingSettings` | `enabled = false` | Ray-traced shadows, reflections and ambient occlusion. |
| `shadows` | `ShadowSettings` | enabled, 2048 px, 4 cascades, `.pcf` | Shadow maps. |
| `post` | `PostProcessSettings` | tone mapper `.agx` | Tone mapping, bloom, ambient occlusion, depth of field, motion blur and colour grading. |
| `frame` | `FramePacingSettings` | vsync on, 3 frames in flight, 60 Hz fixed update | Presentation and pacing. |
| `textureQuality` | `TextureQuality` | `.high` | Number of top mip levels skipped on upload. |
| `anisotropy` | `Int` | `8` | Anisotropic filtering level. |
| `gpuDrivenCulling` | `Bool` | `true` | Compute frustum culling and Hi-Z occlusion culling into indirect draws. |
| `occlusionCulling` | `Bool` | `true` | Occlusion culling against the previous frame's hierarchical depth buffer. |
| `lodBias` | `Float` | `1` | Multiplier on LOD switching distances. Values above 1 keep higher detail further away. |

## 3. Quality presets

`QualityPreset` has four cases, `low`, `medium`, `high` and `ultra`. It is `CaseIterable` and has `String` raw values.

`apply(_:)` is a `mutating` method. It changes only the fields listed below. The effect of each preset is:

| Setting | `low` | `medium` | `high` | `ultra` |
| --- | --- | --- | --- | --- |
| Anti-aliasing mode | `fxaa` | `taa` | `taa` | `taa` |
| Upscaling (mode, quality) | `automaticSpatial`, `performance` | `automaticTemporal`, `balanced` | `automaticTemporal`, `quality` | `native`, `native` |
| Shadows (resolution, cascades, softness) | 1024, 2, `hard` | 2048, 3, `pcf` | 2048, 4, `pcf` | 4096, 4, `pcss` |
| Bloom | off | on | on | on |
| Ambient occlusion (enabled, quality) | off | on, `low` | on, `medium` | on, `high` |
| Depth of field | off | unchanged | unchanged | unchanged |
| Motion blur | off | unchanged | unchanged | unchanged |
| Ray tracing preset | `off` | `off` | `performance` | `quality` |
| Texture quality | `low` | `medium` | `high` | `ultra` |
| Anisotropy | 2 | 4 | 8 | 16 |
| LOD bias | 0.75 | 1 | 1.25 | 1.5 |

Some details of `apply(_:)` matter when a game applies a preset to settings it has already changed:

- `upscaling`, `shadows` and `rayTracing` are replaced by new values built with their initialisers. Any field the preset does not name goes back to its default. For example, `shadows.maxDistance` returns to 120, `upscaling.customRenderScale` returns to `nil`, and `rayTracing.denoise` returns to `true`.
- `low` also turns depth of field and motion blur off. The other presets leave those two effects as they were.
- Only `enabled` and `quality` change on the ambient occlusion settings, so `radius` and `intensity` are kept.
- `apply(_:)` does not change `renderPath`, `frame`, `dynamicResolution`, `gpuDrivenCulling`, `occlusionCulling`, `post.toneMapper`, `post.autoExposure`, `post.colorGrading`, `antiAliasing.msaaSamples`, the TAA and sharpening values, or the bloom threshold, intensity and radius.

The ray tracing presets, from `RayTracingSettings(preset:)`, are:

| Preset | `enabled` | Reflections | Rays per pixel | Max bounces | Resolution scale |
| --- | --- | --- | --- | --- | --- |
| `.off` | false | (struct default) | (struct default) | (struct default) | (struct default) |
| `.performance` | true | false | 1 | 1 | 0.5 |
| `.balanced` | true | (struct default, true) | 1 | 1 | 0.5 |
| `.quality` | true | (struct default, true) | 2 | 2 | 1 |

## 4. Setting groups

### 4.1 Anti-aliasing

`AntiAliasingMode` has five cases: `none`, `msaa` (hardware multisampling of the main colour pass), `fxaa` (Ferox's fast approximate AA), `smaa` (Ferox's simplified single-pass-per-stage SMAA, with no area or search textures) and `taa` (jittered projection, motion vectors and history reprojection).

`AntiAliasingSettings` has these fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `mode` | `.taa` | The anti-aliasing mode. |
| `msaaSamples` | 4 | Sample count (2, 4 or 8) used when `mode == .msaa`. |
| `taaFeedback` | 0.1 | History blend weight for the current frame. Lower is smoother, with more ghosting. |
| `taaJitterPhases` | 8 | Length of the Halton jitter cycle. |
| `sharpness` | 0.25 | Post-AA sharpening strength in [0, 1]. |

### 4.2 Upscaling

`UpscalingMode` has seven cases:

- `native` renders at output resolution.
- `feroxSpatial` and `feroxTemporal` are Ferox's own spatial upscaler and temporal upscaler (TAAU).
- `metalFXSpatial` and `metalFXTemporal` use Apple's MetalFX scalers, which need macOS 13 or later.
- `automaticSpatial` and `automaticTemporal` use MetalFX when the device supports it and Ferox's own upscaler otherwise.

`UpscalingMode.isTemporal` and `isMetalFX` report the family of each mode.

`UpscalingQuality` gives the per-axis render scale for each preset: `performance` 0.5, `balanced` 0.58, `quality` 0.67 and `native` 1.

`UpscalingSettings` also has an optional `customRenderScale`. When it is set, it overrides the preset. `renderScale` clamps the value to the range [0.25, 1].

### 4.3 Dynamic resolution

`DynamicResolutionSettings` has these fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | false | Turns the controller on. |
| `minScale` | 0.5 | Lowest render scale. The resolver clamps it to [0.25, 1]. |
| `maxScale` | 1 | Highest render scale. The resolver keeps it at or above `minScale`, and at most 1. |
| `targetGPUMilliseconds` | `nil` | GPU frame time to aim for. The field's doc comment says that `nil` derives the target from the target frame rate with 10 % headroom. |

When dynamic resolution is on and the upscaler is `none`, the resolver adds an upscaler, MetalFX spatial where supported and Ferox spatial otherwise, and records a fallback.

The feedback loop is `DynamicResolutionController` in `Sources/FeroxRender/PostSettings.swift`. It is a plain, platform-independent type. It works as follows:

- It smooths each GPU frame time with a 0.9 and 0.1 running average.
- The target is `targetGPUMilliseconds` when it is set. Otherwise the caller supplies a budget, which the controller's doc comment says is derived from the display refresh rate or the target frame rate.
- When the smoothed time is more than 5 % over the target, the scale drops by one `step` (0.05 by default), or jumps towards the estimate if that is lower. The estimate assumes that cost scales with the square of the scale.
- When the smoothed time is under 80 % of the target, the scale rises by one step.
- After each change it waits 30 frames before changing again (`cooldownFrames`).
- The scale never leaves the range from `minScale` to `maxScale`.
- It does nothing unless `settings.enabled` is true.

### 4.4 Ray tracing

`RayTracingSettings` has these fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | false | Turns the ray-traced effects on. |
| `shadows`, `reflections`, `ambientOcclusion` | true, true, true | Chooses each effect. |
| `raysPerPixel` | 1 | Rays per pixel for each effect. The resolver clamps it to 1–8. |
| `maxBounces` | 1 | Maximum reflection bounces. The resolver clamps it to 1–4. |
| `resolutionScale` | 0.5 | Ray-tracing resolution relative to the internal render size. The resolver clamps it to 0.25–1. |
| `denoise` | true | Spatio-temporal denoiser (à-trous filter with temporal accumulation). |
| `aoRadius` | 1.5 | Maximum AO ray distance, in world units. |
| `maxReflectionRoughness` | 0.6 | Rougher surfaces use the prefiltered environment instead of traced reflections. |

The resolver handles ray tracing as follows:

- If the device does not support ray tracing (`supportsRaytracing` is false), `enabled` is set to false. Shadows fall back to shadow maps, AO to SSAO, and reflections to reflection probes and IBL. Each fallback is recorded.
- If the device supports ray tracing but has no dedicated hardware (`hasHardwareRayTracing` is false, which means an Apple family below 9), the budget is reduced to 1 ray per pixel, a resolution scale of at most 0.5 and 1 bounce. The reduction is recorded only when the request was above those values.

### 4.5 Shadows

`ShadowSettings` has these fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | true | Turns shadows on. |
| `resolution` | 2048 | Shadow map size in pixels. The resolver clamps it to 256–8192. |
| `cascades` | 4 | Cascade count. The resolver clamps it to 1–4. |
| `softness` | `.pcf` | `hard`, `pcf` or `pcss`. |
| `maxDistance` | 120 | Distance over which shadows are drawn, in world units. |
| `depthBias` | 0.0015 | Depth bias. |
| `normalBias` | 0.02 | Normal-offset bias. |

If the renderer cannot allocate the shadow map, it logs an error and disables shadows (see [27-Troubleshooting.md](27-Troubleshooting.md)).

### 4.6 Post-processing

`PostProcessSettings` contains these fields:

- `toneMapper`: `ToneMapper`, one of `none`, `reinhard`, `aces` or `agx`. The default is `agx`.
- `autoExposure`: default `false`.
- `bloom`: enabled (default `true`), `threshold` 1.0, `intensity` 0.6 and `radius` 1.0.
- `ambientOcclusion`: enabled (default `true`), `quality` (`low`, `medium` or `high`, default `medium`), `radius` 0.6 and `intensity` 1.0. `sampleCount` is 8, 16 or 32 for the three quality levels.
- `depthOfField`: enabled (default `false`), `focusDistance` 10, `aperture` 2.8 and `maxBlurRadius` 8.
- `motionBlur`: enabled (default `false`), `shutter` 0.5 (the fraction of the frame interval the virtual shutter is open) and `samples` 8.
- `colorGrading`: `exposure` 0, `contrast` 1, `saturation` 1, `temperature` 0, `tint` 0, `lift` (0, 0, 0), `gamma` (1, 1, 1), `gain` (1, 1, 1) and `vignette` 0.15. The three vectors use `Vec3Codable`.

### 4.7 Frame pacing

`FramePacingSettings` has these fields:

- `targetFPS`: `Int?`, default `nil`. The doc comment says `nil` uses the display's maximum refresh rate.
- `vsync`: default `true`. The doc comment recommends it because it avoids tearing.
- `maxFramesInFlight`: default 3. The resolver clamps it to 1–3. The number of frames the CPU may run ahead of the GPU. A lower value reduces latency, and a higher value absorbs CPU spikes. The change takes effect only when the renderer is recreated (see [section 7](#7-changing-settings-at-run-time)).
- `fixedUpdateHz`: default 60. The simulation frequency.

### 4.8 Textures, filtering and culling

- `textureQuality` is `TextureQuality`, with the cases `low`, `medium`, `high` and `ultra`. `mipBias` is the number of top mip levels skipped on upload: 2 for `low`, 1 for `medium`, and 0 for `high` and `ultra`.
- `anisotropy` must be 1, 2, 4, 8 or 16. Any other value is lowered to the largest allowed value that does not exceed it.
- `gpuDrivenCulling` and `occlusionCulling` are both `true` by default. The resolver does not currently change them.
- `lodBias` multiplies the LOD switching distances.

## 5. Resolution against device capabilities

`GraphicsFeatureResolver.resolve(_:capabilities:)` returns a `ResolvedGraphics`. The rules are those in the resolver's doc comment, and they match the code:

1. MSAA sample counts are clamped to the highest count the device supports that does not exceed the request. If none is available, the mode falls back to FXAA.
2. A temporal upscaler performs anti-aliasing itself, so the effective mode is TAA. A requested mode other than `taa` or `none` is recorded as a fallback.
3. An automatic upscaler chooses MetalFX when the device supports it and Ferox's own scaler otherwise. An explicit MetalFX request on an unsupported device falls back to the matching Ferox scaler.
4. A spatial upscaler needs anti-aliased input. If anti-aliasing is `none`, FXAA is enabled.
5. A render scale of 1 with a spatial upscaler collapses to no upscaler. With a temporal upscaler it becomes native-resolution TAA.
6. Ray-traced effects need `supportsRaytracing`. Without it, the effects fall back as described in [section 4.4](#44-ray-tracing).

The resolver also clamps shadow cascades and resolution, validates anisotropy, clamps frames in flight, and adds an upscaler for dynamic resolution, as described above. A MetalFX temporal scaler's minimum input scale is 0.5 per axis, so a lower scale is raised to 0.5 and recorded.

Every change is recorded as a `GraphicsFallback`, which has `feature`, `requested`, `effective` and `reason`. Its `description` is `feature: requested → effective (reason)`. The `Feature` cases are `msaa`, `antiAliasing`, `upscaling`, `rayTracing`, `rayTracedShadows`, `rayTracedReflections`, `rayTracedAO`, `shadows`, `gpuCulling`, `dynamicResolution`, `anisotropy` and `framePacing`. The `gpuCulling` case exists, but the resolver does not record it.

`ResolvedGraphics` provides these derived values:

- `jitter` is true for TAA or a temporal upscaler, and `needsMotionVectors` is true when `jitter` is true or motion blur is on.
- `usesRayTracing` is true when any ray-traced effect is active.
- `screenSpaceAO` is true when AO is enabled and the ray-traced AO is not active.
- `renderSize(forOutput:_:)` returns the internal size for an output size. With no upscaler the scale is 1.

## 6. Device capabilities

`DeviceCapabilities` describes what the device supports. On macOS, `CapabilityProbe` in `FeroxRender` fills it from `MTLDevice` queries. Nothing is inferred from the device name, and every optional feature is queried. The fields fall into these groups:

- **Identity:** `deviceName`, `appleFamily` (7 for M1, 8 for M2, 9 for M3, M4 and later, or 0), `supportsMac2Family`, `supportsMetal3`, `hasUnifiedMemory`, `isAppleSilicon`, `isLowPower` and `isHeadless`.
- **Memory:** `recommendedMaxWorkingSetSize`, `maxThreadgroupMemoryLength` and `maxBufferLength`.
- **Features:** `supportedSampleCounts`, `supportsRaytracing`, `supportsRaytracingFromRender`, `supportsMetalFXSpatial`, `supportsMetalFXTemporal`, `supportsStageBoundaryCounters`, `supportsMeshShaders`, `argumentBuffersTier`, `supportsBCTextureCompression`, `supportsDepthResolveMinMax` and `supports32BitFloatFiltering`.
- **OS:** `osMajor` and `osMinor`.

`DeviceCapabilities.baseline` has no optional features and a sample count list of `[1]`. The resolver uses it when Metal is unavailable. `DeviceCapabilities.testAppleSiliconFull` is a fully featured profile for tests only. `hasHardwareRayTracing` is true when ray tracing is supported and `appleFamily` is 9 or higher.

## 7. Changing settings at run time

`Engine.graphics` has a `didSet` observer. When the value changes, the engine calls `onGraphicsChanged`. `GameHost` sets that callback, so changes reach the renderer before the next frame. A headless engine only stores the value.

`Renderer.applySettings(previous:)` then does the following:

- It resolves the new settings again and logs each fallback at info level, with the text `Graphics fallback: ...`.
- It updates the dynamic-resolution controller.
- If `maxFramesInFlight` changed, it logs a warning that the change takes effect only when the renderer is recreated.
- If `anisotropy` changed, it rebuilds the samplers. If that fails, it logs an error and keeps the previous samplers.
- It discards temporal history, which resets TAA, motion blur, the ray-tracing denoisers and Hi-Z.

`Renderer.cameraCut()` does the same history reset for a camera cut that automatic detection would miss.

## 8. Inspecting the resolved configuration

`swift run FeroxDiag` prints, for each preset, the resolved anti-aliasing, upscaler, render scale, render size at 2560 × 1440, ray-traced effects and fallbacks. On a machine without Metal it uses `DeviceCapabilities.baseline` and says so. `--json` writes the same report as JSON, which is useful to attach to an issue. See [section 1 of 27-Troubleshooting.md](27-Troubleshooting.md#1-start-with-feroxdiag).

## 9. Code examples

Starting a game at a preset and overriding part of it:

```swift
var config = EngineConfiguration(title: "My Game")
config.graphics = GraphicsSettings(preset: .high)
config.graphics.shadows.resolution = 4096                     // clamped to 256–8192 by the resolver
config.graphics.upscaling = UpscalingSettings(mode: .feroxTemporal, quality: .balanced)
```

Checking what a configuration becomes on a given device, without a window:

```swift
let resolved = GraphicsFeatureResolver.resolve(GraphicsSettings(preset: .ultra), capabilities: .baseline)
for fallback in resolved.fallbacks { print(fallback) }
let size = resolved.renderSize(forOutput: 2560, 1440)
print("renders at \(size.width)×\(size.height)")
```

Switching quality at run time from a game hook:

```swift
var settings = engine.graphics
settings.apply(.low)
engine.graphics = settings                                    // GameHost forwards this to the renderer
```

## 10. Limitations

- MetalFX scaler paths have not been verified on hardware, so the automatic MetalFX choice and its fallbacks are unconfirmed in practice.
- `maxFramesInFlight` takes effect only when the renderer is recreated.
- The `gpuCulling` fallback feature is never recorded by the resolver.
- `apply(_:)` resets the whole `upscaling`, `shadows` and `rayTracing` sub-structures, not only the fields a preset names.

The full list of known limitations, including the rendering ones that affect these settings, is in [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md).

## 11. Validation status

- No frame times, memory figures or benchmark results are quoted. Performance should be measured on real hardware, as described in [21-Performance.md](21-Performance.md).
- `Tests/FeroxCoreTests/GraphicsSettingsTests.swift` exists in the repository. This document cites no results from it.
- The behaviour described here comes from reading the source. It has not been confirmed on a Mac.

## 12. Related documents

- [02-Getting-Started.md](02-Getting-Started.md): setting up a project and choosing a first preset.
- [08-Rendering-3D.md](08-Rendering-3D.md): the 3D render path, including `renderPath`.
- [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md): shadow maps, cascades and softness.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md): tone mapping, bloom, AO and anti-aliasing modes.
- [11-Ray-Tracing.md](11-Ray-Tracing.md): the ray-traced effects and their budgets.
- [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md): upscalers, render scales and the dynamic-resolution controller.
- [21-Performance.md](21-Performance.md): measuring the cost of each setting.
- [25-Platform-Support.md](25-Platform-Support.md): which settings apply on which platforms.
- [27-Troubleshooting.md](27-Troubleshooting.md): fallbacks, logged errors and FeroxDiag.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md): the known limitations.
