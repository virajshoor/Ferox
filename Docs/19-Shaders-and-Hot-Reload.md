# Shaders and Hot Reload

Ferox's GPU code is written in Metal Shading Language and lives in `Sources/FeroxRender/Shaders/`. The Swift side that compiles, caches and reloads it is `ShaderLibrary`, in `Sources/FeroxRender/Metal/ShaderLibrary.swift`. Hot reload (`FEROX_SHADER_DIR`, or a directory passed to `Renderer`) always compiles from source. Otherwise `ShaderLibrary` loads `FEROX_METALLIB` or a bundled `FeroxShaders.metallib` when one of those files is present, and compiles the bundled sources when neither is. The repository does not commit a metallib, because the binary is specific to the OS and GPU.

Hot reload is a development feature. It is enabled only when a shader directory is supplied, either in code or through an environment variable. Nothing in this document has been compiled, run or tested on a Mac. The shaders, the compile options and the reload path are unverified on hardware, and no compiler output has been produced from them.

The renderer as a whole is described in [07-Rendering-2D.md](07-Rendering-2D.md) and [08-Rendering-3D.md](08-Rendering-3D.md). Asset-level hot reload (meshes, textures and materials) is a different mechanism and is covered in [18-Assets.md](18-Assets.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [The shader sources](#2-the-shader-sources)
3. [How modules are compiled](#3-how-modules-are-compiled)
4. [Choosing a shader directory](#4-choosing-a-shader-directory)
5. [The reload cycle](#5-the-reload-cycle)
6. [What a reload invalidates](#6-what-a-reload-invalidates)
7. [Lookup, variants and caches](#7-lookup-variants-and-caches)
8. [The Metal support files](#8-the-metal-support-files)
9. [Code examples](#9-code-examples)
10. [Limitations](#10-limitations)
11. [Validation status](#11-validation-status)
12. [Related documents](#12-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| Runtime compilation of ten shader modules | Implemented: `ShaderLibrary.compileAll()`. **Not compiled on hardware.** |
| Shader directory from code or `FEROX_SHADER_DIR` | Implemented: `ShaderLibrary.init`, `EngineConfiguration.shaderDirectory`. |
| Hot reload by polling modification dates | Implemented: `ShaderLibrary.reloadIfChanged()`, called from `Renderer.render`. |
| Function-constant variants | Implemented: `ShaderVariant`. |
| Pipeline and function caches | Implemented: `renderPipeline`, `computePipeline`, `function`. |
| Precompiled `.metallib` | Loaded when hot reload is off and `FEROX_METALLIB` or `FeroxShaders.metallib` in the bundle exists. Otherwise sources compile at launch. |
| Shader debugging or profiling tools | **Not implemented** in the repository. |
| Automated tests | `RenderPathTests` checks shader-source policy, prewarm keys and the new `Mesh.metal` entry points. The macOS CI job runs `Scripts/compile-shaders.sh`. `MetalDeviceTests` constructs a `Renderer` when a GPU is present. |

## 2. The shader sources

`Common.metal` is not a module. It holds the shared structures, constants and function-constant declarations that every other file needs, and it is prepended to each module at compile time. Its header says its structures must match `GPUTypes.swift` exactly. Any change to those structures therefore touches every module.

The ten compiled modules, in compilation order, are:

| Module | File | Role (from each file's header) |
| --- | --- | --- |
| `Mesh` | `Mesh.metal` | Shadow depth, depth/normal/motion prepass, and clustered forward PBR, with linear-blend skinning. |
| `Post` | `Post.metal` | Post-processing: SSAO, temporal anti-aliasing and upscaling, bloom, depth of field, motion blur, auto exposure, tone mapping and grading, and anti-aliasing passes. |
| `Sky` | `Sky.metal` | Sky rendering and image-based-lighting precomputation. |
| `Clusters` | `Clusters.metal` | Clustered light assignment for Forward+ shading. |
| `Culling` | `Culling.metal` | GPU-driven culling. |
| `Debug` | `Debug.metal` | Debug line rendering for physics shapes, bounds and gizmos. |
| `Particles` | `Particles.metal` | GPU particles. |
| `Sprite` | `Sprite.metal` | 2D sprites, shapes, tilemaps, 2D lights and masks. |
| `UI` | `UI.metal` | Immediate-mode UI rendering (`uiVertex`, `uiFragment`). |
| `RayTracing` | `RayTracing.metal` | Hybrid ray-traced effects, requiring Metal ray tracing. |

`Mesh.metal` defines the entry points the renderer names directly, such as `meshVertex`, `shadowVertex`, `shadowAlphaTestFragment`, `prepassFragment` and `forwardFragment`. `Sprite.metal` defines `spriteVertex`, `spriteFragment` and `spriteMaskFragment`.

`ShaderLibrary.modules` lists the ten modules in that order. `ShaderLibrary.requiredModules` names the six the renderer cannot run without: `Mesh`, `Post`, `Sky`, `Sprite`, `UI` and `Debug`. The other four are optional.

## 3. How modules are compiled

Each module is compiled as its own `MTLLibrary`. `ShaderLibrary.compile` reads the module's `.metal` file, joins it after `Common.metal` with a `#line` directive so compiler errors name the right file, and calls `device.makeLibrary(source:options:)`. Each library is labelled `Ferox.<module>`.

The compile options set the language version to 3.0 and turn on `preserveInvariance`. The header comment in `ShaderLibrary.swift` explains why: the forward pass re-rasterises prepass geometry with an equal-depth test, so vertex positions must be bit-identical across pipelines.

At startup, `compileAll()` compiles all ten modules in parallel with `DispatchQueue.concurrentPerform`, then installs the results on the calling thread. If a required module fails, `init` throws `RenderError`. If an optional module fails, the failure is logged as a warning and the module is marked unavailable. `isAvailable(_:)` reports that state, and `failures` holds the compiler message for each failed module.

The source is read as UTF-8 text. Nothing is downloaded, and the sources are read only from the bundle or from the configured directory.

## 4. Choosing a shader directory

`ShaderLibrary.init(device:sourceDirectory:)` picks one of three sources, in this order:

1. An explicit `sourceDirectory`, passed through `Renderer(device:settings:assets:shaderDirectory:)`. `GameHost` passes `EngineConfiguration.shaderDirectory`. This enables hot reload.
2. The `FEROX_SHADER_DIR` environment variable, read only when no explicit directory is passed. A non-empty value enables hot reload.
3. The package's bundled `Shaders` resource. Hot reload is off, and the sources are never read again after launch.

The variable and the parameter both name a directory of `.metal` files. The directory must contain `Common.metal` and every module file. A missing file is reported as `RenderError.shaderSourceMissing` at startup. At reload time it is logged, and the previous library is kept.

## 5. The reload cycle

`Renderer.render` calls `shaders.reloadIfChanged()` once per frame, after `materials.beginFrame()`. The check does the following:

1. It returns immediately when hot reload is off.
2. It returns without polling when less than half a second has passed since the last poll. Polling uses `MonotonicClock`.
3. It reads the modification date of `Common.metal` and each module file, and compares them with the dates from the previous poll.
4. If nothing changed, it returns `false`. If `Common.metal` changed, every module is rebuilt. Otherwise only the changed modules are rebuilt.
5. Each rebuild is compiled with `compile`. On success the new library replaces the old one and `failures` is cleared for that module. On failure the previous library is kept, the error is logged, and `failures` records the message. A typo in a shader therefore never takes the running game down.
6. If anything was rebuilt, the function, render-pipeline and compute-pipeline caches are emptied and `generation` is incremented.

`reloadIfChanged()` returns `true` when any module was rebuilt. The renderer then logs the new generation and invalidates the caches that depend on shader code.

The recompile runs synchronously inside `Renderer.render`. A slow compile can therefore add to that frame's CPU time. This has not been measured.

## 6. What a reload invalidates

When `reloadIfChanged()` returns `true`, `Renderer.render` does three things:

- `environment.invalidate()` (`EnvironmentLighting`). The image-based lighting cubes are regenerated on the next update, and the BRDF lookup is rebuilt.
- `probes.invalidateAll()` (`ReflectionProbes`). Every reflection probe is recaptured.
- `post.releaseCaches()` (`PostProcessor`). Post-processing caches are released so that new pipelines are built.

Pipeline states looked up through `ShaderLibrary.renderPipeline` and `computePipeline` are cleared with the rest of the caches, so the next lookup builds them from the new functions. A pass that keeps a pipeline state on its own object would not be cleared by this path. That was not checked for every pass.

## 7. Lookup, variants and caches

`function(_:variant:module:)` returns an `MTLFunction`. Without a variant it uses `makeFunction(name:)`. With a `ShaderVariant` it specialises the function with function constants. The five constants, at indices 0 to 4 in `Common.metal`, are:

| Field | Default | Constant meaning |
| --- | --- | --- |
| `skinning` | `false` | Linear-blend skinning. |
| `alphaTest` | `false` | Discard transparent texels. |
| `vertexColor` | `false` | Multiply by the vertex colour. |
| `clusters` | `true` | Use clustered light lookup. |
| `unlit` | `false` | Skip lighting. |

`ShaderVariant.key` is a five-character string used in cache keys. Functions are cached under `module.name.variantKey`.

`renderPipeline(_:_:)` caches a render pipeline under a caller-supplied key. The key must describe everything the configure closure sets. The source says so explicitly, and a key that omits a state change will silently return a stale pipeline. The renderer names its keys by use, for example `"ui.<pixel format>"` for the UI pass.

`computePipeline(_:)` caches a compute pipeline by kernel name. `cachedPipelineCount` reports how many render and compute pipelines are held, which is a diagnostic aid and not a performance figure.

`hasFunction(_:)` and `module(of:)` answer whether a function name exists and which module defines it. Function names must be unique across modules for these lookups to be meaningful; if two modules define the same name, the later one in the module list wins in the name index.

## 8. The Metal support files

The `Sources/FeroxRender/Metal/` folder holds the Swift code that drives the shaders. These files are built on macOS, where Metal is available.

| File | Responsibility |
| --- | --- |
| `ShaderLibrary.swift` | Compilation, caching and hot reload. |
| `RenderDevice.swift` | The Metal device, command queue and capability detection. |
| `Renderer.swift` | Frame orchestration, offscreen rendering, reload checks and UI assembly. |
| `ScenePasses.swift` | Scene passes, including the shadow and prepass work for meshes. |
| `OverlayPasses.swift` | Overlay passes: particles, the UI pass (`encodeUI`) and the UI glyph atlas upload. |
| `PostProcessor.swift` | The post-processing chain and its caches. |
| `EnvironmentLighting.swift` | Sky-derived lighting cubes and the BRDF table. |
| `ReflectionProbes.swift` | Reflection probe capture. |
| `RayTracingContext.swift` | Acceleration structures and ray-tracing dispatch. |
| `GPUResources.swift` | The per-frame allocator, the GPU uploader, and the mesh and texture caches. |
| `RenderTargets.swift` | Render targets sized to the output. |

## 9. Code examples

Starting the sample game with shader hot reload pointed at a working copy of the sources:

```swift
var config = EngineConfiguration(title: "Shader Lab")
config.shaderDirectory = URL(fileURLWithPath: "/path/to/Ferox/Sources/FeroxRender/Shaders", isDirectory: true)
GameLauncher.main(MyGame(), configuration: config)
```

The same effect from the shell, with no code change:

```bash
FEROX_SHADER_DIR=/path/to/Ferox/Sources/FeroxRender/Shaders swift run HelloFerox
```

Inspecting the library from a renderer:

```swift
let shaders = renderer.shaders
print("generation", shaders.generation, "hot reload", shaders.hotReloadEnabled)
for (module, message) in shaders.failures {
    print("module \(module) unavailable: \(message)")
}
let uiFragment = try shaders.function("uiFragment", module: "UI")
let skinned = try shaders.function("meshVertex", variant: ShaderVariant(skinning: true), module: "Mesh")
```

## 10. Limitations

- **Metallib is optional.** A checkout without `FEROX_METALLIB` or a bundled metallib still compiles all ten modules from text at launch. There is no committed metallib, so a normal developer run pays that compile. `Renderer` then prewarms the mesh pipelines into `FeroxPipelines.binaryarchive` under the caches directory.
- **Reload is polled, not watched.** Changes are detected at most twice a second, and only while frames are being rendered.
- **Reload is synchronous.** The recompile runs on the render thread. A large edit to `Common.metal` rebuilds all ten modules in one frame.
- **Full rebuild for shared edits.** A change to `Common.metal` rebuilds every module, even if the change affects only one.
- **Pipeline keys are trusted.** A caller that omits state from a key gets a stale pipeline with no warning.
- **Function-constant variants are fixed.** `ShaderVariant` covers skinning, alpha test, vertex colour, clusters, unlit, and material argument buffers (index 5, with index 6 as the discrete-bind complement). Adding a flag requires changing `Common.metal`, the struct and `constantValues` together.
- **Only text sources.** Shaders are compiled from source at runtime, so a shader compile error appears at run time rather than at build time.
- **No shader debugging tools.** The repository has no shader profiler or capture helper.
- **Ray-tracing shaders need hardware.** The `RayTracing` module compiles only where the device supports ray tracing, and that path is not verified on any device.
- **MetalFX availability is a capability check.** Support for spatial and temporal MetalFX is reported through the device capabilities (`supportsMetalFXSpatial` and `supportsMetalFXTemporal`). Those paths are unverified on hardware.

## 11. Validation status

This document was written from the source. No macOS machine or Swift toolchain was available while the engine was written, so none of the ten modules has been compiled, and no compiler diagnostics, pipeline counts or reload timings are reported here. The function names quoted above are taken from the source and have not been resolved against a compiled library.

`FeroxRenderTests` covers the CPU side of rendering, including a source check that `Culling.metal` declares `access::read` and an 8-uint indirect stride, and that `Mesh.metal` declares `prepassPickFragment` and the material argument-buffer path. The macOS CI job compiles every shader module with `Scripts/compile-shaders.sh` (`xcrun metal`, `Common.metal` prepended). That is a compile, not a GPU run. `MetalDeviceTests` constructs a `Renderer` on a Mac that has a device, which compiles the libraries through Metal and records the MetalFX probe. Hot reload has not been executed on hardware in CI.

## 12. Related documents

- [03-Architecture.md](03-Architecture.md) for where `FeroxRender` sits in the module graph.
- [07-Rendering-2D.md](07-Rendering-2D.md) for the sprite and UI passes that use the `Sprite` and `UI` modules.
- [08-Rendering-3D.md](08-Rendering-3D.md) for the mesh, shadow and prepass modules.
- [09-Lighting-and-Shadows.md](09-Lighting-and-Shadows.md) for the clustered lighting that `Clusters.metal` implements.
- [10-Post-Processing-and-Anti-Aliasing.md](10-Post-Processing-and-Anti-Aliasing.md) for what the `Post` module does.
- [11-Ray-Tracing.md](11-Ray-Tracing.md) for the `RayTracing` module.
- [18-Assets.md](18-Assets.md) for asset hot reload, which is separate from shader reload.
- [27-Troubleshooting.md](27-Troubleshooting.md) for reading shader compile errors in the log.
