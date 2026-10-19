# Assets

The assets module (`FeroxAssets`) finds the files in a project, gives each one a stable identifier, imports them into runtime data, and loads them on background threads. It covers textures, glTF models, materials, sprite atlases, Tiled maps and raw files. Its `AssetDatabase` tracks source files and their `.meta` sidecars, and detects changes. Its `AssetManager` loads on a worker queue, delivers results on the main thread, substitutes placeholders for broken files, and evicts unused textures under a memory budget. This document describes the implementation in `Sources/FeroxAssets`, the formats it accepts, and how to extend it.

The identifier type `AssetID` is defined in `FeroxCore`. Scenes and components refer to assets by `AssetID`, so the identifiers in `.meta` files must be kept. Animation clips and skeletons produced by import are described in [17-Animation-and-Particles.md](17-Animation-and-Particles.md). Scene files and prefabs are described in [06-Scene-and-Entities.md](06-Scene-and-Entities.md), and rendering of textures and meshes in [08-Rendering-3D.md](08-Rendering-3D.md).

## Contents

1. [Pipeline overview](#1-pipeline-overview)
2. [Asset identity and kinds](#2-asset-identity-and-kinds)
3. [The asset database](#3-the-asset-database)
4. [The asset manager](#4-the-asset-manager)
5. [Supported formats](#5-supported-formats)
6. [The glTF importer](#6-the-gltf-importer)
7. [Images](#7-images)
8. [Meshes and materials](#8-meshes-and-materials)
9. [Sprite atlases and Tiled maps](#9-sprite-atlases-and-tiled-maps)
10. [Built-in assets and model instantiation](#10-built-in-assets-and-model-instantiation)
11. [Code examples](#11-code-examples)
12. [Extending the pipeline](#12-extending-the-pipeline)
13. [Troubleshooting](#13-troubleshooting)
14. [Licensing third-party assets](#14-licensing-third-party-assets)
15. [Limitations and discrepancies](#15-limitations-and-discrepancies)
16. [Related documents](#16-related-documents)

## 1. Pipeline overview

```text
Project directory
   |  AssetDatabase.refresh()        scan, read or create .meta, hash, find dependencies
   v
AssetDatabase (ids, paths, kinds, dependencies)
   |  AssetManager.texture / model / material / atlas / data
   v
Worker queue (concurrent)           read bytes, decode, import, cache
   |  completion pushed to a thread-safe queue
   v
AssetManager.update()  (main thread, once per frame)
   -> AssetHandle state, value and revision; callbacks; hot-reload scan; budget enforcement
```

Loads never block the caller. A request returns an `AssetHandle` in the `loading` state, and its value appears in a later `update()`. Hot reload runs the same scan on a background queue and reloads changed assets, and the dependents of changed assets, on the main thread.

## 2. Asset identity and kinds

An `AssetID` is a string wrapper, encoded in JSON as a single string. It is stable when it comes from a `.meta` file.

- `AssetID()` makes a new random identifier, as a lowercase UUID string. The database uses this when it first sees a file without a `.meta`.
- `AssetID.derived(fromPath:)` makes a deterministic identifier from a project-relative path, with the form `path-<hex>`. It is a fallback for an atlas's image when the database has not yet indexed that image.
- Built-in identifiers use readable names such as `ferox/mesh/cube` (see [section 10](#10-built-in-assets-and-model-instantiation)).

`AssetKind.infer(fromExtension:)` maps a file extension to a kind. Matching is case-insensitive. Files with unknown extensions are not indexed.

| Kind | Extensions |
| --- | --- |
| `texture` | `png`, `jpg`, `jpeg`, `tga`, `bmp`, `tif`, `tiff`, `heic`, `hdr`, `exr`, `ktx`, `ktx2` |
| `model` | `gltf`, `glb` |
| `material` | `fxmat` |
| `audio` | `wav`, `aif`, `aiff`, `caf`, `mp3`, `m4a`, `aac`, `flac` |
| `font` | `ttf`, `otf`, `ttc` |
| `shader` | `metal` |
| `spriteAtlas` | `fxatlas`, `atlas` |
| `tilemap` | `tmj`, `fxtilemap` |
| `scene`, `prefab`, `animation` | `fxscene`, `fxprefab`, `fxanim` |
| `unknown` | Everything else. Not indexed. |

Classifying an extension does not mean a loader exists. See [section 5](#5-supported-formats).

## 3. The asset database

`AssetDatabase(root:)` indexes a project directory. Each indexed file has a `.meta` sidecar next to it, named by appending `.meta` to the file name (for example `hero.png.meta`). The sidecar holds the stable `AssetID` that scenes reference. Commit sidecar files to version control. Without them, identifiers are regenerated on a new machine.

### The `.meta` format

`AssetMeta` is encoded as sorted, pretty-printed JSON. Its fields are `version` (currently 1), `id`, `kind`, `settings`, `dependencies`, `sourceHash` and `labels`. The `settings` object has three parts, `texture`, `model` and `audio`, and each has the defaults shown below.

```json
{
  "dependencies" : [
    "hero/hero_sheet.png"
  ],
  "id" : "6f1d3b9e-2c4a-4d7b-9a3e-1f2b3c4d5e6f",
  "kind" : "spriteAtlas",
  "labels" : [],
  "settings" : {
    "audio" : { "loop" : false, "stream" : false },
    "model" : {
      "generateTangents" : true,
      "importAnimations" : true,
      "importCameras" : false,
      "importLights" : true,
      "scale" : 1
    },
    "texture" : {
      "filter" : "linear",
      "generateMips" : true,
      "isCubemap" : false,
      "maxSize" : 0,
      "wrap" : "repeatWrap"
    }
  },
  "sourceHash" : "a1b2c3d4e5f60718",
  "version" : 1
}
```

Texture `srgb` is optional. When it is absent, colour space is decided at load time. The example is illustrative: the values shown are the ones a new sidecar receives, except `id` and `sourceHash`, which are generated.

### Change detection

`refresh()` scans the project and returns a `Changes` value with `added`, `modified`, `removed` and `invalidated`. Detection has two stages:

1. **Cheap check.** If a known file has the same size and modification date as before, it is skipped.
2. **Content check.** Otherwise the file is hashed with FNV-1a 64 and compared with `sourceHash` in the sidecar. Only a different hash counts as `modified`. Touching a file does not re-import it.

`invalidated` is the set of modified assets together with every asset that depends on them, transitively. The database finds dependencies while scanning:

| Kind | Dependencies recorded |
| --- | --- |
| glTF (`.gltf` only) | URIs of buffers and images. Binary `.glb` files are self-contained and record none. |
| Sprite atlas | The image named by `meta.image` or `texture`. |
| Tilemap | The images of the tilesets. |
| Material | The textures named in the `.fxmat` file, that the database has indexed. |

`dependents(of:)` returns the assets that depend on a given asset. `updateSettings(_:_:)` rewrites a sidecar with new import settings. It does **not** change `sourceHash` or clear any cache (see [section 15](#15-limitations-and-discrepancies)).

`writesMetaFiles` (true by default) controls whether sidecars are written. Turn it off for read-only builds.

### The cache

Cached products go in `.ferox-cache/` under the project root, one file per asset and suffix. Each file begins with a 64-byte header, `FXCACHE1 <sourceHash>`, padded with spaces. A cache entry is used only if its header matches the current `sourceHash`. Today only imported glTF models are cached, with the suffix `model`. The binary format starts with a version number of 1, followed by a JSON header, the meshes, and the embedded images.

## 4. The asset manager

`AssetManager(database:budget:)` is the runtime loader. Its main entry points are:

| Method | Returns | Notes |
| --- | --- | --- |
| `texture(_:srgb:)` | `AssetHandle<ImageData>` | Starts a load if none exists. |
| `model(_:)` | `AssetHandle<LoadedModel>` | glTF or cached model. |
| `material(_:)` | `AssetHandle<MaterialData>` | Reads `.fxmat` JSON. |
| `atlas(_:)` | `AssetHandle<SpriteAtlas>` | Ferox or TexturePacker JSON. |
| `data(_:)` | `AssetHandle<Data>` | Raw bytes, for any kind. |
| `mesh(_:)` | `AssetHandle<MeshData>?` | Registered meshes only. Does not load. |
| `registerTexture(_:id:)`, `registerMaterial(_:)`, `registerMesh(_:id:)` | Handle | Adds an in-memory asset. |
| `update()` | Void | Call once per frame on the main thread. |
| `waitForPendingLoads()` | Void | Blocks until pending work finishes. For tools and tests. Do not call it on a render thread. |

`AssetHandle` has an `id`, a `state` (`unloaded`, `loading`, `loaded` or `failed(String)`), a `value`, and a `revision` that is incremented on every load, including reloads and failures. `isLoaded` is true only in the `loaded` state.

`whenLoaded(_:)` runs its closure at once if the asset is loaded, and otherwise stores it. **The stored closure also runs when the load fails**, so check `state` inside the closure (see [section 15](#15-limitations-and-discrepancies)).

### Placeholders

A missing or corrupt asset never crashes a load. The manager logs an error that names the asset, and stores a fallback value with a `failed` state:

| Asset | Fallback |
| --- | --- |
| Texture | Magenta and black checkerboard (`ImageData.checkerboard()`). |
| Model | A unit cube named `Missing(<id>)`, with the default material. |
| Material | `MaterialData.default`. |
| Atlas | An empty atlas with no frames. |
| Raw data | Empty `Data`. |

### Textures

- **Colour space.** The effective sRGB flag is the `srgb:` argument if given, otherwise `TextureImportSettings.srgb`, otherwise `true`. When the result is false, an sRGB format is changed to linear RGBA8.
- **Mips.** If `generateMips` is set (the default), a full box-filtered mip chain is built on the CPU for RGBA8 images. sRGB images are filtered in linear light.
- **Quality and size.** `TextureQuality.mipBias` drops that many top mips: `low` drops 2, `medium` drops 1, and `high` and `ultra` drop none. If `maxSize` is set, further mips are dropped until the width is no more than `maxSize`. Dropping only works when mips exist. See [section 15](#15-limitations-and-discrepancies).

### Models

A model is loaded from the database cache if the cache matches. Otherwise the glTF importer runs, the import settings are applied (scale, animations, lights and cameras), and the result is written to the cache. A `LoadedModel` holds the `ModelData` and a map from image index to texture identifier. Once loaded, embedded images are registered as in-memory textures named `<model>#image<N>`.

### Hot reload and callbacks

With `hotReload` set to true, `update()` starts a background scan every `hotReloadInterval` seconds (default 0.75). If the scan finds invalidated assets, `reload` restarts their loads. Each reloaded asset's `revision` increments, and `onReload` is called on the main thread with the identifiers. Reloading a texture starts it with no colour-space hint, even if the original `texture(_:srgb:)` call gave one.

### Memory budget

`MemoryBudget(textureBytes:meshBytes:audioBytes:)` has defaults of 1 GiB for textures, 256 MiB for meshes and 128 MiB for audio. Each `update()` checks the CPU-side texture total against `textureBytes`. If it is exceeded, textures in the `loaded` state are removed from the cache, least recently used first, **but only when no other code holds their handle**. The check uses `isKnownUniquelyReferenced`. A warning is logged if the budget is still exceeded afterwards. `meshBytes` is enforced for cached model assets. Least recently used loaded models that no other code references are evicted, and they reload on demand. Meshes registered in memory are never evicted by the asset manager. They are counted and a warning is logged if the budget is exceeded. The renderer's GPU mesh cache reads the same `meshBytes` value and drops idle, then least-recently-used, GPU meshes by their real buffer size. `Engine` hands `audioBytes` to the audio backend, which enforces it (see [16-Audio.md](16-Audio.md#3-loading-clips)). See [section 15](#15-limitations-and-discrepancies).

## 5. Supported formats

| Format | Support | Notes |
| --- | --- | --- |
| PNG, JPEG, HEIC, TIFF, BMP, GIF, TGA, OpenEXR, Radiance HDR | Loaded through ImageIO on Apple platforms, as the OS supports them. | LDR images decode to premultiplied RGBA8 (sRGB). HDR images decode to RGBA32 float. |
| Binary PPM (`P6`, 8-bit) and PFM (float RGB) | Built-in decoder, on every platform. | Intended for tests and tools. |
| KTX, KTX2 | Classified as textures. | No dedicated decoder in this module. Behaviour depends on ImageIO. |
| glTF 2.0 (`.gltf`, `.glb`) | Supported, within the limits in [section 6](#6-the-gltf-importer). | |
| `.fxmat` material | JSON encoding of `MaterialData`. | |
| `.fxatlas`, `.atlas` sprite atlas | Ferox JSON, or TexturePacker JSON (Hash and Array). | |
| `.tmj` Tiled map | First tile layer, first tileset, uncompressed data only. | |
| Audio, fonts, shaders | Raw bytes only, through `data(_:)`. | No typed loader. |
| `.fxscene`, `.fxprefab` | Loaded by scene code, not by this manager. | See [06-Scene-and-Entities.md](06-Scene-and-Entities.md). |
| `.fxanim` | Classified only. | No loader. |

## 6. The glTF importer

`GLTFImporter(limits:imageDecoder:)` parses `.gltf` files with external or data-URI buffers, and binary `.glb` files. Its doc comment lists these supported features:

- Triangle-list meshes with `POSITION`, `NORMAL`, `TANGENT`, `TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`, `JOINTS_0` and `WEIGHTS_0`.
- All accessor component types, including normalised integers, and byte strides.
- Metallic-roughness materials with textures. Extensions `KHR_materials_emissive_strength` and `KHR_materials_unlit`.
- `KHR_lights_punctual` lights.
- Node hierarchies, given as TRS or as a matrix. Cameras.
- Skins and animations, with `LINEAR`, `STEP` and `CUBICSPLINE` interpolation.

The importer is **not** able to handle these, and the doc comment says so:

- Sparse accessors.
- Draco and meshopt compression.
- Morph-target rendering. Morph weights are imported as animation channels only.
- Primitive modes other than triangles. Such primitives are skipped with a warning.
- `KHR_texture_transform`.

Only the three extensions `KHR_materials_emissive_strength`, `KHR_lights_punctual` and `KHR_materials_unlit` are accepted in `extensionsRequired`. Any other required extension fails the import with `unsupportedFormat`. Only glTF version 2.x is accepted.

Security and limits:

- Every external URI is resolved through `SafePath`, so absolute paths and `..` escapes are rejected.
- Accessor and buffer-view ranges are bounds-checked against their buffers.
- Element counts are capped by `DecodeLimits.maxElementCount` (50,000,000 by default), and file size by `maxFileBytes` (512 MiB by default).
- Node graphs with cycles, or with a node that has two parents, are rejected.
- Image dimensions are capped by `maxTextureDimension` (16,384 by default).

Import details the implementation applies:

- **Materials.** Missing `metallicFactor` defaults to 1, and missing `roughnessFactor` to 1. The material identifier is `<model>#material<N>`.
- **Images.** Images referenced as colour (base colour and emissive) keep their sRGB format. Other images are changed to linear RGBA8.
- **Meshes.** One `MeshData` per glTF mesh, with one submesh per primitive. Normals are generated if absent, and tangents if UVs are present and tangents are not.
- **Skins.** Joints are reordered so parents come first, and the skeleton stores the inverse bind matrices.
- **Animations.** Clips always loop. Morph weights become one float channel per target.

## 7. Images

`ImageDecoder.decode(_:_:limits:)` picks a decoder from the data. Binary PPM and PFM are detected from their magic bytes. Everything else goes to ImageIO on Apple platforms. On other platforms, it throws `unsupportedFormat` for anything except PPM and PFM.

- LDR images are decoded to premultiplied RGBA8 in sRGB.
- HDR images, detected by a bit depth above 8 with float components, are decoded to RGBA32 float in extended linear sRGB.
- Dimensions above `maxTextureDimension` are rejected before decoding.

`ImageData` stores `width`, `height`, `format`, `pixels`, optional `mips` and, for cubemaps, six `faces` (+X, −X, +Y, −Y, +Z, −Z). Colour is stored premultiplied. `generateMips()` only handles the two RGBA8 formats, so HDR textures never receive generated mips.

## 8. Meshes and materials

`MeshData` stores separate streams for `positions`, `normals`, `tangents` (xyz plus handedness in w), `uv0`, `uv1`, `colors`, `joints`, `weights` and `indices`. A stream is either empty or matches the vertex count. `validate()` checks stream lengths, that the index count is a multiple of three, that every index is in range, and that every submesh is inside the index buffer. Violations throw `corrupt`.

| Method | Effect |
| --- | --- |
| `generateNormals()` | Area-weighted smooth normals. |
| `generateTangents()` | Tangents from UV derivatives, orthogonalised against the normal. Needs normals and `uv0`. |
| `recomputeBounds()` | Bounding box from positions. |
| `MeshData.cube(size:)`, `sphere(radius:segments:rings:)`, `plane(size:subdivisions:)` | Primitives. |

`MaterialData` follows the glTF metallic-roughness model. Its fields include `shader` (`"pbr"`), `baseColor`, `baseColorTexture`, `metallic` (0), `roughness` (0.5), `metallicRoughnessTexture`, `normalTexture`, `normalScale`, `occlusionTexture`, `occlusionStrength`, `emissive`, `emissiveStrength`, `emissiveTexture`, `alphaMode` (`opaque`, `mask` or `blend`), `alphaCutoff` (0.5), `doubleSided`, `unlit`, `features`, `floatParameters` and `vectorParameters`.

A `.fxmat` file is `MaterialData` JSON. Because the decoder is synthesised, write a complete file, for example by encoding a `MaterialData` value. On load, the material's `id` is replaced by the asset's identifier.

## 9. Sprite atlases and Tiled maps

`SpriteAtlas` holds the texture identifier, the texture path, the atlas size and a list of `Frame` values. Each frame has a name, a normalised `uv` rectangle, a `pixelSize` and a `pivot`. `frame(named:)` looks up a frame, and `sequence(prefix:)` returns the frames whose names begin with a prefix, in natural order, for flipbooks.

`SpriteAtlas.grid(texture:texturePath:size:columns:rows:prefix:)` makes an atlas for a uniform grid. Frames are named `<prefix>_<index>`, row by row.

`SpriteAtlas.parse` accepts two JSON layouts. Both need an image name, a size and frames.

```json
{
  "frames": {
    "run_0": { "frame": { "x": 0, "y": 0, "w": 32, "h": 32 }, "pivot": { "x": 0.5, "y": 0.5 } },
    "run_1": { "frame": { "x": 32, "y": 0, "w": 32, "h": 32 } }
  },
  "meta": { "image": "hero.png", "size": { "w": 128, "h": 64 } }
}
```

- **Ferox and TexturePacker, Hash.** `frames` is an object keyed by name, sorted by key on load.
- **TexturePacker, Array.** `frames` is an array, and each name is taken from `filename`.
- The image is found under `meta.image` or `texture`, and the size under `meta.size` or `size`.

`TiledImporter.parse` reads a `.tmj` map. It takes the first tile layer and the first tileset, and requires uncompressed data. The flip bits of each tile ID are removed. Tiled stores rows from the top, and Ferox tilemaps store them from the bottom, so rows are reversed on import. Tile ID 0 becomes -1 (empty). Other IDs are offset by the tileset's `firstgid`.

## 10. Built-in assets and model instantiation

`BuiltinAssets` defines identifiers that exist without project files. They are `cube`, `sphere`, `plane`, `quad`, `whiteTexture`, `checkerTexture`, `flatNormalTexture` and `defaultMaterial`. `AssetManager.registerBuiltins()` registers them as in-memory assets.

`ModelInstantiator` turns a `LoadedModel` into entities:

```swift
let instantiator = ModelInstantiator(assets: assets, animations: library)
let root = instantiator.instantiate(model, id: modelID, into: world, parent: .null)
```

- `register(_:id:)` adds the meshes as `<model>#mesh<N>`, the materials, the skeletons as `<model>#skin<N>`, and the clips to the animation library. It can be called more than once.
- `instantiate(_:id:into:transform:parent:playFirstAnimation:)` creates one entity per node, with a `MeshRenderer`, or with a `SkinnedMeshRenderer` if the node has a skin and the mesh is skinned. Lights and cameras are attached as components. Skin joints are resolved to entities, and a `SkeletonBinding` is added to the root. With `playFirstAnimation`, an `Animator` plays the first clip.
- Depth is capped at 256 levels.

## 11. Code examples

### Setting up the database and manager

```swift
import FeroxAnimation
import FeroxAssets
import FeroxCore

let database = AssetDatabase(root: projectURL)
let changes = database.refresh()          // run on a background thread in a real game
print("added:", changes.added.count)

let assets = AssetManager(database: database)
assets.registerBuiltins()
assets.textureQuality = .medium
```

### Loading a texture and waiting for it

```swift
let handle = assets.texture(heroTextureID)          // returns at once; state is loading
handle.whenLoaded { h in
    guard h.state == .loaded else {
        print("texture failed, showing placeholder:", h.state)
        return
    }
    uploadTexture(h.value!, revision: h.revision)
}

// Each frame, on the main thread:
assets.update()
```

### Hot reload with a callback

```swift
assets.hotReload = true
assets.hotReloadInterval = 0.5
assets.onReload = { ids in
    // Drop cached GPU resources for these identifiers, then rebuild them.
    renderCache.invalidate(ids)
}
```

### Updating import settings

```swift
var settings = database.entry(modelID)?.meta.settings ?? ImportSettings()
settings.model.scale = 0.01
try database.updateSettings(modelID, settings)
// Note: the model cache is not invalidated by this change. See section 15.
```

### Memory budget

```swift
assets.budget = MemoryBudget(textureBytes: 512 << 20, meshBytes: 256 << 20, audioBytes: 128 << 20)
```

### Raw bytes for a font or audio file

```swift
let font = assets.data(fontID)
font.whenLoaded { h in
    if h.state == .loaded { fontRegistry.load(h.value!) }
}
```

## 12. Extending the pipeline

To add a new kind of asset:

1. **Recognise the extension.** Add a case to `AssetKind` (if one is needed), and map the extension in `AssetKind.infer(fromExtension:)`.
2. **Record dependencies.** If the format references other files, add a case to `AssetDatabase.discoverDependencies`. Use `safePath.resolve` and `safePath.relativePath(for:)` to keep paths inside the project, as the existing cases do.
3. **Load it.** `AssetManager` has no plug-in hook, so either:
   - use `data(_:)` and parse the bytes in a subsystem that you own, which needs no change to this module; or
   - add a typed loader to `AssetManager`, following the existing pattern: create a handle, set `state` to `loading`, submit work to the worker, and call `finish` with a `Result` and a fallback.
4. **Cache if slow.** Use `database.cachedData(for:suffix:)` and `database.writeCache(_:for:suffix:)`, which key entries by source hash.

A subsystem that wants a custom format can use the public database API without changing `FeroxAssets`:

```swift
func loadTileAnimation(_ id: AssetID, assets: AssetManager) -> AnimationClip? {
    let handle = assets.data(id)
    guard handle.isLoaded, let bytes = handle.value else { return nil }
    return parseTileAnimation(bytes)          // your parser, with its own limits
}
```

Call the function only after `isLoaded` is true, which is the pattern above. Keep parsers bounded: check sizes and counts before allocating, as the glTF importer does.

## 13. Troubleshooting

Every error is an `AssetError`. Its `description` names the file.

| Case | Message format | Typical cause |
| --- | --- | --- |
| `notFound(String)` | `Asset not found: <path>` | The file was moved or deleted, or the identifier has no `.meta` entry. Run `refresh()`. |
| `unsupportedFormat(String)` | `Unsupported asset format: <path>` | An unsupported glTF version, extension or compression, or a tilemap that is not uncompressed. |
| `corrupt(String, reason:)` | `Corrupt asset <path>: <reason>` | Bad JSON, a stream length mismatch, an index out of range, or a truncated file. The reason names the element. |
| `limitExceeded(String, reason:)` | `Asset <path> exceeds limits: <reason>` | A file, image or element count is above `DecodeLimits`. |
| `invalidPath(String)` | `Invalid asset path: <path>` | A URI that escapes the project, is absolute, or contains control characters. |
| `dependencyMissing(String, dependency:)` | `Asset <path> depends on missing <dependency>` | A glTF buffer or image, or an atlas image, is not in the project. |

Other things to check:

- **Pink and black textures.** The checkerboard fallback is in use. Check the state of the handle, and the error logged under the `Assets` category.
- **A model with a cube in place of its geometry.** The model failed to load. Check the error, and the `dependencyMissing` case for external buffers.
- **Stale models after editing.** Replace the source file, or delete `.ferox-cache/`. Settings changes alone do not invalidate the cache.
- **Identifiers that change between machines.** The `.meta` files were not committed, so new identifiers were generated.
- **Memory warnings.** The warning means all resident textures are still referenced. Release handles you no longer need.

## 14. Licensing third-party assets

Ferox does not check licences. Its database indexes only files with recognised extensions, so a licence text file such as `LICENSE.txt` or `LICENSE.md` is not an asset and is not indexed.

Practical points:

- Keep the licence text with the assets it covers, in the same folder or in a `third_party` folder that the project's documentation links to.
- Third-party glTF models and other assets often carry their own licences. Those terms can restrict redistribution, require attribution, or limit commercial use. Check them before committing an asset to a project repository.
- Keep the `.meta` sidecar with its source file. The sidecar records the source hash and the identifier, and does not change the licence terms.
- The database does not record licences. The `labels` field in `AssetMeta` is free-form, and a label such as `"licence:CC-BY-4.0"` is a convention for your own tools, not a feature of this module.

## 15. Limitations and discrepancies

- **Discrepancy: settings changes do not invalidate the model cache.** The cache is keyed only by `sourceHash`. `updateSettings` changes the sidecar, but not the hash, and does not clear `.ferox-cache/`. A cached model keeps the old scale, animation, light and camera settings until the source file changes.
- **Discrepancy: `maxSize` and `mipBias` need mips.** Both work by dropping mip levels. With `generateMips` set to false, or for HDR textures, which never receive mips, they have no effect.
- **Discrepancy: `whenLoaded` runs on failure too.** The stored closure is called for failed loads, and `state` is `failed`. A closure registered after a failure is never called.
- **Discrepancy: hot reload loses colour-space hints.** Reloading a texture passes no `srgb:` hint, so a hint given to `texture(_:srgb:)` is lost.
- **Discrepancy: texture settings not applied.** `TextureImportSettings.srgb` is used, but `filter`, `wrap` and `isCubemap` are stored and never applied by this module. The `TextureImportSettings.srgb` comment says that materials mark normal and occlusion-roughness-metallic maps as linear. No code in this repository does that. Only the glTF importer sets colour space, through its colour flags.
- **Discrepancy: model settings partly ignored.** `ModelImportSettings.generateTangents` is not read. Tangents are generated whenever UVs exist and tangents are missing.
- **Discrepancy: audio settings unused.** `AudioImportSettings` is stored, but there is no audio loader in this module.
- **Limitation: registered meshes are not evicted.** `meshBytes` is enforced only for cached model assets. In-memory meshes count toward the budget but are never removed. `audioBytes` is enforced by the audio backend, not by this module.
- **Limitation: in-memory textures can be evicted.** Textures registered with `registerTexture`, including built-ins and textures from models, are subject to the same LRU rule. If one is evicted and later requested by ID, the manager starts a file load, which fails for built-in identifiers and falls back to the checkerboard.
- **Limitation: derived identifiers may not match.** An atlas that loads before its image is indexed uses `AssetID.derived(fromPath:)`, which may not match the identifier the database later assigns. Keep `.meta` files committed, and let the database index before loading atlases.
- **Limitation: KTX and KTX2 have no decoder.** They are classified as textures but are not decoded by this module.
- **Limitation: glTF features.** Sparse accessors, Draco, meshopt, non-triangle modes and morph rendering are not supported. Hinge-style limits and textures transforms are not imported.
- **Limitation: Tiled.** Only the first tile layer and first tileset are read, and only uncompressed encodings.
- **Limitation: `.fxmat` identifiers.** The file's `id` is overwritten with the asset identifier on load.
- **Limitation: `waitForPendingLoads`** blocks the calling thread until all work finishes.
- **Tests.** `Tests/FeroxSubsystemTests/AssetsTests.swift` covers procedural meshes, validation, image decoding, minimal glTF import, path containment and database discovery. The tests run in CI.

## 16. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): where `AssetManager.update()` sits in the frame.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): scenes and prefabs, which refer to assets by identifier.
- [08-Rendering-3D.md](08-Rendering-3D.md): use of textures, meshes and materials by the renderer.
- [17-Animation-and-Particles.md](17-Animation-and-Particles.md): clips and skeletons produced by glTF import.
- [20-Gameplay-API.md](20-Gameplay-API.md): loading content from gameplay code.
- [21-Performance.md](21-Performance.md): measuring load times and memory use.
- [29-API-Reference.md](29-API-Reference.md): the complete API listing.
