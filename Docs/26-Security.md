# Security

This document describes how Ferox handles untrusted input, what it does and does not do with data it receives, and where the protections live in the source. It is a description of the code, not an audit. No penetration test, fuzzing campaign or third-party review is cited, and none has been run on this snapshot.

To report a vulnerability, follow [SECURITY.md](../SECURITY.md). It asks for private reporting, not a public issue. The supported version is listed there as 0.1.x.

## Contents

1. [Scope and threat model](#1-scope-and-threat-model)
2. [Path validation](#2-path-validation)
3. [Decode limits](#3-decode-limits)
4. [Scene documents](#4-scene-documents)
5. [Asset import](#5-asset-import)
6. [Networking](#6-networking)
7. [Code execution](#7-code-execution)
8. [Telemetry and outbound traffic](#8-telemetry-and-outbound-traffic)
9. [Secrets and repository hygiene](#9-secrets-and-repository-hygiene)
10. [What is not claimed](#10-what-is-not-claimed)
11. [Related documents](#11-related-documents)

## 1. Scope and threat model

[SECURITY.md](../SECURITY.md) names three areas that deserve particular attention:

- **Asset importers**: glTF, image formats and JSON scene files. Malformed or hostile files should not crash the engine, exhaust memory or cause out-of-bounds access.
- **Networking**: messages from peers and servers must be validated before use.
- **Shader hot reload**: reloaded shader source must not cause code to be loaded or executed from unexpected locations.

Everything else in this document follows from those three. The inputs treated as untrusted are:

| Input | Where it enters | Covered in |
| --- | --- | --- |
| Scene and prefab files (`.fxscene`, `.fxprefab`) | `SceneDocument.load`, `EditorSession.load(from:)`, `SceneManager` providers | [section 4](#4-scene-documents) |
| glTF, GLB, images, Tiled maps and their referenced files | `GLTFImporter`, `ImageDecoder`, `TiledImporter`, `AssetDatabase` | [section 5](#5-asset-import) |
| Cached import products | `BinaryReader` | [section 5](#5-asset-import) |
| Datagrams and messages from peers | `NetReader`, `NetConnection`, `NetServer`, `NetClient` | [section 6](#6-networking) |

Shader source is treated as developer input. It comes from the bundled `Shaders` resource, or from a directory the developer configures. The configured directory is described in [section 7](#7-code-execution).

## 2. Path validation

`SafePath` in `Sources/FeroxCore/SafePath.swift` validates paths that come from data. It is constructed with a root, and the root is standardised and has its symbolic links resolved. `resolve(_:)` rejects a path in the following cases, each with its own `PathError`:

| Check | Error |
| --- | --- |
| Empty string | `empty` |
| More than 4096 UTF-8 bytes | `tooLong` |
| Any byte below 0x20, or 0x7F | `invalidCharacters` |
| Starts with `/` or `~`, or contains `://` | `absoluteNotAllowed` |
| A `..` that would climb above the root | `escapesRoot` |
| A resolved location outside the root, after symbolic links are resolved | `escapesRoot` |

Symbolic links are resolved only when the target exists. A link inside the root that points outside it is therefore rejected once it exists.

`SafePath` is used in three places:

- `GLTFImporter.resolveURI` sends every external buffer and image URI through `root.resolve`. Absolute paths and `..` escapes are rejected with `AssetError.invalidPath`. Data URIs are handled separately, as described in [section 5](#5-asset-import).
- `AssetDatabase` checks each dependency it discovers in a glTF, an atlas or a Tiled tileset against `safePath`, and ignores any that fall outside the project.
- `AssetManager` passes the database's `SafePath` to the model importer when it loads a model from a project.

## 3. Decode limits

`DecodeLimits` in `Sources/FeroxCore/SafePath.swift` is the single set of bounds for untrusted data. It is a plain struct, so a caller can change it, but the defaults are:

| Field | Default | Meaning |
| --- | --- | --- |
| `maxFileBytes` | 512 MiB (`512 << 20`) | Largest file or buffer accepted for decoding. |
| `maxElementCount` | 50,000,000 | Largest number of elements in one accessor (count × components). |
| `maxTextureDimension` | 16,384 | Largest width or height of a decoded image. |
| `maxNestingDepth` | 128 | Deepest nesting allowed in a component payload. |

Where each limit is applied:

| Limit | Applied in |
| --- | --- |
| `maxFileBytes` | `SceneDocument.load`, `EditorSession.load(from:)` (checked before the file is read), `AssetManager.sourceData`, `ImageDecoder.decode`, `GLTFImporter.load(data:)`. |
| `maxElementCount` | `GLTFImporter`, for each accessor. |
| `maxTextureDimension` | `ImageDecoder`, for ImageIO images and Netpbm and PFM images. |
| `maxNestingDepth` | `SceneDocument.validate`, for each component payload. |

Two limits are not part of `DecodeLimits`:

- `SceneDocument.maxEntities` is a constant of 1,000,000 entities.
- `BinaryReader.readArray` takes its own default limit of 100,000,000 elements, and `readString` rejects strings longer than 1 MiB. These apply to cached import products.

`AssetManager.limits` is a public property, so a game can change the asset limits. `DecodeLimits` is also a parameter of `SceneDocument.load`, `EditorSession.load` and `ImageDecoder.decode`.

Some size checks run after the data has been read. `SceneManager` and `GLTFImporter.load(url:root:)` read the file with `Data(contentsOf:)` and check the size afterwards. `AssetManager` reads with `Data(contentsOf:options: .mappedIfSafe)` and checks afterwards. The limit therefore bounds decoding, not the initial read. The editor's scene load is the exception: it reads the file's size from the file system and checks it before the file is read.

## 4. Scene documents

`SceneDocument.load(from:limits:)` in `Sources/FeroxScene/Serialization.swift` does the following, in order:

1. Rejects data larger than `limits.maxFileBytes` with `SceneError.malformed`.
2. Decodes the data as JSON with `JSONDecoder`. A decoding error becomes `SceneError.malformed`.
3. Calls `validate(limits:)`, which rejects the document in these cases:
   - a `formatVersion` below 1 or above `SceneDocument.currentVersion` (`unsupportedVersion`);
   - more than `maxEntities` entities (`tooManyEntities`);
   - a duplicate entity id (`duplicateID`);
   - a component payload nested deeper than `maxNestingDepth` (`malformed`);
   - a parent id that does not exist (`invalidParent`);
   - a parent chain that loops back on itself (`malformed`, "parent cycle").

The nesting check runs on the decoded payload. Ferox does not limit the depth of the JSON before `JSONDecoder` parses it, so `maxNestingDepth` does not control how the decoder itself handles very deep input.

Unknown component types are handled in one of two ways. With `SceneSerializer.strict` set to `true`, an unregistered component raises `SceneError.unknownComponent`. Otherwise the payload is kept as `UnknownComponents` and a warning is logged. Each component type has to be registered with `ComponentRegistry` before the document that uses it is loaded.

## 5. Asset import

**Images.** `ImageDecoder.decode` in `Sources/FeroxAssets/ImageDecoder.swift` rejects empty input and data larger than `maxFileBytes`. A PPM or PFM file goes to a built-in Netpbm decoder, which checks that the width and height are positive and no larger than `maxTextureDimension`. Other formats go to ImageIO, which runs only on Apple platforms. ImageIO images are also checked against `maxTextureDimension`, and the decoder rejects an image with a zero dimension. On other platforms, formats other than Netpbm and PFM raise `unsupportedFormat`.

**glTF.** `GLTFImporter` in `Sources/FeroxAssets/GLTF.swift` follows these rules, as its header comment states:

- Every external URI is resolved through `SafePath`. When no `SafePath` root is supplied, an external URI raises `dependencyMissing` instead of being read.
- Data URIs must be base64. Other data URI encodings raise `corrupt`.
- Each accessor's element count is checked against `maxElementCount`. Sparse accessors are rejected with `unsupportedFormat`.
- Accessor and buffer-view ranges are bounds-checked before the bytes are read.
- Non-triangle primitives are skipped with a warning, and unsupported features are rejected or ignored, as the header lists.

**Tiled maps.** `TiledImporter.parse` decodes the file with `JSONDecoder` and checks that the tile data has exactly width times height entries, raising `corrupt` otherwise. It does not apply `DecodeLimits` itself.

**Cached import products.** `BinaryReader` in `Sources/FeroxAssets/BinaryCoding.swift` checks every read against the remaining length, and checks array and string lengths before it uses them. `AssetDatabase.cachedData` ignores a cache file whose header does not equal `FXCACHE1` followed by the source hash, so a stale cache is not read.

Import failures raise `AssetError`, whose doc comment says that the messages name the file. For a glTF image that fails to decode, the importer logs an error and uses a fallback. See [27-Troubleshooting.md](27-Troubleshooting.md).

## 6. Networking

The networking code is in `Sources/FeroxNet`. Its protections are these.

**Decoding never traps.** `NetReader` in `NetCoding.swift` bounds-checks every read and caps every length. Its doc comment says that decoding "never traps". A malformed packet produces a `NetDecodeError`, which is one of `truncated`, `lengthExceeded`, `invalidValue` or `unknownMessage`. A message that fails to decode is logged as a warning and dropped. A varint longer than 64 bits is rejected, and so is a non-finite double.

**Message and packet sizes.**

| Limit | Value | Where |
| --- | --- | --- |
| Largest message payload | 1024 bytes (`NetConnection.maxMessageSize`) | Enforced on send and when reading. Larger messages are dropped on send. |
| Largest packet payload | 1150 bytes (`maxPacketPayload`) | Packets are filled up to this size. |
| Largest UDP datagram | 1400 bytes (`UDPTransport.maxDatagramSize`) | Larger datagrams are dropped. |
| Default length cap in `NetReader` | 4096 bytes | Used when a caller does not pass its own limit. |
| Reliable queue and reorder buffer | 1024 messages (`maxPendingReliable`) | Sends fail when the queue is full. |
| Objects per snapshot | 128 (`SnapshotMessage.maxObjects`) | The encoder truncates, and the decoder rejects larger counts. |

**Connection handling.** The handshake is request, challenge, response, accept. In the server, no per-client state is created until the challenge is answered, and challenges expire after a few seconds. The server's salt comes from the system's random number generator, and the source comment says that the salts "cannot be predicted by spoofers". The response must equal the XOR of the two salts. This check deters spoofed and flooded connection requests. It is not authentication, and it is not encryption.

The challenge reply is padded so that it is never larger than the request, which prevents the server from being used as a reflection amplifier. `NetConfig` sets the following limits, all of which can be changed:

| Setting | Default |
| --- | --- |
| `protocolID` | `0xFE70`. Packets with another id are ignored. |
| `protocolVersion` | 1. A client with another version is denied with "protocol version mismatch". |
| `maxClients` | 16. A connection beyond this is denied with "server full". |
| `maxConnectRequestsPerSecond` | 10 per endpoint. |
| `maxPacketsPerSecond` | 300 per client. Extra packets are dropped. |

**Transport.** `UDPTransport` uses Network.framework. Its doc comment says that "plain UDP is unencrypted and unauthenticated". Passing `dtls: true` to the initialiser wraps the traffic in DTLS, which is off by default. The doc comment also says that game-level validation is still needed when DTLS is on. `LoopbackTransport` is in-process and carries no network traffic.

**Input from clients.** `InputMessage` is described in its doc comment as untrusted intent. The server should validate it, for example by clamping movement vectors. The framework does not validate game-specific values.

**Known limits on what is checked.** The protocol checks the size and shape of each packet. Decisions about whether a sender may send a given message, and about game rules, are left to the game. The handshake is the only sender check the framework makes.

## 7. Code execution

Ferox does not execute untrusted code. The source contains no scripting engine, no expression evaluator and no dynamic loading. A search of `Sources` found no `Process`, `NSTask`, `dlopen`, `NSExpression`, `NSClassFromString`, `NSSelectorFromString` or JavaScript context. The one place where the engine compiles source at run time is the Metal shader path, described below.

`ShaderLibrary` in `Sources/FeroxRender/Metal/ShaderLibrary.swift` compiles Metal Shading Language source at run time with `device.makeLibrary(source:options:)`. The source comes from one of three places, checked in this order:

1. A directory passed to `Renderer` as `shaderDirectory`, which `EngineConfiguration.shaderDirectory` sets. Hot reload is on.
2. The directory named by the `FEROX_SHADER_DIR` environment variable, if it is set and not empty. Hot reload is on.
3. The `Shaders` resource bundled with `FeroxRender`. Hot reload is off.

So hot reload can read `.metal` files from a directory that the process has been told to use. Only a developer who controls that directory should set it. In the source, the directory reaches the renderer from `EngineConfiguration.shaderDirectory` (through `GameHost`) or from `FEROX_SHADER_DIR`, which `ShaderLibrary` reads. No scene, network or asset path is used for this purpose.

Hot reload for assets re-scans the asset folder and re-imports changed files. It loads data, not code.

## 8. Telemetry and outbound traffic

Ferox collects no telemetry. The evidence in the source is these:

- There is no analytics, crash-reporting or metrics SDK, and `Package.swift` declares no dependencies.
- A search of `Sources` found no `URLSession`, `CFNetwork`, `URLRequest` or `http://` or `https://` URL.
- The only network code is `UDPTransport`, which sends to endpoints that the game chooses.
- Logging writes to standard error. Unified logging is used only when a game asks for it with `ConsoleLogSink(useUnifiedLogging: true)`.
- `FeroxDiag`'s doc comment says that nothing is sent anywhere, and that its report goes to standard output only.

These statements describe the source at this snapshot. A game built with Ferox can add its own network calls, and those are outside this document.

## 9. Secrets and repository hygiene

`.gitignore` excludes the usual secret and signing material: `*.p12`, `*.mobileprovision`, `*.provisionprofile`, `*.cer`, `*.pem`, `*.key`, `.env` and `.env.*`. A search of the tracked sources for common credential names and assignment patterns found only unrelated identifiers, such as the `token` field of a network connection. That search is not a secrets scan. Running a dedicated scanner over the full history is a sensible addition.

Because the package has no dependencies, it has no registry credentials to protect. `.gitignore` says that `Package.resolved` is meant to be tracked. The package declares no dependencies, and no such file is present in this snapshot.

## 10. What is not claimed

- No fuzzing, penetration test or third-party review has been run on this snapshot.
- The protections in this document are the ones the source implements. Their behaviour under hostile input has not been measured.
- The `Data(contentsOf:)` reads described in [section 3](#3-decode-limits) mean a very large file is read into memory before the size check.
- The network handshake is not authentication. Unencrypted UDP can be read and modified by anyone on the path, unless DTLS is enabled.
- Decoding of images, and of the formats handled by ImageIO, relies on the operating system's decoders, which Ferox does not control.
- Ferox does not check the integrity of assets or scenes beyond the rules listed above.

## 11. Related documents

- [SECURITY.md](../SECURITY.md): how to report a vulnerability and the supported versions.
- [18-Assets.md](18-Assets.md): the asset database, importers and import settings.
- [19-Shaders-and-Hot-Reload.md](19-Shaders-and-Hot-Reload.md): shader compilation and hot reload.
- [22-Editor.md](22-Editor.md): loading and saving scenes from the editor.
- [23-Networking.md](23-Networking.md): the networking model and its message types.
- [25-Platform-Support.md](25-Platform-Support.md): which transports and importers exist on which platform.
- [27-Troubleshooting.md](27-Troubleshooting.md): the errors these checks raise and how to respond to them.
