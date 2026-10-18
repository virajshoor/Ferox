# Troubleshooting

This document lists common problems with Ferox, grouped by area. Each entry gives the message or symptom, the cause that the source gives for it, and a fix. The messages are quoted from the code, so searching the log for a phrase will find the matching row. The source of each message is named in the entry, so that the code can be read if the entry does not solve the problem.

Start with FeroxDiag. It reports what the engine sees on this machine, and its output belongs in any bug report. Nothing in this document has been run on hardware yet, so the fixes describe what the code does, not what has been measured.

## Contents

1. [Start with FeroxDiag](#1-start-with-feroxdiag)
2. [Reading the log](#2-reading-the-log)
3. [Startup and platform](#3-startup-and-platform)
4. [Assets and import](#4-assets-and-import)
5. [Scenes and prefabs](#5-scenes-and-prefabs)
6. [Rendering and graphics](#6-rendering-and-graphics)
7. [Shaders and hot reload](#7-shaders-and-hot-reload)
8. [Networking](#8-networking)
9. [Physics](#9-physics)
10. [Audio](#10-audio)
11. [Editor](#11-editor)
12. [Paths and file safety](#12-paths-and-file-safety)
13. [Related documents](#13-related-documents)

## 1. Start with FeroxDiag

Run FeroxDiag from the package root:

| Command | Output |
| --- | --- |
| `swift run FeroxDiag` | A readable report. |
| `swift run FeroxDiag --json` | The same report as pretty-printed JSON, with sorted keys. Attach this to an issue. |
| `swift run FeroxDiag --render` | The same report, plus a render smoke test. macOS only. |
| `swift run FeroxDiag --help` (or `-h`) | `usage: FeroxDiag [--json] [--render]`. |

The report contains the Ferox version, the operating system version, the CPU core count and the memory size. On a Mac with Metal, it also contains the GPU name, the Apple family, Metal 3 support, unified memory, ray tracing and MetalFX support, the MSAA sample counts, mesh shader support, the working set size and the maximum buffer length. For each quality preset it lists the anti-aliasing mode, the upscaler and its scale, the render size at 2560 × 1440, the ray-traced effects, and every fallback that the resolver recorded.

On a machine without Metal, the report says that Metal is not available. It resolves the presets against `DeviceCapabilities.baseline`.

`--render` renders one 256 × 256 frame of a lit cube offscreen and reports one of these results:

- `ok (256×256, N non-black pixels, M visible objects)`
- `failed (no output texture)`
- `failed (readback)`
- `failed (<error>)`

Nothing from the report is sent anywhere. FeroxDiag writes it to standard output only.

If a bug report includes performance numbers, [CONTRIBUTING.md](../CONTRIBUTING.md) asks for the Mac model, the chip, the macOS version and the Ferox commit. FeroxDiag gives most of that information.

## 2. Reading the log

Ferox logs through `Log.shared`. Each record has a level and a category, and the console sink writes it to standard error as `[LEVEL] [Category] message`. The levels, from lowest to highest, are `trace`, `debug`, `info`, `warning`, `error` and `fault`.

- The default minimum level is `debug` in a debug build, where `FEROX_DEBUG` is defined, and `info` otherwise. Change it with `Log.shared.minimumLevel = .debug`.
- The console sink writes to standard error. It writes to the unified logging system only when it is created with `ConsoleLogSink(useUnifiedLogging: true)`.
- `RingBufferLogSink` keeps the most recent records in memory. The editor's console uses it.
- The categories that appear in the messages below are `Engine`, `Assets`, `Scene`, `ECS`, `Render`, `Shaders`, `Net`, `Physics`, `Audio`, `Input`, and `Editor`.

The entries below quote messages in the form they are logged. Where a message is printed with an error value, the error text follows the colon.

## 3. Startup and platform

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `No Metal device is available` (`RenderError.noDevice`), or `Renderer unavailable: ...` (`EngineError.rendererUnavailable`), followed by `Startup failed: ...` (Engine) | `MTLCreateSystemDefaultDevice()` returned no device, or the renderer could not be created. This happens on Linux and on systems without Metal. | Run on a Mac with Metal. For a simulation without a window, use `--headless`. Run FeroxDiag to check the device. |
| `Could not create a Metal command queue` (`RenderError.commandQueue`) | The device was found but did not give a command queue. | Run FeroxDiag. If the device is reported but the queue still fails, file an issue with the FeroxDiag output. |
| `Asset folder does not exist: <path>` (`EngineError.assetRootMissing`) | `EngineConfiguration.assetRoot` names a path that does not exist, or that is not a directory. | Correct the path. Set `assetRoot` to `nil` to run without file assets. |
| `Headless run failed: ...` (Engine), then exit status 1 | An error during a headless run, which `GameLauncher.runHeadless` reports and then exits with status 1. | Read the error text that follows the colon. |
| `Audio output unavailable (...); continuing without sound` (Engine, warning) | The AVFoundation audio backend could not start. The engine uses the silent backend instead. | Check the audio output device. To run silently on purpose, set `enableAudio` to `false`. |

## 4. Assets and import

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `Asset not found: <id or path>` (`AssetError.notFound`) | The asset's id is not in the database, or its file could not be read. | Check that the source file is inside the asset root. Check that the `<file>.meta` sidecar exists and holds the id that the scene references. `AssetDatabase` writes missing `.meta` files unless `writesMetaFiles` is set to `false`. |
| `Asset X exceeds limits: file too large` (`AssetError.limitExceeded`) | The file is larger than `DecodeLimits.maxFileBytes`, which is 512 MiB by default. | Reduce or split the file. For trusted content, raise `AssetManager.limits`. |
| `Asset X exceeds limits: dimensions W×H exceed 16384` | An image is wider or taller than `maxTextureDimension`. | Downscale the image. For trusted content, raise the limit. |
| `Asset X exceeds limits: accessor N has M elements` | A glTF accessor has more than `maxElementCount` elements (50,000,000 by default). | Split the model. |
| `Corrupt asset X: ImageIO could not decode the image` (`corrupt`) | ImageIO rejected the data, usually because the file is truncated or in an unsupported variant. | Re-export the image. Check that the file opens in an image viewer. |
| `Corrupt asset X: empty image data` | The file is empty. | Re-export the file. |
| `Unsupported asset format: X (image decoding requires ImageIO on this platform)` (`unsupportedFormat`) | The platform has no ImageIO, so only Netpbm (PPM and PFM) can be decoded. | Use PPM or PFM, or run on macOS. |
| `Unsupported asset format: X: sparse accessor N` | The glTF file uses a sparse accessor, which the importer does not support. | Re-export the model without sparse accessors. |
| `Asset X depends on missing Y` (`dependencyMissing`) | A glTF refers to an external buffer or image, but either no `SafePath` root was supplied to the importer, or the referenced file cannot be read. | Load the model through the project asset database, and check that the referenced file exists next to the glTF. |
| `Invalid asset path: <uri> in X: <PathError>` (`invalidPath`) | A glTF URI is absolute or climbs out of the project root. | Use URIs that are relative to the model file and stay inside the project. |
| `Corrupt asset X: unsupported data URI (only base64 is supported)` | A glTF data URI uses an encoding other than base64. | Re-export with base64 data or with external files. |
| `X: image N failed to load (...); using fallback` (Assets, error) | A glTF image could not be decoded. The importer uses a fallback texture. | Fix or re-export the image. The model still loads. |
| `X: mesh N primitive N uses mode M; only triangles are supported, skipped` (Assets, warning) | A primitive uses lines, points or fans. | Re-export the mesh as triangles. |
| `Texture memory X MB exceeds budget Y MB (all textures in use)` (Assets, warning) | Textures that are in use are larger than the budget. | Lower `textureQuality`, or release asset handles that are no longer needed. |

## 5. Scenes and prefabs

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `Malformed scene: file exceeds N bytes` (`SceneError.malformed`) | The scene file is larger than `maxFileBytes`. | Split the scene. Check that the file is a scene and not a binary asset with the wrong extension. |
| `Scene format version N is not supported (max 1)` (`unsupportedVersion`) | The file has a format version this build does not read. | Use a build of Ferox that supports the file's version, or re-save the scene from a current build. |
| `Malformed scene: <DecodingError text>` | The JSON does not match the scene format. | Compare the file with a scene saved by the current build. |
| `Duplicate entity id N in scene document` (`duplicateID`) | Two entities in the file share an id, often after a manual edit or a bad merge. | Give each entity a unique id. |
| `Entity N references missing parent M` (`invalidParent`) | An entity's parent is not in the file. | Restore the parent, or remove the link. |
| `Malformed scene: parent cycle at entity N` | The parent chain loops back on itself. | Break the cycle. |
| `Malformed scene: component nesting too deep in entity N` | A component payload nests deeper than `maxNestingDepth` (128). | Flatten the component's data. |
| `Scene has too many entities (N)` (`tooManyEntities`) | The file has more than 1,000,000 entities. | Split the scene. |
| `Unknown component type 'X'` (`unknownComponent`) | `SceneSerializer.strict` is `true`, and the component is not registered. | Register the component type with `ComponentRegistry.register` before loading, or set `strict` to `false`. |
| `Preserving unknown component 'X' on entity N` (Scene, warning) | The component is not registered, and it is kept as it was loaded. | Register the type if the game uses it. Otherwise the data is kept and saved back unchanged. |
| `Failed to load 'name': <error>` (Scene, error) | `SceneManager` could not load the named scene. The error text is one of the scene errors above. | Fix the scene file as described in that entry. |
| `add(T) on dead entity N` (ECS, warning) | A component was added to an entity that has been destroyed. | Check the entity's lifetime before adding components to it. |

## 6. Rendering and graphics

Many graphics problems are not errors. The resolver changes a setting the device cannot support and records the change. Those changes are logged at info level as `Graphics fallback: <feature>: <requested> → <effective> (<reason>)`. Each one is an intentional fallback. To see what a configuration becomes on the current device, run FeroxDiag. [Section 5 of 24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md#5-resolution-against-device-capabilities) lists the rules.

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `Could not allocate a N² × C shadow map; shadows disabled` (Render, error) | The shadow map for `resolution` by `cascades` could not be allocated. | Lower `shadows.resolution` or `shadows.cascades`. |
| `Render target allocation failed (W×H): ...` (Render, error) | The render targets for the current size could not be allocated. | Lower the render scale in `upscaling`, or the window size. |
| `Texture pool allocation failed: WxH format` (Render, error) | A pooled texture could not be allocated. | Lower `textureQuality` or the resolution. |
| `GPU allocation failed: <what>` (`RenderError.allocation`) | The GPU could not allocate the named resource. | Lower the resource's size, such as the shadow map or the particle count. |
| `GPU particle buffer allocation failed (N particles)` (Render, error) | An emitter's GPU particle buffer could not be allocated. Each particle is 64 bytes, so the upper bound per emitter is 64 MB. | Lower the emitter's capacity. |
| `More than 16 reflection probes; extra probes are ignored` (Render, warning) | The scene has more reflection probes than the renderer supports. | Reduce the number of probes to 16 or fewer. |
| `GPU frame failed: <error>` (Render, error) | A command buffer finished with an error. | Enable Metal API validation in the Xcode scheme, and read the validation messages. |
| `GPU did not release a frame slot within 1 s; frame skipped` (Render, warning) | The GPU did not finish the frame in flight within one second. | Reduce the work per frame, starting with the graphics preset, and profile with the steps in [21-Performance.md](21-Performance.md). |
| `Could not create command buffers; frame skipped` (Render, error) | The command queue would not create command buffers. | Check the Metal device and the output of FeroxDiag. |
| `maxFramesInFlight changes take effect when the renderer is recreated` (Render, warning) | `frame.maxFramesInFlight` was changed while the renderer was running. | Restart the renderer, or set the value before the renderer starts. |
| `Sampler rebuild failed, keeping previous samplers: <error>` (Render, error) | A change to anisotropy could not create new samplers. | The previous samplers are kept. Set the anisotropy to a value listed in [section 4.8 of 24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md#48-textures-filtering-and-culling). |
| `MetalFX temporal scaler unavailable for these formats; using Ferox temporal` and similar (Render, warning) | MetalFX does not accept the texture formats or usage flags that the renderer uses. | None is needed. Ferox's own upscaler is used. |
| `Post pass X unavailable: <error>`, `Present pass unavailable: ...`, `Auto exposure unavailable: ...`, `Light clustering unavailable: ...`, `GPU culling unavailable: ...`, `Hi-Z build unavailable: ...`, `Environment generation failed: ...`, `BRDF LUT integration failed: ...`, `Particle pipeline unavailable: ...` and similar (Render, error) | A render pipeline or pass could not be created, so that feature is skipped. | Look for the shader compilation error that caused it in the log. [Section 7](#7-shaders-and-hot-reload) explains those messages. |
| `Mesh 'X' has out-of-range indices; not uploaded` (Render, error) | The mesh's indices refer to vertices that do not exist. | Fix the mesh data. |
| `Cubemap 'X' face N is truncated` or `Texture 'X' pixel data is truncated` (Render, error) | The image data is shorter than its dimensions require. | Re-export the image. |

## 7. Shaders and hot reload

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `Shader compilation failed in X.metal: <message>` (`RenderError.shaderCompilation`) | The Metal compiler rejected the source. The message names the file and the error. | Fix the error in that file. |
| `Hot reload kept the previous X library: <error>` (Shaders, error) | Hot reload compiled an edited module, and the compile failed. The previous library is still in use. | Fix the module. A later save triggers another reload. |
| `Optional module X unavailable: <error>` (Shaders, warning) | An optional shader module failed to compile. | Fix the module. The game keeps running without it. |
| `Hot reload: Common.metal could not be read` (Shaders, error) | `Common.metal` is missing or cannot be read from the shader directory. | Restore the file in the shader directory. |
| `Shader source not found: X` (`RenderError.shaderSourceMissing`) | The shader directory, from `FEROX_SHADER_DIR` or `shaderDirectory`, lacks a file, or the bundled `Shaders` resource is missing. | Check the directory path in the environment variable or configuration. Unset `FEROX_SHADER_DIR` to use the bundled shaders. |
| `Shader function not found: X` (`RenderError.functionMissing`) | The compiled library has no function with that name. | Check the function name and the module that defines it. |
| `Pipeline 'X' could not be created: <message>` (`RenderError.pipeline`) | The pipeline state could not be created from the compiled functions. | Read the message, and check the pixel format and the sample count that the pipeline expects. |

Hot reload is on only when a shader directory is set, either through `EngineConfiguration.shaderDirectory` or through `FEROX_SHADER_DIR`. See [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md) and [section 7 of 26-Security.md](26-Security.md#7-code-execution).

## 8. Networking

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `UDP listener failed: <error>` (Net, error) | The listener could not start, often because the port is in use. | Choose another port. Port 0 asks the system for a free port. |
| `UDP connection <endpoint> failed: <error>` (Net, warning) | A client connection to the endpoint failed, for example because nothing is listening there. | Check the address, the port and any firewall between the two. |
| Client event `connectionFailed("protocol version mismatch")` | The client's `protocolVersion` differs from the server's. | Build client and server with the same `NetConfig.protocolVersion`. |
| Client event `connectionFailed("server full")` | The server already has `maxClients` clients (16 by default). | Raise `maxClients` or try again later. |
| Client event `connectionFailed("timed out")` | The server did not answer the connection request. | Check that the server is running, the address is right, and the protocol ID matches. |
| `Message N of B bytes exceeds maxMessageSize; dropped` (Net, warning) | The message payload is larger than `NetConnection.maxMessageSize` (1024 bytes). The limit is a constant, so the message must be split. | Split the message into smaller ones, or send changes as separate messages. |
| `Reliable send buffer full for <endpoint>; message dropped` (Net, warning) | More than `maxPendingReliable` (1024) reliable messages are waiting for acknowledgement. | Send fewer reliable messages, or check that the peer is acknowledging them. |
| `<client>: dropped malformed message N: <error>` (Net, warning) | A received message did not decode. | Check that both sides register the same message types with the same IDs. |
| `packet truncated`, `length N exceeds maximum M`, `invalid value: ...` or `unknown message type N` (`NetDecodeError`) | A packet is malformed, or it uses a message ID that the receiver does not register. | Register every message type with `NetMessageRegistry.register` on both sides, and make sure the schemas match. |
| `Duplicate message id N` (a precondition failure at registration) | Two message types have the same `messageID`. | Give each message type a unique ID. |

The protocol and transport limits, and what the handshake does and does not protect, are in [section 6 of 26-Security.md](26-Security.md#6-networking). For the networking model, see [23-Networking.md](23-Networking.md).

## 9. Physics

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `TriangleMesh has out-of-range indices; collider will be empty` (Physics, error) | The mesh's indices refer to vertices that do not exist, so the collider is empty. | Fix the mesh data. |
| `Mesh collider asset X unavailable` (Physics, warning) | A mesh collider refers to an asset that is not loaded, or whose id is wrong. | Check that the asset is loaded and that the id matches its `.meta` sidecar. |

## 10. Audio

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `Could not decode audio 'name': <reason>` (`AudioError.decodeFailed`) | AVFoundation could not decode the file. | Re-export the file in a format that AVFoundation reads, such as WAV or AAC. |
| `Audio configuration changed (device switch); restarting engine` (Audio, warning) | The output device changed, and the engine is restarted. | None is needed. |
| `Engine restart failed: <error>` (Audio, error) | The audio engine did not restart after the device change. | Reconnect the device, or restart the application. |

## 11. Editor

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `The scene can only be saved or loaded while editing (press Stop first)` (`EditorError.notEditing`) | Play mode is running. | Press Stop, then save or load. |
| `Scene file is too large (N bytes)` (`EditorError.fileTooLarge`) | The file is larger than the limit. | See [section 5](#5-scenes-and-prefabs). |
| `Cannot enter play mode, the scene failed to serialise: <error>` (Editor, error) | The scene could not be saved to memory before play mode started. | Look at the scene's error in [section 5](#5-scenes-and-prefabs). |
| `Restoring the scene failed: <error>` (Editor, error) | An undo or redo snapshot could not be restored. | Report the steps that led to it, with the log. |
| `Duplicate failed: <error>` (Editor, error) | Duplicating the selection failed. | Report it with the log. |
| `The editor needs a Mac with Metal.` | FeroxEditor needs Metal, and it exits on other platforms. | Run it on a Mac. |

## 12. Paths and file safety

These errors come from `PathError` and `SafePath`. Their meaning is explained in [section 2 of 26-Security.md](26-Security.md#2-path-validation).

| Message | Cause | Fix |
| --- | --- | --- |
| `Path escapes the project root: X` (`escapesRoot`) | The path uses `..` to climb above the root, or a symbolic link points outside the root. | Change the reference so that it stays inside the project. |
| `Absolute paths are not allowed here: X` (`absoluteNotAllowed`) | The path starts with `/` or `~`, or contains `://`. | Use a path relative to the project root. |
| `Path contains control or NUL characters: X` (`invalidCharacters`) | The path contains a control character or a NUL. | Remove the character from the path. |
| `Path is too long (N bytes)` (`tooLong`) | The path is longer than 4096 UTF-8 bytes. | Shorten the path. |
| `Path is empty` (`empty`) | The path is an empty string. | Supply a path. |

## 13. Related documents

- [02-Getting-Started.md](02-Getting-Started.md): the first build and run.
- [04-Building-and-Testing.md](04-Building-and-Testing.md): build and test commands.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): where startup and the frame loop report errors.
- [18-Assets.md](18-Assets.md): the asset database and importers.
- [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md): shader compilation and hot reload.
- [21-Performance.md](21-Performance.md): measuring slow frames.
- [22-Editor.md](22-Editor.md): the editor and its console.
- [23-Networking.md](23-Networking.md): the networking model.
- [24-Graphics-Settings-and-Presets.md](24-Graphics-Settings-and-Presets.md): fallbacks and how the resolver works.
- [25-Platform-Support.md](25-Platform-Support.md): what runs on which platform.
- [26-Security.md](26-Security.md): the limits and checks behind the path, decoding and network errors.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md): known limitations that can look like bugs.
