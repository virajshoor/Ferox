# Lighting and Shadows

This document describes the light types, their units and how they are selected, the cascaded shadow maps for the sun and their filtering, the image-based lighting and sky environment, exponential fog, and reflection probes. The code is in `Sources/FeroxScene/RenderComponents.swift` (the component data), `Sources/FeroxRender/RenderScene.swift` (light extraction), `Sources/FeroxRender/Metal/ScenePasses.swift` and `Sources/FeroxRender/Shaders/Mesh.metal` (shadows and shading), `Sources/FeroxRender/Metal/EnvironmentLighting.swift`, and `Sources/FeroxRender/Metal/ReflectionProbes.swift`. The render pipeline that these feed is in [08-Rendering-3D.md](08-Rendering-3D.md). Nothing here has been rendered on a GPU.

## Contents

1. [Light types and units](#1-light-types-and-units)
2. [Light selection and extraction](#2-light-selection-and-extraction)
3. [Clustered punctual lights](#3-clustered-punctual-lights)
4. [Cascaded shadow maps](#4-cascaded-shadow-maps)
5. [Shadow filtering](#5-shadow-filtering)
6. [Sky and image-based lighting](#6-sky-and-image-based-lighting)
7. [Fog and ambient light](#7-fog-and-ambient-light)
8. [Reflection probes](#8-reflection-probes)
9. [Validation status](#9-validation-status)
10. [Limitations](#10-limitations)
11. [Related documents](#11-related-documents)

## 1. Light types and units

A light is a `Light` component on an entity. Its `type` is one of three cases.

| `LightType` | Shape of the light | Position and direction | Range |
| --- | --- | --- | --- |
| `.directional` | Parallel rays, such as the sun. | Direction only: the entity's forward axis (its −Z axis in the source's convention). | Not used. |
| `.point` | Emits in all directions from the entity's position. | Position. | Attenuation range in world units. |
| `.spot` | A cone from the entity's position along its forward axis. | Position and direction. | Attenuation range in world units. |

The fields and their defaults are:

| Field | Default | Meaning |
| --- | --- | --- |
| `color` | white | The light's colour. |
| `intensity` | `10` | The brightness. The source comment gives lux for directional lights, and candela for point and spot lights, as glTF `KHR_lights_punctual` does. The value is pre-exposed by the camera. |
| `range` | `10` | The distance beyond which a point or spot light contributes nothing. |
| `innerConeAngle` | `0.3` rad | The angle inside which a spot light is at full strength. |
| `outerConeAngle` | `0.5` rad | The angle beyond which a spot light contributes nothing. |
| `castsShadows` | `false` | Requests a shadow map: cascades for the sun (section 4), budgeted slices for point and spot lights (section 5). |
| `is2D` | `false` | Makes the light a 2D light. See [07-Rendering-2D.md](07-Rendering-2D.md). |

The constructors are `Light(type:color:intensity:range:)`, which creates a point light by default, and `Light.directional(_:intensity:shadows:)`. The directional constructor defaults to an intensity of 3 and to shadows on. The `HelloFerox` example uses it as `Light.directional(intensity: 4, shadows: true)`.

```swift
let sun = world.createEntity(
    named: "Sun",
    transform: Transform(rotation: .lookRotation(forward: Vec3(-0.4, -1, -0.3).normalized)))
world.add(Light.directional(intensity: 4, shadows: true), to: sun)

let lamp = world.createEntity(named: "Lamp", transform: Transform(position: Vec3(2, 3, 0)))
world.add(Light(type: .point, color: Color(1, 0.8, 0.6), intensity: 800, range: 12), to: lamp)

let beam = world.createEntity(named: "Beam", transform: Transform(position: Vec3(0, 5, 0),
                                                                   rotation: .lookRotation(forward: Vec3(0, -1, 0))))
var spot = Light(type: .spot, intensity: 1200, range: 15)
spot.outerConeAngle = 0.5
spot.innerConeAngle = 0.35
world.add(spot, to: beam)
```

The `intensity` of 800 and 1200 in the last two examples are illustrative values. They are not presets in the source. Choose intensities by inspecting the scene.

## 2. Light selection and extraction

`RenderSceneExtractor.extractLights` builds the light list for each frame. A light is skipped when any of these holds:

- `is2D` is `true`;
- `intensity` is not above 0;
- its entity is not active in its hierarchy;
- its `Layer` is not in the camera's `cullingMask`.

Directional lights are kept, and their direction is the entity's forward vector. A point or spot light is kept only if the sphere of radius `range` around it intersects the camera's frustum. Spot cones are clamped: the outer angle to between 0.001 and π/2 − 0.001 radians, and the inner angle to below the outer angle.

**The sun.** One directional light is singled out as the sun. It is the first directional light with `castsShadows` set. If none has shadows, the brightest directional light is the sun. The sun drives the sky, the shadow maps and the sun term in the shading. All directional lights are added to the light list, but only the sun is shadowed.

**Shadowed point and spot lights.** Point and spot lights with `castsShadows` are listed in `RenderFrameData.shadowedLights`, nearest to the camera first. The renderer gives them shadow-map slices until the budget runs out; see section 5.

**Limit.** At most 1024 punctual lights are passed to the frame, which is `ExtractionOptions.maxPunctualLights`. If there are more, the nearest to the camera are kept.

## 3. Clustered punctual lights

In the clustered render path, punctual lights are assigned to clusters by the compute kernel `assignLights` in `Clusters.metal`. The view frustum is split into 16 by 9 screen tiles and 24 exponential depth slices, so there are 3,456 clusters. Each cluster stores up to 64 light indices, the fourth component of `clusterDims`. A light is assigned to a cluster if its bounding sphere intersects the cluster's box.

Directional lights come first in the light list, and they are not clustered, so the cluster grid does not limit them.

The forward path, selected by `RenderPath.forward`, iterates over all lights for each pixel and builds no clusters. The cluster limit does not apply to that path. See [08-Rendering-3D.md](08-Rendering-3D.md), section 3.

## 4. Cascaded shadow maps

Shadows for the sun use cascaded shadow maps (CSM). The view frustum is divided into slices, and each slice has its own depth map.

Settings are in `ShadowSettings`.

| Field | Default | Effect |
| --- | --- | --- |
| `enabled` | `true` | Turns sun shadows on or off. |
| `resolution` | `2048` | The side length of each cascade's depth map, in texels. Clamped to 256 through 8192. |
| `cascades` | `4` | The number of cascades. Clamped to 1 through 4. |
| `softness` | `.pcf` | The filter: `.hard`, `.pcf` or `.pcss`. See section 5. |
| `maxDistance` | `120` | The distance at which shadows end, in world units. |
| `depthBias` | `0.0015` | A depth offset applied to the shadow comparison, scaled by the surface's slope. |
| `normalBias` | `0.02` | An offset along the surface normal, which grows with the cascade index. |
| `localShadowSlices` | `12` | Slices for point and spot shadows. A spot light takes one, a point light six. 0 turns local shadows off. At most 64. |
| `localResolution` | `512` | The side length of each local shadow slice, in texels. Clamped to 64 through 4096. |

The cascades are built as follows:

1. The far distance is the smaller of the camera's `far` and `maxDistance`, and at least the near distance plus one.
2. `RenderMath.cascadeSplits(near:far:count:)` divides that range into `count` slices.
3. For each slice, `RenderMath.frustumSliceCorners` finds the eight corners of the slice, and `RenderMath.stableCascadeMatrix` builds a light-space projection that encloses them. The matrix is stabilised, so that moving the camera does not make the shadow edges shimmer.
4. The projection is built from the camera's unjittered view-projection, so temporal anti-aliasing jitter does not move the cascades.

Each cascade is rendered in its own depth-only pass into one slice of a `depth32Float` two-dimensional array texture. The pass uses standard depth, with a clear value of 1 and the `less` comparison. It sets a slope-scaled hardware depth bias of 1.5, with a clamp of 0.01, in addition to the shader biases.

When a surface is shaded, the renderer chooses the cascade whose split contains the surface's view depth. The surface position is offset along its normal by `normalBias`, multiplied by one plus the cascade index. The depth is offset by `depthBias`, scaled by one plus twice a slope term that is zero for surfaces facing the light. A point outside the cascade's map is treated as lit.

When ray-traced shadows are active, the cascades are not built, and the shading reads the ray-traced shadow buffer instead. See [11-Ray-Tracing.md](11-Ray-Tracing.md).

```swift
var shadows = GraphicsSettings().shadows
shadows.resolution = 4096
shadows.cascades = 3
shadows.maxDistance = 80
shadows.softness = .pcss
var settings = GraphicsSettings()
settings.shadows = shadows
```

## 5. Shadow filtering

Every shadow lookup goes through `sampleShadow` in `Mesh.metal`. The filter depends on `softness`.

| `softness` | Samples | Behaviour |
| --- | --- | --- |
| `.hard` | One comparison, with a nearest-filtered sampler. | Sharp, aliased edges. The cheapest mode. |
| `.pcf` | Nine comparisons, in a 3 by 3 grid of one-texel spacing. | Soft edges with a fixed width. |
| `.pcss` | A 5 by 5 blocker search, then nine comparisons whose spacing depends on the penumbra estimate. | The penumbra widens with the distance between the occluder and the receiver. The radius is clamped to between 1 and 6 texels. |

`ScenePasses` sets the frame flag `hardShadows` for `.hard` and `pcss` for `.pcss`. PCSS applies to the sun only; point and spot shadows use the hard or PCF filter.

The source describes the PCSS path as simplified: it estimates the penumbra from an average of occluder depths, with a fixed scale. It is not the full algorithm from the original paper.

**Point and spot shadows.** `LocalShadowPlanner` (in `LocalShadows.swift`, which has no Metal code and is unit-tested) assigns slices of one `depth32Float` 2D array:

- Candidates are taken nearest first. A spot light takes one slice, projected through its cone with a small margin. A point light takes six, one per cube face, each with a field of view slightly wider than 90° so the filter kernel stays inside the face.
- A point light that does not fit in the remaining slices is skipped, and a later spot light may still fit. Lights that get no slice are lit without shadows.
- Each served light records its first slice, the texel size and a normal-offset factor in `LightData.extra`. The shader picks a point light's face from the dominant axis of the light-to-surface vector.

Each slice is rendered like a cascade: standard depth, cleared to 1, the `less` comparison and a slope bias of 1.5. Casters are culled against the light's sphere. Shadow maps are skipped during reflection-probe capture.

**Receivers.** `MeshRenderer.receivesShadows` and `SkinnedMeshRenderer.receivesShadows` default to `true`. When `false`, the instance ignores the sun, local and ray-traced shadows. It still casts shadows if `castsShadows` is set.

## 6. Sky and image-based lighting

`Environment` holds the sky and the ambient terms for the scene. It is a component, and one environment per scene is expected.

| Field | Default | Effect |
| --- | --- | --- |
| `sky` | `.procedural(sunDirection:turbidity:)`, sun from (0.3, 0.8, 0.4), turbidity 2.5 | The sky. The cases are `.procedural`, `.texture(AssetID)` and `.color(Color)`. |
| `iblIntensity` | `1` | Scales the image-based lighting. |
| `skyIntensity` | `1` | Scales the sky's brightness as seen by the camera. |
| `ambientColor` | (0.03, 0.03, 0.035) | A constant ambient term, added to the lighting. |

A procedural sky is generated on the GPU. When a sun light exists, the sky uses its direction, so the sky and the sun stay consistent. The sun's direction is quantised to about a quarter of a degree before the cache is checked, so a slowly moving sun regenerates the sky occasionally rather than every frame.

`EnvironmentLighting` turns the sky into three resources:

| Resource | Size | Use |
| --- | --- | --- |
| Environment cube | 256 by 256 per face, mipmapped | The source of the other two. |
| Irradiance cube | 32 by 32 per face | Diffuse lighting, from a convolution of the environment. |
| Prefiltered cube | 128 by 128 per face, 6 mip levels | Specular lighting. Each mip corresponds to a roughness level. |
| BRDF lookup table | 256 by 256, two-channel half-precision float | The split-sum term for the specular lookup, computed once. |

The resources are regenerated only when the sky definition changes, as recorded by a key that includes the mode, the quantised sun direction, the turbidity, the texture and the colour. Regeneration is a few compute passes on the frame's command buffer.

The sky itself is drawn only for perspective cameras, in the main pass after the opaque geometry. It is not drawn for orthographic cameras, which show `clearColor`.

A `.texture` sky uses an equirectangular or cube texture asset. It is loaded like any other texture. A `.color` sky fills the environment with one colour, which gives uniform image-based lighting.

## 7. Fog and ambient light

Fog is exponential, with no height dependence. In the mesh shader, the fragment's colour is blended towards `fogColor` by a factor of `1 − exp(−fogDensity × viewDepth)`, clamped to [0, 1]. The fog term is applied only if `fogDensity` is above 0.

```swift
var environment = Environment()
environment.fogDensity = 0.02
environment.fogColor = Color(0.6, 0.7, 0.8)
environment.ambientColor = Color(0.05, 0.05, 0.06)
world.add(environment, to: environmentEntity)
```

The frame uniforms carry the ambient colour together with `iblIntensity`, and the fog colour with the density. The shader's use of the ambient term is part of the lighting equation and is not described further here.

The 2D layer reads `ambientColor` as the ambient term when 2D lights are in view. See [07-Rendering-2D.md](07-Rendering-2D.md), section 11.

## 8. Reflection probes

A `ReflectionProbe` captures the surroundings of its position into a prefiltered cube, so that nearby surfaces reflect their environment rather than only the sky.

| Field | Default | Effect |
| --- | --- | --- |
| `resolution` | `128` | The requested face size in texels. All probes share one size; see below. |
| `extents` | (10, 10, 10) | The half-size of the influence box, in world units. |
| `boxProjection` | `true` | Box projection, intended to correct the reflection direction for the probe's box. The field comment calls the extents the influence volume for box projection. |
| `realtime` | `false` | Captures the probe every frame, one probe at a time, instead of once. |
| `revision` | `0` | Increment to request a new capture. |

The renderer holds at most 16 probes, `ReflectionProbes.maxProbes`. A probe beyond that is ignored, and a warning is logged. All probes live in one cube-map array, so they share one face size, `ReflectionProbes.faceSize`. It is the largest `resolution` among the probes, rounded up to a power of two and clamped to 32 through 256 (`RenderMath.probeFaceSize`). With no probes, the size stays where it was, 128 at start. When the size changes, the array is reallocated and every probe is re-captured. If the allocation fails, the renderer keeps the previous size and does not retry that size.

The capture scheduler runs at most one capture per frame. It takes the first probe that has never been captured, or whose `revision` has changed. If none needs a capture, it takes the next probe with `realtime` set, in turn.

A capture renders the scene from the probe's position, with shadows, GPU culling, occlusion culling and ray tracing turned off. The source describes this as cheap lighting for captures. It then prefilters the result into the probe's slot of the probe array.

When a surface lies inside more than one probe's box, the innermost probe wins. There is no blending between probes. The surface shader samples the single probe that is chosen.

```swift
let room = world.createEntity(named: "Room", transform: Transform(position: Vec3(0, 2, 0)))
var probe = ReflectionProbe()
probe.extents = Vec3(6, 3, 6)
probe.boxProjection = true
world.add(probe, to: room)

// After moving furniture or changing lights, request a fresh capture:
world.modify(ReflectionProbe.self, room) { $0.revision &+= 1 }
```

## 9. Validation status

- The light selection, the cascade construction, the shadow filters and the probe limits were read from the Swift and Metal sources. They have not been run.
- The numeric values in this document are those in the source (defaults, clamps, sizes). They are not measurements.
- The examples' intensities are illustrative, as stated in section 1.
- Image quality, shadow acne, and the visual behaviour of PCSS, point and spot shadows and box projection have not been observed on hardware.

## 10. Limitations

- **Limitation: local shadows are budgeted.** Only as many point and spot lights as `localShadowSlices` allows are shadowed, nearest first. The rest are lit without shadows, so a light's shadow can switch off as the camera moves away from it.
- **Limitation: no PCSS for local lights.** `.pcss` softens only the sun; point and spot shadows use PCF.
- **Limitation: one set of cascades.** Only one directional light gets shadow maps, so a scene with two suns shadows one of them.
- **Limitation: PCSS is simplified.** The blocker search uses a fixed 5 by 5 pattern, and the penumbra scale is a constant.
- **Limitation: probes share one face size.** The face size is the largest `ReflectionProbe.resolution` among the probes, rounded up to a power of two and clamped to 32–256. Changing it re-captures every probe.
- **Limitation: at most 16 reflection probes.** Further probes are not captured or drawn.
- **Limitation: no blending between probes.** The innermost probe wins, so the chosen probe changes abruptly at a boundary.
- **Limitation: at most 64 lights per cluster.** Lights beyond the cluster's limit are dropped for the pixels in that cluster.
- **Limitation: at most 1024 punctual lights per frame.** The nearest are kept.
- **Limitation: fog is not height-dependent.** Only the exponential density applies.
- **Limitation: the sky is not drawn for orthographic cameras.** They show `clearColor`.

## 11. Related documents

- [07-Rendering-2D.md](07-Rendering-2D.md): the 2D lights, which are separate from these.
- [08-Rendering-3D.md](08-Rendering-3D.md): the frame, the clustered and forward paths, and the presets for shadow resolution.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md): exposure, tone mapping and ambient occlusion, which act on the lit image.
- [11-Ray-Tracing.md](11-Ray-Tracing.md): ray-traced shadows and reflections, which replace some of the techniques here.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): the components and their storage.
