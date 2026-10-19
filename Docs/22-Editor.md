# Editor

Ferox includes a scene editor, `FeroxEditor`, built on two layers. `EditorSession` is the platform-independent core in the `Ferox` module: selection, Play, Pause, Step and Stop, snapshot-based undo and redo, entity creation, duplication and deletion, and scene files. It drives an `Engine` in edit mode and has no UI of its own, so it can be tested without a window. `FeroxEditor` is a macOS executable that builds the window, the panels and the viewport camera on top of `EditorSession`, `GameHost` and `FeroxUI`.

The editor exists to show that the engine's parts fit together. It is a working outline, not a finished product. Nothing in it has been compiled or run on macOS, and the interface has not been seen on a screen. The limitations listed below are real and deliberate, and some of them affect how a scene can be used.

Scene files and the component registry are covered by [06-Scene-and-Entities.md](06-Scene-and-Entities.md). The UI toolkit the panels use is in [15-User-Interface.md](15-User-Interface.md). The engine's edit-mode behaviour is in [20-Gameplay-API.md](20-Gameplay-API.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [Running the editor](#2-running-the-editor)
3. [Architecture](#3-architecture)
4. [Selection and the hierarchy](#4-selection-and-the-hierarchy)
5. [Play mode](#5-play-mode)
6. [Undo and redo](#6-undo-and-redo)
7. [Scene files and built-in assets](#7-scene-files-and-built-in-assets)
8. [Panels and controls](#8-panels-and-controls)
9. [Code examples](#9-code-examples)
10. [Limitations](#10-limitations)
11. [Validation status](#11-validation-status)
12. [Related documents](#12-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| `EditorSession` (selection, edits, play, undo, files) | Implemented: `Sources/Ferox/EditorSession.swift`. Platform independent. |
| Editor window, panels and viewport camera | Implemented: `Sources/FeroxEditor/FeroxEditor.swift`. macOS with Metal only. **Not run.** |
| Undo, redo and coalescing tests | Present in `Tests/FeroxIntegrationTests/EditorSessionTests.swift`. **Not run here.** |
| Viewport picking | Implemented. The click selects with `EditorSession.pick(_:pixel:)` immediately (CPU raycast) and asks the renderer for an instance-id readback. When that readback hits, it replaces the selection. Tests in `Tests/FeroxIntegrationTests/EditorPickingTests.swift`. See [section 4](#4-selection-and-the-hierarchy). |
| Component editing in the inspector | **Not implemented.** The inspector edits name and transform, and lists component type names. |
| Asset browser, prefab editing, material editing | **Not implemented.** |

## 2. Running the editor

```bash
swift run FeroxEditor                  # a new, default scene
swift run FeroxEditor path/to.fxscene  # open a scene file
```

The first argument that does not start with a dash is treated as a scene path. The window is 1600 × 900 points and titled "Ferox Editor". On platforms without AppKit and Metal, `FeroxEditor` prints a short message explaining that the editing core is available through the `Ferox` module, and exits with status 1.

The default scene contains a ground plane with a box collider, a cube, a directional sun, a camera and an environment entity. It is built in code, not loaded from a file, so a first run needs no assets on disk.

## 3. Architecture

`EditorSession` owns the editing rules. It is created with an engine, and its initialiser sets `engine.isEditMode = true`. Every mutation goes through a method that records an undo step first, changes the world, and then calls `onChange` so the panels can refresh. Nothing in the session depends on AppKit.

`EditorController` in `FeroxEditor` is the engine's `Game`. In edit mode only `setup` and `shutdown` are called on the game. Per-frame editor work happens in `GameHost.onFrame`, which the controller installs when the host attaches. That work includes the orbit camera, keyboard shortcuts, gizmo drawing and the status line.

The controller keeps the panels in sync with the session through `EditorSession.onChange`. `refresh()` rebuilds the hierarchy rows from the scene's entities, updates the inspector sliders and fields, and changes the Play and Pause labels.

The renderer is driven by the same `GameHost` as a game. The editor's own camera is an entity with the highest camera priority (1000), so it wins over the scene's cameras while editing. In play mode the editor camera receives a `Disabled` component, so the game's cameras take over.

## 4. Selection and the hierarchy

`EditorSession.select(_:)` sets the selection. It ignores entities that are not alive or are editor-owned, and it clears the coalescing key so the next edit starts a new undo step.

The hierarchy panel is a virtualised `UIListView` of rows. Each row is an entity in depth-first document order, indented by its depth. Clicking a row selects that entity. Escape clears the selection. Delete or Backspace deletes the selected entity and its children, when no text field has focus.

Left-click in the viewport selects the nearest entity hit by a ray from the editor camera, then asks the GPU to confirm. The click is ignored over a UI panel, and it applies only while editing. `EditorSession.pick(_:pixel:)` returns the CPU hit at once: a mesh with triangle indices uses `MeshRaycast` (front faces, world space), a mesh with no indices uses its world-space bounds, and lights and cameras without a mesh use a 0.3-unit marker sphere. Editor-owned and Disabled entities are skipped. The same click calls `Renderer.scheduleInstancePick`. The next frame draws opaque meshes into an `r32Uint` target with `prepassPickFragment` (CPU instance counts, so culling cannot drop the object) and blits that pixel into a 256-byte shared buffer. When the scene command buffer completes, `takeInstancePick` returns the word and that frame's instance list. `completeInstancePick` replaces the selection when the word is a hit for the latest click. A miss leaves the CPU selection, which is how lights and index-less meshes stay pickable. `Camera.ray(through:aspect:cameraToWorld:)` takes normalized 0...1 viewport coordinates with a top-left origin. It works for perspective and orthographic cameras, and for reverse-Z.

## 5. Play mode

`EditorSession.play()` serialises the scene into a snapshot, clears the clock, turns off edit mode and switches to the `playing` state. The engine then runs all systems and game hooks. `togglePause()` pauses and resumes simulation, and `step()` advances exactly one fixed step while paused, by calling `engine.tick(delta:)` with the fixed step.

`EditorSession.stop()` leaves play mode, turns edit mode back on, and restores the snapshot taken when Play was pressed. Everything the simulation created is destroyed, and no play-mode change reaches the edited scene. The restore recreates every scene entity from the snapshot, so entity handles obtained during play are no longer valid afterwards.

The toolbar's Play button toggles between Play and Stop. The Pause button reads Resume while paused.

## 6. Undo and redo

Each edit calls `recordUndo(_:coalesce:)` before it changes anything. The step stores the whole scene document, plus the index of the selected entity in document order, so the selection can be restored. Undo and redo move these snapshots between two stacks. A new edit clears the redo stack.

The design is simple and exact, not fast. Each step costs time proportional to the scene's size, because the entire scene is encoded. It works for every operation, including deleting a subtree, which a per-command design would have to handle case by case.

Edits that arrive with the same coalescing key in a row share one step. Transform changes use the key `transform` plus the entity's index and generation, so a slider drag produces a single undo step. A key of `nil` never coalesces. The history is capped at `maxUndoSteps`, which is 64 by default; older steps are dropped first.

Undo and redo are only available while editing. `canUndo`, `canRedo`, `undoLabel` and `redoLabel` drive the menu state. The toolbar's Undo and Redo buttons call the session directly.

Opening a scene is also an undoable step, so Undo returns to the previous scene.

## 7. Scene files and built-in assets

`save(to:)` writes the scene as JSON, using the `.fxscene` extension in the panels. The write is atomic. Editor-owned entities, such as the editor camera, are excluded. The save panel suggests the current file name, or the scene name with the extension.

`load(from:limits:)` checks the file size against `DecodeLimits` before reading, then parses it with `SceneDocument.load`, which rejects unsupported versions, duplicate or cyclic identifiers and excessive nesting. The default size limit is 512 MB. Nothing in a scene file is executed. Loading is refused while playing; stop first.

`newScene(named:)` destroys the scene's root entities as an undoable edit. It is also refused while playing.

The editor registers four built-in assets when it starts, so every scene can use them:

| Identifier | Asset |
| --- | --- |
| `editor.cube` | A unit cube mesh. |
| `editor.sphere` | A sphere of radius 0.5. |
| `editor.plane` | A 20 × 20 plane. |
| `editor.default-material` | A light grey material. |

A saved scene refers to these identifiers, not to copies of the meshes. A scene that uses them therefore depends on the same identifiers being registered by whatever loads it. A game that opens such a scene must register the same ids, or the references will not resolve.

## 8. Panels and controls

The toolbar is a row of buttons anchored at the bottom left of the window. It contains Play, Pause, Step, New, Open, Save, Undo, Redo, +Cube, +Sphere, +Light, +Camera, +Empty, Duplicate and Delete. The "+" buttons add a primitive in front of the orbit pivot as a single undoable edit. Light and Camera add the matching component, and Empty adds an entity with only a name and a transform.

The left panel is the hierarchy. The right panel is the inspector. It has a name field, which renames the selected entity on Return, and nine sliders in three groups: position, rotation in degrees (converted back to a quaternion from pitch, yaw and roll), and scale. A line at the bottom lists the component types on the selected entity. Components cannot be edited there.

Assigning a slider's value does not call its change handler. The inspector relies on this, so refreshing from the session does not create undo steps. A user change goes through `setTransform`, which coalesces per entity.

The viewport camera orbits its pivot with the right mouse button. The scroll wheel zooms when the pointer is not over a panel, and W, A, S and D move the pivot relative to the camera's yaw. Keyboard movement is suspended while a text field has focus.

Gizmos are drawn each frame while editing. They include a ground grid from −10 to 10 units on each axis, a cross on each light and an arrow for each directional light, an arrow for each scene camera, and axis arrows and a bounds box for the selected entity.

A status line along the top shows the scene name, an "(edited)" marker when the scene is dirty, the session state, the entity count, and the renderer's last CPU and GPU frame times in milliseconds.

## 9. Code examples

Driving the session from code, without the window. This is how a test or a tool would use it:

```swift
let engine = try Engine(configuration: EngineConfiguration(title: "Tool"))
let session = EditorSession(engine: engine)

let crate = session.createEntity(named: "Crate")
session.setTransform(Transform(position: Vec3(0, 1, 0)), of: crate)
session.undo()                       // reverts the transform
session.undo()                       // reverts the creation

try session.save(to: URL(fileURLWithPath: "/path/to/level.fxscene"))
```

Checking play-mode behaviour:

```swift
session.play()
engine.simulate(frames: 30)          // game hooks and systems run
session.stop()                       // scene restored to the state at Play
assert(session.state == .editing)
```

Choosing an undo limit and reading the labels for a menu:

```swift
session.maxUndoSteps = 128
if session.canUndo { print("Undo \(session.undoLabel ?? "")") }
```

## 10. Limitations

- **Saved scenes reference built-in asset identifiers.** Scenes refer to `editor.cube`, `editor.sphere`, `editor.plane` and `editor.default-material`. A game that loads such a scene must register the same identifiers.
- **The toolbar has a fixed width.** It is anchored at 1500 points and does not adapt to the window's width. Narrower windows are not handled.
- **Undo stores whole-scene snapshots.** Each edit encodes the entire scene, which is O(scene) work per edit. History is capped at `maxUndoSteps`, which is 64 by default. Large scenes will pay for every undoable change.
- **Entity handles do not survive restores.** Undo, redo, Stop and opening a file destroy and recreate scene entities. Any `Entity` a caller holds becomes invalid. Only the selection is carried across, by index.
- **The inspector edits transforms only.** Component values cannot be changed in the editor, and component types are only listed as text.
- **Sliders only.** Numeric entry is not available for position, rotation or scale.
- **No asset browser.** Meshes and materials can be used only through the built-in identifiers or code.
- **No prefab or material editing.**
- **Mac only.** The window needs AppKit and Metal. The editing core runs elsewhere, but the panels do not.
- **Edit-mode side effect.** Creating an `EditorSession` sets the engine into edit mode, so the caller must reset it if the engine is also used for play.
- **Scene files do not bundle assets.** A saved scene names its assets by identifier. The editor neither copies the asset files nor records which ones a scene needs.

## 11. Validation status

This document was written from the source. No macOS machine or Swift toolchain was available while the engine was written, so `FeroxEditor` has never been built, started or used. Its layout, its anchored sizes and its gizmos have not been seen on a screen.

`Tests/FeroxIntegrationTests/EditorSessionTests.swift` exercises `EditorSession`. It covers selection, undo and redo, the coalescing of consecutive transform edits into one step, and Play and Stop snapshot restore. They pass on an M1 Max, macOS 27, Swift 6.4, as do the picking tests in `Tests/FeroxIntegrationTests/EditorPickingTests.swift`. No test covers the `FeroxEditor` panels, the viewport camera or the gizmos.

## 12. Related documents

- [03-Architecture.md](03-Architecture.md) for where `Ferox` and `FeroxEditor` sit in the module graph.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md) for edit mode and the engine frame.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md) for scene documents, the serialiser and entities.
- [15-User-Interface.md](15-User-Interface.md) for the controls the panels use.
- [18-Assets.md](18-Assets.md) for registering the built-in primitives and loading assets.
- [20-Gameplay-API.md](20-Gameplay-API.md) for the `Game` protocol and `GameHost`.
- [27-Troubleshooting.md](27-Troubleshooting.md) for opening a scene that does not render.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md) for planned editor work.
