# 2D Rendering

Ferox draws 2D content in the same HDR pass as 3D content. Sprites, shapes, tilemaps, 2D lights, stencil masks and, for orthographic cameras, CPU particles are gathered from the world, sorted, tessellated on the CPU into one indexed vertex stream, and split into draw calls only where the render state changes. This document describes the components, the sort and batch rules, masks, tilemaps, the 2D camera and 2D lights, and the colour settings a 2D game needs. The batching code is in `Sources/FeroxRender/SpriteBatcher.swift`, and the shader is `Sources/FeroxRender/Shaders/Sprite.metal`. The component data is in `Sources/FeroxScene/RenderComponents.swift`. The 3D path is in [08-Rendering-3D.md](08-Rendering-3D.md).

## Contents

1. [Where 2D sits in the frame](#1-where-2d-sits-in-the-frame)
2. [Components](#2-components)
3. [Sorting](#3-sorting)
4. [Batching](#4-batching)
5. [Sprites and atlases](#5-sprites-and-atlases)
6. [Shapes](#6-shapes)
7. [Stencil masks](#7-stencil-masks)
8. [Tilemaps](#8-tilemaps)
9. [The 2D camera](#9-the-2d-camera)
10. [Parallax](#10-parallax)
11. [2D lights](#11-2d-lights)
12. [Colour for 2D games](#12-colour-for-2d-games)
13. [Validation status](#13-validation-status)
14. [Limitations](#14-limitations)
15. [Related documents](#15-related-documents)

## 1. Where 2D sits in the frame

Inside the main HDR pass, the renderer encodes these steps in order:

1. opaque 3D geometry;
2. the sky, for perspective cameras only;
3. transparent 3D geometry;
4. particles;
5. the 2D layer: sprites, shapes and tilemaps, through `SpriteBatcher.build` and `overlays.encodeSprites`;
6. debug lines;
7. the `afterTransparent` render hooks.

The 2D layer therefore draws over the 3D scene of the same frame, and it goes through the same tone mapping, anti-aliasing and upscaling as 3D. A 2D game does not need a separate renderer, but it should choose a tone mapper. See section 12.

## 2. Components

| Component | Purpose | Notable fields and defaults |
| --- | --- | --- |
| `SpriteRenderer` | A textured quad. | `texture`, `uvRect` (`.unit`), `size` (`nil`), `pixelsPerUnit` (100), `pivot` (0.5, 0.5), `color`, `flipX`, `flipY`, `sortingLayer`, `orderInLayer`, `blend` (`.alpha`), `filter` (`.linear`), `normalMap`, `isMask`, `maskID` (0), `receives2DLighting` (`false`). |
| `ShapeRenderer` | An untextured shape, tessellated on the CPU. | `shape`, `fill` (a `Gradient`), `strokeWidth` (0), `strokeColor`, `sortingLayer`, `orderInLayer`. |
| `Tilemap` | A grid of tiles from a tileset. | `tileset`, `tilesetColumns`, `tilesetRows`, `width`, `height`, `tileSize` (1, 1), `tiles`, `sortingLayer`, `color`, `revision`, `solidTiles`. |
| `Parallax` | Scales how far a layer follows the camera. | `factor` (a `Vec2`). |
| `Light` | A 2D light when `is2D` is `true`. | `type`, `color`, `intensity`, `range`, cone angles, `is2D`. |
| `Camera` | An orthographic camera. | `projection` (`.orthographic`), `orthographicSize`, `near`, `far`, `pixelPerfect`, `pixelsPerUnit` (16), `clearColor`, `cullingMask`, `priority`. |

`SpriteRenderer.size` is in world units. When it is `nil`, the size is derived from the texture's frame size and `pixelsPerUnit`, as the field comment states. `SpriteRenderer.uvRect` is the sub-rectangle of the texture in normalised coordinates, which is how an atlas frame is selected.

A 2D entity uses the same `Transform` and hierarchy as a 3D entity. Only the x and y components of its world matrix are used for placement. The z component of the world position is used for the 2D light height and for the depth of 2D lights. See section 11.

## 3. Sorting

`SpriteBatcher.build` gathers a drawable for every visible sprite, shape, tilemap and, for orthographic cameras, CPU particle emitter. It sorts them by:

1. `sortingLayer`, ascending;
2. `orderInLayer` for sprites and shapes, or the order `Int.min` for tilemaps, ascending;
3. the entity index, ascending;
4. the order in which the drawables were gathered, as the final tie-break: sprites, then shapes, then tilemaps, then particle emitters. So a sprite and a shape on the same entity, with the same layer and order, always draw sprite first.

Within a sorting layer, a tilemap draws beneath every sprite and shape, because its order is the lowest possible value. Among sprites and shapes, the higher `orderInLayer` draws on top.

An entity is visible when it is active in its hierarchy and its `Layer` is in the camera's `cullingMask`. An entity with no `Layer` is on layer 0, the default.

```swift
var background = SpriteRenderer(texture: sky)
background.sortingLayer = 0
background.orderInLayer = -10          // drawn first within layer 0

var hero = SpriteRenderer(texture: heroFrame)
hero.sortingLayer = 1
hero.orderInLayer = 5                  // above the tilemap of layer 1
```

## 4. Batching

Each drawable is turned into triangles in one shared vertex array, and the indices are appended to one shared index array. `SpriteBatcher.BatchEmitter` then starts a new batch whenever any of these change from one drawable to the next:

- the texture;
- the normal map;
- the blend mode;
- the filter;
- the stencil state.

A batch is a contiguous range of the index array, described by a `SpriteBatch`, which is one 2D draw call. Sprites that share an atlas, a blend mode and a filter therefore draw in a single call, provided no other kind of drawable is sorted between them. Sorting by layer and order decides the batch breaks, so an atlas shared by sprites on alternating layers produces more batches than one shared by sprites in a single layer.

The shader `spriteVertex`, `spriteFragment` and `spriteMaskFragment` in `Sprite.metal` draws every batch. The file header says one pipeline per blend mode covers the whole 2D layer. The colour values are premultiplied linear.

Batching is performed on the CPU, every frame, for every visible drawable. The source does not report a cost for it. `SpriteFrameData` holds the batches, vertices and indices of a frame, and `RenderFrameStatistics.spritesDrawn` counts the drawables that were drawn.

## 5. Sprites and atlases

A sprite samples one texture. A texture atlas packs several frames into one texture, and `uvRect` selects the frame.

```swift
let atlas = AssetID("hero.atlas")                  // registered or loaded as a texture asset
var frame = SpriteRenderer(texture: atlas, size: Vec2(1, 1.5))
frame.uvRect = Rect(x: 0.25, y: 0.5, width: 0.25, height: 0.25)   // normalised, in the atlas
frame.pivot = Vec2(0.5, 0)                         // pivot at the feet
frame.filter = .nearest                            // crisp pixel art
frame.blend = .alpha
frame.flipX = true                                 // face left
world.add(frame, to: hero)
```

The blend modes are `alpha`, `additive`, `multiply`, `premultiplied` and `opaque`. Each is a separate pipeline state, so a sprite set that changes blend mode often produces more batches.

The filter is `nearest` or `linear`. For pixel art, use `nearest`. The default is `linear`.

Textures are obtained through `AssetManager`. See [18-Assets.md](18-Assets.md).

## 6. Shapes

A `ShapeRenderer` draws one of five shapes. The shapes are tessellated on the CPU, and drawn with the built-in white texture, so they batch with other untextured drawables.

| Case | Meaning |
| --- | --- |
| `.rectangle(size:cornerRadius:)` | A rectangle, with optional rounded corners. |
| `.circle(radius:segments:)` | A circle with the given number of segments. |
| `.polygon(points:)` | A polygon from its points. |
| `.line(from:to:)` | A line segment. |
| `.polyline(points:closed:)` | A chain of segments, optionally closed. |

```swift
var panel = ShapeRenderer(.rectangle(size: Vec2(3, 1), cornerRadius: 0.15),
                          color: Color(0.25, 0.3, 0.38))
panel.strokeWidth = 0.05                           // in world units
panel.strokeColor = Color(0.45, 0.55, 0.7)
panel.orderInLayer = 2
world.add(panel, to: menu)
```

The fill is a `Gradient`. `ShapeRenderer(_:color:)` sets a gradient whose two ends are the same colour, so a flat colour is the default.

The platformer example draws every visual this way, so it needs no image files. See [02-Getting-Started.md](02-Getting-Started.md), section 3.

## 7. Stencil masks

A sprite can write into the stencil buffer, and another sprite can draw only where the stencil has a given value. The mask is a sprite, so a window, a spotlight or a reveal effect is a texture with alpha.

- A sprite with `isMask` set writes its `maskID` into the stencil wherever its alpha passes a cut-off. It writes no colour. A `maskID` of 0 is changed to 1 when the mask is written.
- A sprite with a non-zero `maskID` and `isMask` clear is drawn only where the stencil equals that `maskID`.
- A sprite with `maskID` 0 is drawn everywhere.

The values 1 to 255 are available, because the stencil is 8 bits. The stencil lives in the depth-stencil format, `depth32Float_stencil8`, which the main depth target uses.

```swift
var window = SpriteRenderer(texture: windowShape)
window.isMask = true
window.maskID = 1
world.add(window, to: windowEntity)

var water = SpriteRenderer(texture: waterTexture, size: Vec2(8, 8))
water.maskID = 1                                   // drawn only inside the window
world.add(water, to: waterEntity)
```

A mask draws in the order given by its sorting layer and order, like any other sprite. A masked sprite must come after its mask in that order, because the stencil is written as the batches are drawn in sequence. The sort rules in section 3 decide this.

`SpriteFrameData.usesStencil` reports whether any batch in the frame writes or tests the stencil.

## 8. Tilemaps

A `Tilemap` is a grid of tile indices, drawn from a tileset. The tileset is a texture divided into `tilesetColumns` by `tilesetRows` equal cells. A tile index `i` selects the cell at column `i mod columns` and row `i div columns`, and `uvRect(for:)` returns that cell. The index `-1` is an empty tile.

```swift
var map = Tilemap(tileset: AssetID("tiles.set"), columns: 8, rows: 8, width: 32, height: 16)
map.tileSize = Vec2(1, 1)
for x in 0..<32 {
    map[x, 0] = 3                 // ground row; each write increments the revision
}
map.solidTiles = [3]             // tiles that generate static colliders
world.add(map, to: level)
```

The subscript setter ignores coordinates outside the map. Writing a tile increments `revision`, and the renderer rebuilds only the chunks that changed. The `tiles` array is row-major, with the bottom row first.

The tilemap is drawn in chunks of 16 by 16 tiles. Each chunk has a bounding box, and chunks outside the camera's frustum are skipped. The tessellated chunks are cached per entity, keyed by the revision and a signature of the size and tileset layout. A tilemap that is destroyed or hidden loses its cache entry on the next frame, so the cache does not grow.

`solidTiles` is read by the physics layer. `TilemapCollider` builds static boxes from it, merged by row, and rebuilds them when `revision` changes. See [13-Physics.md](13-Physics.md).

## 9. The 2D camera

An orthographic camera shows a rectangle of the world. Its half-height is `orthographicSize`, in world units, and its width follows the view's aspect ratio.

```swift
let camera = world.createEntity(named: "Camera", transform: Transform(position: Vec3(0, 2, 10)))
var cam = Camera.orthographic(size: 7)             // half-height of 7 world units
cam.clearColor = Color(0.07, 0.08, 0.12)
cam.pixelPerfect = true                            // snap to whole texels
cam.pixelsPerUnit = 16                             // texels per world unit
world.add(cam, to: camera)
```

`Camera.orthographic(size:near:far:)` defaults `near` to -100 and `far` to 100, which suit a 2D scene placed on the z = 0 plane.

When `pixelPerfect` is set on an orthographic camera, its position is rounded to whole texels, using `pixelsPerUnit`, before the view matrix is built. This prevents shimmering at sub-texel positions. The sprite uniforms also carry the flag. A perspective camera ignores `pixelPerfect`.

The camera is chosen by the same rule as in 3D: the enabled camera with the highest `priority`. `Camera.cullingMask` decides which layers it draws.

## 10. Parallax

A `Parallax` component shifts an entity's rendered position by the camera's position, scaled by `1 - factor`. The shift is a translation only, and it does not change the `Transform`. When the camera moves by a distance `d`, the entity moves across the screen by `factor × d`, in the opposite direction to the camera.

| `factor` | Behaviour |
| --- | --- |
| `1` | Fixed in the world. The entity moves across the screen as an ordinary world object does. |
| `0` | Fixed to the screen. The entity stays where it is while the camera moves, which suits a very distant background. |
| between 0 and 1 | Moves across the screen at that fraction of the speed of a world object. Values near 0 suggest distance. |

```swift
var backdrop = world.createEntity(named: "Backdrop")
world.add(SpriteRenderer(texture: hills, size: Vec2(40, 12)), to: backdrop)
world.add(Parallax(Vec2(0.2, 0.2)), to: backdrop)   // far away: moves slowly across the screen
```

`Parallax.factor` has two components, so x and y can differ. The shift uses the camera's x and y position only.

## 11. 2D lights

A 2D light is a `Light` with `is2D` set. Only point and spot lights are used in 2D. A directional light with `is2D` set is ignored by the 2D path.

- The light's position is its world x and y, and its radius is `range`.
- Its height above the sprite plane is the absolute value of its z position. A light on the plane (z near 0) uses a quarter of its range as the height.
- A spot light has a cone direction, taken from its forward vector, and an outer cone angle.
- A light is included only if its bounding square intersects the camera's frustum, and only if its `intensity` is above 0.
- At most 64 lights are used in a frame. If there are more, the nearest to the camera are kept.

A sprite takes part in 2D lighting only if its `receives2DLighting` flag is set. A sprite's normal map is part of its batch key, so sprites with different normal maps are drawn in separate batches. The batcher sets the ambient term to 1 when no 2D light is in view, and to the environment's `ambientColor` when at least one light is in view.

```swift
let lamp = world.createEntity(named: "Lamp", transform: Transform(position: Vec3(3, 2, 1)))
var light = Light(type: .point, color: Color(1, 0.8, 0.5), intensity: 2, range: 6)
light.is2D = true
world.add(light, to: lamp)

var wall = SpriteRenderer(texture: wallTexture, size: Vec2(4, 4))
wall.receives2DLighting = true
world.add(wall, to: wallEntity)
```

The 2D lights do not cast shadows. The 3D shadow code does not apply to them.

## 12. Colour for 2D games

The default `PostProcessSettings.toneMapper` is `.agx`, which applies a curve to every pixel of the HDR image before presentation. Art authored in display colours looks different under that curve. `Platformer2D` sets `config.graphics.post.toneMapper = .none` for this reason:

```swift
var config = EngineConfiguration(title: "My 2D Game")
config.physics3D = false
config.graphics.post.toneMapper = .none        // 2D art is authored in display colours
```

With `.none`, the tone operator is a clamp, with no curve. The rest of the grading still runs. The default vignette, `colorGrading.vignette` at 0.15, darkens the edges of the frame, and the output is encoded to sRGB. A 2D game that needs exact colours sets `colorGrading.vignette` to 0 as well. See [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md).

## 13. Validation status

- The batching rules, the sort order and the chunking were read from `SpriteBatcher.swift`. The source comment says they are unit-tested on Linux. Those tests are not in this snapshot, so the statements are not checked here.
- The stencil values were read from `depthStencilState` in `OverlayPasses.swift` and from the `SpriteStencil` enum.
- No frame has been rendered, and no batch count has been measured.

## 14. Limitations

- **Limitation: the 2D layer is CPU-batched.** Every visible drawable is tessellated on the CPU each frame. The source gives no cost figure. Very large sprite counts should be measured. See [21-Performance.md](21-Performance.md).
- **Limitation: at most 64 2D lights.** The shader loops over at most 64. Lights beyond that are dropped, nearest first.
- **Limitation: no shadows for 2D lights.** Lights add to sprites without occlusion.
- **Limitation: pixel-perfect only for orthographic cameras.** A perspective camera ignores `pixelPerfect`.
- **Limitation: the camera viewport is not honoured.** `Camera.viewport` is not read by the renderer, so split-screen and picture-in-picture are not supported. Its comment in `RenderComponents.swift` describes intended use.
- **Limitation: one camera per frame.** The renderer draws the highest-priority camera only. See [08-Rendering-3D.md](08-Rendering-3D.md).
- **Limitation: CPU particles only in orthographic views.** A `ParticleEmitter` with `simulation` set to `.cpu` is drawn in the 2D layer only when the active camera is orthographic. GPU particles are not drawn by the 2D layer.
- **Limitation: a mask must be sorted before its masked sprites.** The stencil is written in draw order. A masked sprite drawn before its mask is not drawn at all, because the stencil is still clear when it is tested.

## 15. Related documents

- [03-Architecture.md](03-Architecture.md): where the 2D layer sits in the frame.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): the components, layers and the render components.
- [08-Rendering-3D.md](08-Rendering-3D.md): the main pass that the 2D layer shares.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md): the tone mappers and their order.
- [13-Physics.md](13-Physics.md): tilemap colliders.
- [18-Assets.md](18-Assets.md): textures and atlases.
