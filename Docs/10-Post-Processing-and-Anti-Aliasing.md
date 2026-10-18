# Post-Processing and Anti-Aliasing

After the main pass, the renderer runs a chain of full-screen passes that turns the HDR scene colour into the final sRGB image. This document describes that chain and the settings that control it: screen-space ambient occlusion, bloom, auto exposure, depth of field, motion blur, tone mapping and colour grading, the anti-aliasing modes, sharpening, and how the anti-aliasing mode interacts with upscaling. The chain is encoded in `Sources/FeroxRender/Metal/PostProcessor.swift`, the shaders are in `Sources/FeroxRender/Shaders/Post.metal`, and the settings are in `Sources/FeroxCore/GraphicsSettings.swift` and `Sources/FeroxRender/PostSettings.swift`. Upscaling is in [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md). Nothing in this document has been checked on a GPU.

## Contents

1. [The chain in order](#1-the-chain-in-order)
2. [Settings](#2-settings)
3. [Screen-space ambient occlusion](#3-screen-space-ambient-occlusion)
4. [Bloom](#4-bloom)
5. [Auto exposure](#5-auto-exposure)
6. [Depth of field and motion blur](#6-depth-of-field-and-motion-blur)
7. [Tone mapping and colour grading](#7-tone-mapping-and-colour-grading)
8. [Anti-aliasing](#8-anti-aliasing)
9. [Sharpening](#9-sharpening)
10. [Interaction with upscaling](#10-interaction-with-upscaling)
11. [Configuration example](#11-configuration-example)
12. [Validation status](#12-validation-status)
13. [Limitations](#13-limitations)
14. [Related documents](#14-related-documents)

## 1. The chain in order

`PostProcessor` describes the chain in its header comment. Each stage is skipped when disabled.

| Step | Stage | Where it runs |
| --- | --- | --- |
| 1 | Screen-space ambient occlusion (`encodeSSAO`) | After the prepass, before the main pass, so the forward shader can read it. |
| 2 | Temporal anti-aliasing or temporal upscaling (MetalFX or Ferox) | Into the history ping-pong. From here the working resolution may be the output resolution. |
| 3 | Depth of field, then motion blur | HDR, at working resolution. |
| 4 | Luminance histogram and exposure adaptation | On the GPU, into a one-float buffer that is never read back. |
| 5 | Bloom | A 13-tap downsample chain and a tent upsample with additive blending, in the mips of one pooled half-resolution texture. |
| 6 | Tone mapping and colour grading | Into an sRGB-encoded `rgba8Unorm` target. |
| 7 | FXAA or SMAA | On the LDR image, after tone mapping. |
| 8 | Spatial upscaling (MetalFX or Ferox) | When the working resolution is below the output. |
| 9 | Sharpening | After temporal or upscaling passes. |
| 10 | Debug view | Replaces the final image, if one is selected. |

`encodePresent` then copies the result into the drawable, through an sRGB view. The UI is drawn on top in the same pass.

The order matters. Depth of field and motion blur run in linear HDR, before tone mapping. Anti-aliasing for the FXAA and SMAA modes runs on the sRGB-encoded image, as their algorithms expect. Temporal anti-aliasing runs before tone mapping, on HDR values, with a tone-mapped weighting to limit the influence of bright pixels.

## 2. Settings

Post-processing settings are in `GraphicsSettings.post`, a `PostProcessSettings`. Anti-aliasing and sharpening are in `GraphicsSettings.antiAliasing`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `post.toneMapper` | `.agx` | `none`, `reinhard`, `aces` or `agx`. See section 7. |
| `post.autoExposure` | `false` | Adapts exposure to the scene's average brightness. See section 5. |
| `post.bloom.enabled` | `true` | Enables bloom. |
| `post.bloom.threshold` | `1.0` | Brightness above which bloom begins. |
| `post.bloom.intensity` | `0.6` | Strength of the bloom added to the image. |
| `post.bloom.radius` | `1.0` | Scales the blur. Clamped to at least 0.1. |
| `post.ambientOcclusion.enabled` | `true` | Enables SSAO when ray-traced AO is not in use. |
| `post.ambientOcclusion.quality` | `.medium` | 8, 16 or 32 samples for `low`, `medium` and `high`. |
| `post.ambientOcclusion.radius` | `0.6` | The sampling radius, in world units. |
| `post.ambientOcclusion.intensity` | `1.0` | Strength of the occlusion. |
| `post.depthOfField.enabled` | `false` | Enables depth of field. |
| `post.depthOfField.focusDistance` | `10` | The distance in focus, in world units. |
| `post.depthOfField.aperture` | `2.8` | The f-number. |
| `post.depthOfField.maxBlurRadius` | `8` | The largest blur, clamped to 0 through 32. |
| `post.motionBlur.enabled` | `false` | Enables motion blur. |
| `post.motionBlur.shutter` | `0.5` | The fraction of the frame interval the shutter is open, clamped to 0 through 1. |
| `post.motionBlur.samples` | `8` | Samples per pixel, clamped to 2 through 32. |
| `post.colorGrading` | see section 7 | Exposure, contrast, saturation, white balance, lift, gamma, gain and vignette. |
| `antiAliasing.mode` | `.taa` | `none`, `msaa`, `fxaa`, `smaa` or `taa`. See section 8. |
| `antiAliasing.msaaSamples` | `4` | The requested MSAA sample count. |
| `antiAliasing.taaFeedback` | `0.1` | The weight of the current frame in the TAA history, clamped to 0.02 through 1. Lower values are smoother and ghost more. |
| `antiAliasing.taaJitterPhases` | `8` | The number of jitter positions in the Halton sequence. |
| `antiAliasing.sharpness` | `0.25` | The sharpening strength, clamped to 0 through 1. |

The quality presets set several of these values, including bloom, ambient occlusion and anti-aliasing. See [08-Rendering-3D.md](08-Rendering-3D.md), section 11.

## 3. Screen-space ambient occlusion

SSAO estimates how much each pixel is occluded by nearby geometry, using only the depth and normal buffers. It runs when `ambientOcclusion.enabled` is set and ray-traced ambient occlusion is not active for the frame.

The pass `ssaoFragment` samples the hemisphere around each pixel's normal. The number of samples is set by the quality: 8 for `low`, 16 for `medium` and 32 for `high`. A second pass, `ssaoBlurFragment`, smooths the result. The output is a one-channel `r8Unorm` texture in which one means unoccluded. The forward shader reads it, and so does the debug view `ambientOcclusion`.

Ray-traced ambient occlusion, when enabled, replaces SSAO for the frame. See [11-Ray-Tracing.md](11-Ray-Tracing.md).

## 4. Bloom

Bloom adds a blurred copy of the bright parts of the image. The bright parts are the values above `threshold`, and the renderer applies a soft knee at half the threshold, so the transition into the glow is gradual.

The bloom chain works in the mips of one half-resolution texture. The downsample pass uses a 13-tap filter and applies the threshold on its first level, with a Karis average to limit the effect of single very bright pixels. The upsample pass uses a tent filter and adds each level into the one above it. The number of levels depends on the image size. `PostUniformsBuilder.bloomMipCount` counts how many times the smaller side can be halved while it stays at 8 pixels or more, to a maximum of 7 levels.

The result is multiplied by `intensity` and added to the image before tone mapping. Bloom is skipped when `enabled` is `false` or when its intensity is zero.

## 5. Auto exposure

When `autoExposure` is on, the exposure is adapted from the image, on the GPU.

1. `luminanceHistogram` bins the log2 luminance of every pixel into 128 bins, from −10 to +20 EV. Pixels at or below a very small luminance go into bin 0.
2. `adaptExposure` ignores the darkest 50 per cent and the brightest 2 per cent of the histogram. It takes the mean of the remaining bins, converts it to a luminance, and computes a target exposure of 0.18 divided by that luminance.
3. The stored exposure moves towards the target by a factor of `1 − exp(−dt × 1.5)`, so the adaptation rate is 1.5 per second in the exponential sense. `dt` is the unscaled frame time.

The exposure is kept in a GPU buffer and read by the tone mapper directly. The CPU never reads it back, so auto exposure adds no synchronisation.

The camera's `exposureEV100` is converted by `RenderMath.exposure` and passed in the frame uniforms, whichever auto-exposure setting is in use. `colorGrading.exposure` is a separate multiplier applied in the tone mapper, as a power of two.

## 6. Depth of field and motion blur

**Depth of field** (`dofFragment`) blurs pixels by their distance from `focusDistance`. The blur radius depends on a physical focal length, which is derived from the camera's vertical field of view using a 24 mm sensor height. The aperture sets the strength. The radius is clamped to `maxBlurRadius`, which is at most 32 pixels. The pass runs on HDR colour at working resolution.

**Motion blur** (`motionBlurFragment`) smears each pixel along its motion vector, read from the motion target. The vector is scaled by `shutter`, which is the fraction of the frame interval the virtual shutter is open. It takes between 2 and 32 samples. Motion blur requires motion vectors, which the renderer produces when temporal anti-aliasing or motion blur is on.

Both effects run before tone mapping, so they act on linear light.

## 7. Tone mapping and colour grading

`post.toneMapper` selects one of four operators. `ToneMapper.none` clamps the value, without a curve. `reinhard` applies a Reinhard-style curve with a white point of 4. `aces` applies an ACES filmic fit, after Stephen Hill. `agx` applies the AgX base look, a polynomial contrast fit that returns linear display values. The default is `agx`.

`tonemapFragment` applies the following steps, in this order:

1. The bloom is added to the HDR colour.
2. The exposure is applied: the colour grading exposure as a power of two, multiplied by the auto-exposure value when that is on.
3. White balance is applied, using the temperature and tint, converted to LMS space on the CPU.
4. Contrast is applied in log space, around middle grey, which is 0.18.
5. Saturation is applied by mixing the colour with its luminance.
6. The tone operator is applied.
7. Lift, gain, gamma and vignette are applied to the display-referred values. Vignette darkens the corners by the vignette amount, which is clamped to 0 through 1.
8. The result is encoded to sRGB and dithered, to hide banding in dark gradients.

`PostProcessSettings.colorGrading` holds the grading parameters.

| Field | Default | Meaning |
| --- | --- | --- |
| `exposure` | `0` | Exposure in stops. |
| `contrast` | `1` | Contrast, around middle grey. |
| `saturation` | `1` | Saturation. |
| `temperature`, `tint` | `0`, `0` | White balance. |
| `lift` | (0, 0, 0) | Shadow offset. |
| `gamma` | (1, 1, 1) | Per-channel gamma. |
| `gain` | (1, 1, 1) | Per-channel gain. |
| `vignette` | `0.15` | Corner darkening. |

A 2D game that needs the colours of its textures without a curve sets `toneMapper` to `.none`, and sets `vignette` to 0. See [07-Rendering-2D.md](07-Rendering-2D.md), section 12.

## 8. Anti-aliasing

`antiAliasing.mode` selects one technique.

| Mode | How it works | Where it runs |
| --- | --- | --- |
| `none` | No anti-aliasing. | Not applicable. |
| `msaa` | Hardware multisampling of the main colour and depth. The renderer resolves the samples. | In the main pass. |
| `fxaa` | The Lottes quality variant, with an eight-step edge search on the luma of the LDR image. | After tone mapping. |
| `smaa` | A three-pass morphological filter: edge detection, blending weights and neighbourhood blending. The weights are computed analytically from edge lengths, not from SMAA's precomputed area and search textures. | After tone mapping. |
| `taa` | Jittered projection, motion vectors and history reprojection, with a 5-tap Catmull-Rom sample of the history and neighbourhood clamping. | Before tone mapping. |

**MSAA.** The requested sample count is clamped to the largest count the device supports that does not exceed the request. `GraphicsFeatureResolver` checks the counts against `supportedSampleCounts`. If no multisampling is available, the mode falls back to FXAA, and the fallback is recorded. The multisampled targets exist only when the resolved count is above 1.

**TAA.** The projection is jittered by the Halton sequence `RenderMath.halton`, over `taaJitterPhases` positions. Each frame's colour is blended with the reprojected history, using `taaFeedback` as the weight of the current frame. The history is clamped to the neighbourhood of the current pixel, which limits ghosting from disocclusions. The history is reset on a camera cut.

**FXAA and SMAA.** Both work on the sRGB-encoded LDR image, after tone mapping. They see only the final pixels, so they have less information than TAA or MSAA, which use the scene's sub-pixel samples.

## 9. Sharpening

A contrast-adaptive sharpening pass recovers detail softened by temporal accumulation or by upscaling. It runs only when `sharpness` is above zero and at least one of these holds: TAA is the anti-aliasing mode, a temporal upscaler is in use, or any spatial upscaling is needed. The sharpening peak depends on `sharpness`, so stronger settings sharpen more.

## 10. Interaction with upscaling

The anti-aliasing mode and the upscaler are resolved together by `GraphicsFeatureResolver`. The rules that matter here are:

- A temporal upscaler performs anti-aliasing itself. TAA is therefore used whatever the mode was, and MSAA is disabled. A different mode is recorded as a fallback.
- A spatial upscaler needs anti-aliased input. If the mode is `none`, the resolver uses FXAA.
- MSAA is clamped to the device's supported counts, as described in section 8.

See [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md) for the upscalers themselves.

## 11. Configuration example

```swift
var graphics = GraphicsSettings()
graphics.post.toneMapper = .aces
graphics.post.autoExposure = true
graphics.post.bloom.threshold = 1.2
graphics.post.bloom.intensity = 0.4
graphics.post.ambientOcclusion.quality = .high
graphics.post.depthOfField.enabled = true
graphics.post.depthOfField.focusDistance = 8
graphics.post.motionBlur.enabled = true
graphics.post.motionBlur.shutter = 0.4
graphics.antiAliasing.mode = .smaa
graphics.antiAliasing.sharpness = 0.2
```

Changing `graphics` at run time takes effect on the next frame, through the host. Assigning new settings to the renderer invalidates its temporal history, so the first frame after a change is not blended with earlier frames. See [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md).

## 12. Validation status

- The chain order, the parameter ranges and the shader algorithms were read from `PostProcessor.swift`, `Post.metal`, `PostSettings.swift` and `GraphicsSettings.swift`. None of them has been executed.
- The constants quoted here (the bin count, the exposure range, the adaptation factor, the bloom mip limit, and the clamps) are taken from the source.
- The visual results, including ghosting, flicker and the look of each tone operator, have not been observed.

## 13. Limitations

- **Limitation: SMAA is a simplified variant.** It has no precomputed area and search textures, so its edge weights are approximations.
- **Limitation: FXAA and SMAA see only the LDR image.** They cannot use sub-pixel scene data.
- **Limitation: TAA can ghost.** Fast-moving or disoccluded content is reprojected from history that may not match. Clamping limits the artefacts but does not remove them.
- **Limitation: TAA is reset on camera cuts.** A cut is detected from a camera change, a move beyond 100 world units, or an explicit `cameraCut()` call.
- **Limitation: motion blur depends on motion vectors.** A surface that moves without a motion vector is not blurred.
- **Limitation: auto exposure is a histogram average.** It reacts to the whole frame, so a small bright light can be overridden by a large dark area, and the reverse.
- **Limitation: depth-of-field blur is capped.** The radius is clamped to `maxBlurRadius`, which is at most 32 pixels.
- **Limitation: post-processing has no measured cost here.** See [21-Performance.md](21-Performance.md).

## 14. Related documents

- [08-Rendering-3D.md](08-Rendering-3D.md): the main pass that these stages follow.
- [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md): the lit image that these stages process.
- [11-Ray-Tracing.md](11-Ray-Tracing.md): ray-traced ambient occlusion, which replaces SSAO.
- [12-Upscaling-and-Dynamic-Resolution.md](12-Upscaling-and-Dynamic-Resolution.md): the upscalers that run in steps 2 and 8.
- [07-Rendering-2D.md](07-Rendering-2D.md): the 2D layer, which is tone mapped with the rest of the image.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): the settings in one place.
