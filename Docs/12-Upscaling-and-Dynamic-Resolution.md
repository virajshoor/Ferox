# Upscaling and Dynamic Resolution

Ferox can render a frame at a resolution below the output size and reconstruct the output with an upscaler. Two families of upscaler are available: Ferox's own spatial and temporal upscalers, and Apple's MetalFX spatial and temporal scalers. A dynamic resolution controller can change the internal resolution from frame to frame, to hold a GPU frame-time target. This document describes the settings, the render-size calculation, each upscaler and where it runs in the post chain, the MetalFX integration and its fallbacks, the dynamic resolution controller, and the limitations. The resolver is in `Sources/FeroxCore/Capabilities.swift`, the post chain in `Sources/FeroxRender/Metal/PostProcessor.swift`, and the shaders in `Sources/FeroxRender/Shaders/Post.metal`. Nothing here has been checked on a device with MetalFX support.

## Contents

1. [Render scale and output size](#1-render-scale-and-output-size)
2. [Settings](#2-settings)
3. [Ferox upscalers](#3-ferox-upscalers)
4. [MetalFX](#4-metalfx)
5. [How the upscaler is chosen](#5-how-the-upscaler-is-chosen)
6. [Dynamic resolution](#6-dynamic-resolution)
7. [Example](#7-example)
8. [Validation status](#8-validation-status)
9. [Limitations](#9-limitations)
10. [Related documents](#10-related-documents)

## 1. Render scale and output size

The renderer draws the scene at an internal size and then produces the output size.

`ResolvedGraphics.renderSize(forOutput:_:)` computes the internal size. Its width and height are the output's, multiplied by the render scale and rounded, and each is at least 1. When no upscaler is in use, the scale is 1. The dynamic resolution factor, described in section 6, multiplies the result when that feature is on.

The render scale is `UpscalingSettings.renderScale`, which is the quality preset's scale unless `customRenderScale` is set. The custom value is clamped to 0.25 through 1.

## 2. Settings

Upscaling is configured by `GraphicsSettings.upscaling`, and dynamic resolution by `GraphicsSettings.dynamicResolution`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `upscaling.mode` | `.automaticTemporal` | The upscaler. See the table below. |
| `upscaling.quality` | `.quality` | The render-scale preset: `performance`, `balanced`, `quality` or `native`. |
| `upscaling.customRenderScale` | `nil` | Overrides the preset's scale, clamped to 0.25 through 1. |
| `dynamicResolution.enabled` | `false` | Enables the dynamic resolution controller. |
| `dynamicResolution.minScale` | `0.5` | The lowest dynamic scale, clamped to 0.25 through 1. |
| `dynamicResolution.maxScale` | `1` | The highest dynamic scale. Clamped to be at least `minScale`, and at most 1. |
| `dynamicResolution.targetGPUMilliseconds` | `nil` | The GPU frame time to hold, in milliseconds. `nil` derives it from the frame rate target. |

The upscaling modes are:

| `UpscalingMode` | Upscaler |
| --- | --- |
| `native` | None. The frame is rendered at output size. |
| `feroxSpatial` | Ferox spatial upscaler. |
| `feroxTemporal` | Ferox temporal upscaler (described as TAAU in the source). |
| `metalFXSpatial` | MetalFX spatial scaler, or the Ferox spatial upscaler if MetalFX is not supported. |
| `metalFXTemporal` | MetalFX temporal scaler, or the Ferox temporal upscaler if MetalFX is not supported. |
| `automaticSpatial` | MetalFX spatial if supported, otherwise Ferox spatial. |
| `automaticTemporal` | MetalFX temporal if supported, otherwise Ferox temporal. |

The quality presets have these render scales.

| `UpscalingQuality` | Render scale |
| --- | --- |
| `performance` | 0.5 |
| `balanced` | 0.58 |
| `quality` | 0.67 |
| `native` | 1 |

`UpscalingSettings.isTemporal` and `isMetalFX` report the category of a mode.

## 3. Ferox upscalers

The Ferox upscalers are implemented in `Post.metal`, and both run in the post chain. They are used when the mode, or the device, selects them.

**Ferox spatial** (`spatialUpscaleFragment`) works on the LDR image, which is already anti-aliased. The source describes it as an edge-adaptive Lanczos-2 filter with a clamp against ringing. The filter's kernel is stretched along an edge direction taken from the local luma gradient. It runs in step 8 of the chain, after tone mapping. The spatial upscaler needs anti-aliased input, so when the anti-aliasing mode is `none`, the resolver switches it to FXAA. See [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md).

**Ferox temporal** is the TAA resolve with a larger output. The source calls it temporal upscaling, and the same shader is used for both. When the destination is larger than the source, each jittered low-resolution sample is spread over nearby output pixels with a Gaussian kernel, and accumulated into the full-resolution history. The result replaces the anti-aliasing step, so the resolver sets the anti-aliasing mode to TAA. It runs in step 2, before depth of field, and the working resolution becomes the output resolution from there.

The temporal upscaler needs jittered projection and motion vectors, so the renderer produces both when it is in use.

## 4. MetalFX

MetalFX is Apple's upscaling framework. The source comments state that the scalers are available from macOS 13. Ferox uses these classes:

- `MTLFXSpatialScaler`, through `MTLFXSpatialScalerDescriptor`. It runs on the LDR image, at step 8.
- `MTLFXTemporalScaler`, through `MTLFXTemporalScalerDescriptor`. It runs at step 2, on the HDR colour, with the depth and the motion vectors, and receives the frame's jitter.

Apple's documentation for the framework is at [https://developer.apple.com/documentation/metalfx](https://developer.apple.com/documentation/metalfx). The temporal scaler is described at [https://developer.apple.com/documentation/metalfx/mtlfxtemporalscaler](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscaler), and the spatial scaler at [https://developer.apple.com/documentation/metalfx/mtlfxspatialscaler](https://developer.apple.com/documentation/metalfx/mtlfxspatialscaler).

Support is checked once, when the render device is created. `MTLFXSpatialScalerDescriptor.supportsDevice(_:)` and `MTLFXTemporalScalerDescriptor.supportsDevice(_:)` set `supportsMetalFXSpatial` and `supportsMetalFXTemporal` in `DeviceCapabilities`. `Renderer` also probes a temporal scaler at init with colour `rgba16Float`, depth `depth32Float_stencil8` and motion `rg16Float`, scaling 16×16 to 32×32. The result is `Renderer.metalFXProbe`. Motion vectors are scaled by `(−width, −height)` and jitter is converted from NDC to input pixels with Y flipped (`MetalFXTemporalMapping`). A nil scaler is recorded and the frame uses Ferox's temporal resolve.

The scalers are created on first use for a given pair of input and output sizes, and cached under that key. A size change creates a new scaler. If a scaler cannot be created for the formats in use, or the textures lack the usage the scaler requires, the renderer logs a warning once and sets a flag, `metalFXTemporalFailed` or `metalFXSpatialFailed`. From then on, the Ferox implementation runs instead. The flag is not reset during the run.

The MetalFX temporal path also has a device-specific minimum input scale, which the source describes as typically 0.5 per axis. The resolver clamps the scale to at least 0.5 for this mode, and records the change.

## 5. How the upscaler is chosen

`GraphicsFeatureResolver.resolve` applies these rules, in order.

1. The requested mode is mapped to an upscaler. `automatic` modes use MetalFX when the device reports support, and otherwise the Ferox equivalent. An explicit MetalFX request on an unsupported device falls back to the Ferox equivalent, and the fallback is recorded.
2. If the render scale is at least 0.999, a spatial upscaler becomes `none`. A temporal upscaler stays, and then acts as native-resolution temporal anti-aliasing.
3. A MetalFX temporal scale below 0.5 is raised to 0.5, and recorded.
4. A temporal upscaler replaces the anti-aliasing mode with TAA. MSAA is then disabled.
5. A spatial upscaler with anti-aliasing `none` uses FXAA.
6. If dynamic resolution is on and no upscaler is selected, a spatial upscaler is selected: MetalFX spatial when supported, otherwise Ferox spatial. Dynamic resolution needs an upscaler to reconstruct the output.

The resolved configuration is stored as `ResolvedGraphics`, with the upscaler and the render scale. `FeroxDiag` prints the result for each preset, at 2560 by 1440. See [04-Building-and-Testing.md](04-Building-and-Testing.md).

## 6. Dynamic resolution

The dynamic resolution controller changes the render scale each frame, to keep the GPU frame time near a target. The renderer uses the controller in `FeroxRender/PostSettings.swift`. `Renderer` creates it from `DynamicResolutionSettings`.

Each frame, when the feature is on:

1. The GPU time of the most recently completed frame is read. This is one frame behind, because the GPU has not finished the current frame when it is encoded.
2. The target is `targetGPUMilliseconds` if set. Otherwise it is the frame budget, which is 1000 divided by the frame rate target, or divided by 60 when no target is set.
3. The controller smooths the measured time, with each new sample weighted 0.1 and the previous estimate 0.9.
4. If the smoothed time is more than 5 per cent above the target, the scale moves down by at least one step of 0.05, and by more if the estimate says that a lower scale is needed, but never below `minScale`.
5. If the smoothed time is below 80 per cent of the target, the scale moves up by one step of 0.05, never above `maxScale`.
6. After a change, the controller waits 30 frames before it changes again.

The scale is applied to the render size, after the upscaling render scale. The statistics record it as `RenderFrameStatistics.dynamicScale`.

`FeroxRenderTests` (`UniformsTests.swift`) covers these rules, including the cool-down and the handling of invalid timings.

```swift
var graphics = GraphicsSettings()
graphics.upscaling = UpscalingSettings(mode: .automaticTemporal, quality: .balanced)
graphics.dynamicResolution.enabled = true
graphics.dynamicResolution.minScale = 0.6
graphics.dynamicResolution.maxScale = 1.0
graphics.dynamicResolution.targetGPUMilliseconds = 8.0    // hold 8 ms of GPU time
```

## 7. Example

A common setup is a temporal upscaler at `quality` for a scene that needs a steady frame rate.

```swift
var config = EngineConfiguration(title: "Scene")
config.graphics.upscaling.mode = .automaticTemporal
config.graphics.upscaling.quality = .quality
config.graphics.antiAliasing.sharpness = 0.2     // sharpening recovers detail after upscaling
```

With `automaticTemporal`, the renderer uses MetalFX temporal where it is supported, and the Ferox temporal upscaler elsewhere. The choice is recorded in `ResolvedGraphics.upscaler`, and `FeroxDiag` reports it.

## 8. Validation status

- The resolver rules, the render-scale table and the dynamic controller were read from `Capabilities.swift`, `PostSettings.swift` and `Renderer.swift`. They have not been run.
- The MetalFX calls, their inputs and the fallback path were read from `PostProcessor.swift`. They have not been exercised on a device.
- The Ferox upscalers are described from the shader comments. Their output quality has not been observed.
- No frame time, scale, or quality figure is given.

## 9. Limitations

- **Limitation: MetalFX has no captured frame.** The mapping math is unit-tested, and `metalFXProbe` records whether this process could build a temporal scaler. No upscaled frame has been captured on hardware in this tree.
- **Limitation: MetalFX temporal has a minimum input scale.** The source uses 0.5 per axis. A lower requested scale is raised.
- **Limitation: temporal upscaling needs motion vectors and jitter.** Without them, the temporal modes cannot reconstruct detail correctly. The renderer produces both when a temporal mode is in use.
- **Limitation: dynamic resolution reacts late.** It uses the previous completed frame's GPU time, and waits 30 frames after each change.
- **Limitation: the MetalFX fallback is permanent.** Once a scaler fails, the Ferox upscaler is used until the renderer is recreated.
- **Limitation: dynamic scale is bounded.** It cannot go below `minScale` or above `maxScale`. When dynamic resolution is on with `native` upscaling, the resolver adds a spatial upscaler, so the feature is not silently inactive.
- **Limitation: no measured quality or cost.** See [21-Performance.md](21-Performance.md).

## 10. Related documents

- [08-Rendering-3D.md](08-Rendering-3D.md): the frame, the render targets and the statistics.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md): the post chain in which the upscalers run, and sharpening.
- [11-Ray-Tracing.md](11-Ray-Tracing.md): the effects that run before the upscalers.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): the settings in one place.
- [21-Performance.md](21-Performance.md): measuring the frame time that the controller uses.
