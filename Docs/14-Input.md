# Input

The input layer (module `FeroxInput`) turns platform events into a per-frame snapshot that game code can poll, and into named actions that players can rebind. Platform backends enqueue `InputEvent` values from any thread. The engine calls `InputSystem.beginFrame()` once per frame, on the main thread. That call drains the queue, updates the polled `InputState`, completes any pending rebind, records or replays events, and evaluates the action maps. On macOS, `MacInputBackend` translates `NSEvent` values and polls controllers through the GameController framework. The module also provides dead zones, a context stack, saving of bindings, recording and playback, CoreHaptics rumble and mouse capture.

Frame timing is described in [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). Input is usually read in the `earlyUpdate` or `update` phases, as described in [06-Scene-and-Entities.md](06-Scene-and-Entities.md). Menus that consume input are described in [15-User-Interface.md](15-User-Interface.md).

## Contents

1. [Architecture](#1-architecture)
2. [Keys, buttons and axes](#2-keys-buttons-and-axes)
3. [Input events](#3-input-events)
4. [Polling API](#4-polling-api)
5. [Frame timing and fixed-update latching](#5-frame-timing-and-fixed-update-latching)
6. [Gamepads](#6-gamepads)
7. [Dead zones](#7-dead-zones)
8. [Actions and bindings](#8-actions-and-bindings)
9. [Contexts](#9-contexts)
10. [Rebinding and saving bindings](#10-rebinding-and-saving-bindings)
11. [Recording and playback](#11-recording-and-playback)
12. [Haptics](#12-haptics)
13. [Cursor capture](#13-cursor-capture)
14. [The macOS backend](#14-the-macos-backend)
15. [Code examples](#15-code-examples)
16. [Limitations](#16-limitations)
17. [Related documents](#17-related-documents)

## 1. Architecture

```text
Platform backend (MacInputBackend on macOS)
   NSEvent translation: keys, mouse, scroll, trackpad
   GameController polling: buttons and axes, changes only
        |
        |  InputSystem.enqueue(_:)          thread-safe queue
        v
InputSystem.beginFrame()                     once per frame, main thread
   1. InputState.beginFrame(): copy current to previous, clear per-frame data
   2. drain the queue, or take events from playback
   3. record the events, if a recorder is set
   4. per event: complete a pending rebind, else InputState.apply(_:)
   5. evaluate action maps through the context stack
        |
        +--> InputState     polled: isDown, wasPressed, mouse, sticks, triggers
        +--> action values  named: isPressed, wasPressed, vector, axis
```

`InputSystem.state` changes only inside `beginFrame()`, so it is stable for the whole frame. Events that arrive mid-frame wait for the next frame.

## 2. Keys, buttons and axes

`Key` is a `UInt16`-backed enum of **physical** key positions, named as on a US ANSI layout. Letters are `a` to `z`, digits `num0` to `num9`. The set also includes navigation, modifier, function and keypad keys, with keypad raw values from 140 to 157. `InputState` stores key state in three 64-bit words, so raw values must stay below 192.

On macOS, `MacInputBackend.key(for:)` maps Carbon virtual key codes (`kVK_*`) to these positions. The key in a given position is reported regardless of the selected layout. For characters, use `InputEvent.text`, which carries the layout-aware text.

| Type | Cases |
| --- | --- |
| `MouseButton` | `left`, `right`, `middle`, `button4`, `button5` |
| `GamepadButton` | `south`, `east`, `west`, `north` (A, B, X, Y on Xbox), `leftShoulder`, `rightShoulder`, `leftTrigger`, `rightTrigger`, `leftStick`, `rightStick`, `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight`, `menu`, `options`, `home` |
| `GamepadAxis` | `leftX`, `leftY`, `rightX`, `rightY`, `leftTrigger`, `rightTrigger` |
| `KeyModifiers` | Option set: `shift`, `control`, `option`, `command` |

## 3. Input events

`InputEvent` is the common currency of backends, playback and recording. It is `Codable`.

| Case | Meaning |
| --- | --- |
| `keyDown(_:repeat:modifiers:)`, `keyUp(_:modifiers:)` | Key transitions. `repeat` marks auto-repeat. |
| `text(String)` | Keyboard text after layout and input-method processing. |
| `mouseMove(position:delta:)` | Position in points from the view's top-left, and raw delta. |
| `mouseDown(_:clickCount:)`, `mouseUp(_:)` | Button transitions. |
| `scroll(delta:precise:)` | `precise` is true for trackpads and Magic Mouse. |
| `magnify(Float)`, `rotate(Float)` | Pinch delta, and rotation in degrees. |
| `gamepadConnected(id:name:)`, `gamepadDisconnected(id:)` | Controller presence. |
| `gamepadButton(id:_:pressed:)`, `gamepadAxis(id:_:value:)` | Controller state. |
| `focusLost` | All keys and mouse buttons are released. |

`enqueue(_:)` is thread-safe. The queue is drained only in `beginFrame()`.

## 4. Polling API

These read `InputSystem.state` after `beginFrame()`.

| Keyboard | Result |
| --- | --- |
| `isDown(_:)`, `wasPressed(_:)`, `wasReleased(_:)` | Held, pressed this frame, released this frame. |
| `didRepeat(_:)`, `modifiers`, `text` | Auto-repeat this frame, latest modifiers, and text typed this frame. |

| Mouse and trackpad | Result |
| --- | --- |
| `isDown(_:)`, `wasPressed(_:)`, `wasReleased(_:)` on `MouseButton` | Button state, with one-frame edges. |
| `mousePosition` | Last position, in points from the view's top-left. |
| `mouseDelta` | Sum of raw deltas this frame, documented as unaffected by cursor capture. |
| `scrollDelta`, `scrollIsPrecise`, `clickCount` | Scroll this frame, and the latest click count. |
| `magnification`, `rotation` | Pinch and rotation deltas this frame. |

| Gamepads | Result |
| --- | --- |
| `gamepad(player:)` | Connected controller in a player slot, if any. |
| `stick(_:player:)`, `trigger(_:player:)` | Values after the stick or trigger dead zone. |
| `isDown(_:player:)`, `wasPressed(_:player:)` on `GamepadButton` | Button state for a player. |
| `anyKeyPressed` | Any key, mouse button or controller button went down this frame. |

`GamepadState` also has `raw(_:)`, which returns the unfiltered axis value.

## 5. Frame timing and fixed-update latching

Edges are true for **one** frame. The engine may run several fixed steps in one frame, or none. A press that arrives in a frame with no fixed step is never seen by a fixed system. When several fixed steps do run, each sees the same edge. Latch the request in `update`, and consume it once in `fixedUpdate`:

```swift
struct JumpLatch: Component {
    var requested = false
}

// update: once per frame.
if input.wasPressed("Jump") {
    world.modify(JumpLatch.self, player) { $0.requested = true }
}

// fixedUpdate: zero or more times per frame.
world.modify(JumpLatch.self, player) { latch in
    if latch.requested {
        applyJumpImpulse(player)   // gameplay code
        latch.requested = false
    }
}
```

Continuous state, such as `isDown` and sticks, can be read in either phase.

## 6. Gamepads

On macOS, `MacInputBackend` handles controllers:

- It observes connect and disconnect notifications, enumerates controllers present at start-up, and starts wireless discovery. It turns off background monitoring for controllers.
- It accepts only controllers with an extended gamepad profile. Each gets a backend id, counting from 1, and a name from its vendor.
- `poll()` reads every controller once, and enqueues only changed buttons and axes that moved by more than 0.0001. Call it once per frame, before `beginFrame()`.

Player slots:

- On connection, the lowest free slot, counting from 0, is assigned. A disconnected controller releases its slot.
- `assign(gamepad:toPlayer:)` moves a controller to a slot. A controller that held that slot loses it.

```swift
input.assign(gamepad: 2, toPlayer: 0)
```

Triggers are also mirrored as digital buttons, down above 0.5. On disconnection, buttons and axes are cleared, and the entry remains with `isConnected` false.

## 7. Dead zones

`DeadZone` shapes analogue input. Values inside `inner` are zero. Values between `inner` and `outer` are rescaled to 0...1, and values above `outer` saturate at 1. `exponent` shapes the curve (1 is linear). The `shape` is:

- `.radial`: the magnitude of a 2D vector is remapped, and its direction kept. Use for sticks.
- `.axial`: each component is remapped, keeping its sign. Use for triggers.

| Setting | Default | Used by |
| --- | --- | --- |
| `InputState.stickDeadZone` | `inner` 0.15, `outer` 0.95, `.radial`, exponent 1 | `stick(_:player:)` |
| `InputState.triggerDeadZone` | `inner` 0.05, `outer` 0.98, `.axial`, exponent 1 | `trigger(_:player:)` and trigger bindings |

```swift
let curve = DeadZone(inner: 0.2, outer: 0.95, shape: .radial, exponent: 2)
print(curve.apply(Vec2(0.1, 0)))   // zero: inside the inner dead zone
```

**Limitation.** The defaults are public properties of `InputState`, but `InputSystem.state` has a `private(set)` setter. Code outside the module cannot change them through `InputSystem`.

## 8. Actions and bindings

An **action** has a name, a kind and bindings. A **map** groups actions. Maps are enabled through contexts.

| Type | Role |
| --- | --- |
| `ActionKind` | `.button`, `.axis` (one value), `.vector2` (two values). |
| `InputAction` | Name, kind, bindings, and `pressThreshold` (default 0.5). |
| `ActionMap` | Named list of actions. `defaultGameplay` and `defaultUI` are provided. |
| `InputBinding` | A control or derived value (below). |
| `ActionValue` | `vector`, `isPressed`, `wasPressed`, `wasReleased`, and `axis` (the x component). |

| Binding | Value |
| --- | --- |
| `key(_:)`, `mouseButton(_:)`, `gamepadButton(_:)` | 1 while held. Gamepads read player 0. |
| `gamepadAxis(_:scale:)` | Axis value after the dead zone, times `scale`, for player 0. **Contributes to x only.** Negative scale inverts. |
| `keyComposite(up:down:left:right:)` | Vector with components in -1, 0, 1. |
| `mouseDelta(scale:)` | Mouse delta times `scale`, with Y inverted so up is positive. |
| `scrollWheel(scale:)` | Scroll delta times `scale`. |
| `stick(left:)` | Stick vector for player 0, after the stick dead zone. |
| `chord(modifier:_:)` | The inner binding, while `modifier` is held. |

Each frame, for each visible action:

- **Button:** pressed if a binding's value reaches `pressThreshold`. The x component is checked, or y when positive.
- **Axis:** the x components of all bindings are summed.
- **Vector2:** binding vectors are summed, then normalised to length 1 if longer, unless a `mouseDelta` binding is present.
- **Axis and vector2 pressed:** the squared length exceeds `pressThreshold` squared.
- **Edges:** `wasPressed` and `wasReleased` compare with the previous frame, by name.

| Default map | Actions |
| --- | --- |
| `ActionMap.defaultGameplay` | `Move` (WASD, arrows, left stick), `Look` (mouse, right stick), `Jump` (Space, south), `Fire` (left mouse, right trigger), `Interact` (E, west), `Sprint` (left Shift, left stick click), `Pause` (Escape, menu) |
| `ActionMap.defaultUI` | `Navigate` (arrows, left stick), `Submit` (Return, Space, south), `Cancel` (Escape, east), `NextTab` (Tab, right shoulder) |

## 9. Contexts

`InputSystem` keeps a stack of `InputSystem.Context` values, each with a name, a list of maps and a `consumes` flag (default `true`). The walk starts at the top. It stops after the first consuming context. An action comes from the first visible map that defines it, so higher maps override lower ones.

```swift
input.addMap(ActionMap.defaultGameplay)
input.addMap(ActionMap.defaultUI)

input.pushContext(InputSystem.Context("Gameplay", maps: ["Gameplay"]))
input.pushContext(InputSystem.Context("HUD", maps: ["UI"], consumes: false))  // shares with gameplay
input.popContext()                    // removes HUD; Gameplay remains
input.removeContext(named: "Gameplay")
```

With an empty stack, every loaded map acts as one consuming context, in dictionary order. If two maps define the same action name, the winner is therefore unspecified. Avoid duplicate names across maps used together. `activeContextName` returns the top context's name.

## 10. Rebinding and saving bindings

`beginRebind(action:in:bindingIndex:completion:)` captures the next suitable input as the binding at `bindingIndex`. An index equal to the binding count appends. The completion receives the new binding, or `nil` when cancelled.

- A non-repeat **key press** becomes `.key`. **Escape cancels**, so it cannot be bound.
- A **mouse button** becomes `.mouseButton`.
- A **gamepad button** becomes `.gamepadButton`.
- A **gamepad axis** with magnitude above 0.6 becomes `.gamepadAxis`, with the sign as scale.

The event that completes a rebind is consumed. `isRebinding` reports a pending rebind. An event that cannot complete it, such as a mouse move, is applied normally and the rebind stays pending. So does a matching event whose action or map does not exist.

- `exportBindings()` returns JSON for every loaded map, sorted by name.
- `importBindings(_:)` decodes an array of maps. Each replaces the loaded map with the same name. Other maps are unchanged. The file is not otherwise validated.

```swift
try input.exportBindings().write(to: settingsURL, options: .atomic)
try input.importBindings(Data(contentsOf: settingsURL))
```

## 11. Recording and playback

`InputRecorder` records, for each frame with events, the events applied that frame. Frame numbers are relative to the first recorded frame.

```swift
let recorder = InputRecorder()
input.recorder = recorder
// ... later ...
let replay = try recorder.data()
```

Setting `input.player` to an `InputPlayback` makes each `beginFrame()` take its events from the recording. **Live events are drained and discarded during playback.** The player clears itself when the recording ends. Replayed events pass through the same state and action code, and a recorder set during playback records them.

```swift
input.player = try InputPlayback(data: replay)
```

## 12. Haptics

`HapticsProvider` has one method, `rumble(gamepad:intensity:sharpness:duration:)`. `MacInputBackend` implements it with CoreHaptics:

- A `CHHapticEngine` is created on the controller's first rumble, and stopped on disconnection.
- Each rumble plays one continuous event with the given intensity and sharpness.
- A controller without haptics (`GCController.haptics` is `nil`) is ignored silently. Engine start or pattern failures are logged as warnings.

`InputSystem.rumble(player:intensity:sharpness:duration:)` looks up the player's controller and clamps intensity and sharpness to 0...1. It does nothing without a controller or a provider.

```swift
input.rumble(player: 0, intensity: 0.8, sharpness: 0.4, duration: 0.25)
```

**Note.** `GamepadState.supportsHaptics` defaults to `false`, and nothing in the repository sets it. Do not use it to decide whether to rumble. Calling `rumble` is safe on any controller.

## 13. Cursor capture

`captureCursor(_:)` sets `isCursorCaptured` and calls the `setCursorCaptured` closure, which `MacInputBackend` installs. On macOS, capture disassociates the mouse from the cursor and hides the cursor, and release reverses both. Use `mouseDelta` for look input.

## 14. The macOS backend

`MacInputBackend` compiles only where AppKit and GameController are available. It is `@MainActor`, and its initialiser sets `input.haptics` and the cursor-capture closure.

- **Keys.** `handle(_:in:)` returns `true` when it consumes an event. Keys go through `key(for:)`. Text is forwarded from `characters`, with control characters and private-use scalars removed, and command shortcuts produce no text. A key with no table entry produces no key event, but the event is still reported as consumed.
- **Modifiers.** `flagsChanged` events become modifier key events. Device-dependent bits tell left from right. Caps Lock and Fn use the standard flags.
- **Mouse.** Positions are in points from the top-left of the view, respecting the flipped state. Deltas come from the event.
- **Scrolling.** Precise deltas are used as they are. Line-based deltas are multiplied by 10.
- **Trackpad.** Magnify and rotate map to `magnify` and `rotate`.
- **Focus.** `focusLost()` releases everything.
- **Controllers.** `poll()` runs once per frame, before `beginFrame()`.

Events the backend does not translate return `false`.

```swift
import AppKit
import FeroxInput

@MainActor
final class GameView: NSView {
    let backend: MacInputBackend

    init(backend: MacInputBackend, frame: NSRect) {
        self.backend = backend
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { backend.handle(event, in: self) }
    override func keyUp(with event: NSEvent) { backend.handle(event, in: self) }
    override func flagsChanged(with event: NSEvent) { backend.handle(event, in: self) }
    override func mouseMoved(with event: NSEvent) { backend.handle(event, in: self) }
    override func mouseDragged(with event: NSEvent) { backend.handle(event, in: self) }
    override func mouseDown(with event: NSEvent) { backend.handle(event, in: self) }
    override func mouseUp(with event: NSEvent) { backend.handle(event, in: self) }
    override func scrollWheel(with event: NSEvent) { backend.handle(event, in: self) }
}

// Each frame, on the main actor:
// backend.poll()
// input.beginFrame()
```

## 15. Code examples

### Setup and the frame

```swift
import FeroxInput

let input = InputSystem()
input.addMap(ActionMap.defaultGameplay)
input.pushContext(InputSystem.Context("Gameplay", maps: ["Gameplay"]))

func frame(platformEvents: [InputEvent]) {
    for event in platformEvents {
        input.enqueue(event)          // thread-safe
    }
    input.beginFrame()                // drains the queue, evaluates actions

    print("move:", input.vector("Move"))             // held: use as a continuous value
    if input.wasPressed("Jump") { /* request a jump: one frame only */ }
    if input.isPressed("Fire") { /* fire while held */ }
}
```

### Reading raw state

```swift
let state = input.state
if state.isDown(.leftShift) && state.wasPressed(.space) {
    print("Shift and Space")
}
let look = state.mouseDelta
let stick = state.stick(true, player: 0)
let trigger = state.trigger(false, player: 0)
```

### A custom action with a chord

```swift
var gameplay = ActionMap.defaultGameplay
gameplay.actions.append(
    InputAction("Dash", .button, bindings: [
        .key(.q),
        .chord(modifier: .leftShift, .mouseButton(.right)),
        .gamepadButton(.rightShoulder),
    ]))
input.addMap(gameplay)
```

### A two-dimensional look action

`mouseDelta` already inverts Y. A stick is a vector binding, so it provides both axes. The `.gamepadAxis` binding cannot provide a vertical look axis.

```swift
var gameplay = ActionMap.defaultGameplay
gameplay.actions.removeAll { $0.name == "Look" }
gameplay.actions.append(
    InputAction("Look", .vector2, bindings: [
        .mouseDelta(scale: 0.1),
        .stick(left: false),
    ]))
input.addMap(gameplay)
```

### A pause menu that consumes gameplay

```swift
input.pushContext(InputSystem.Context("Pause", maps: ["UI"]))  // consumes: gameplay is hidden
// Each frame while paused:
if input.wasPressed("Submit") { resumeGame() }
// On resume:
input.popContext()
```

### Rebinding from a settings screen

```swift
input.beginRebind(action: "Jump", in: "Gameplay", bindingIndex: 0) { newBinding in
    if let newBinding {
        print("Jump is now", newBinding.description)
    } else {
        print("Rebind cancelled")
    }
}
// While waiting, the settings screen shows: if input.isRebinding { ... }
```

### Saving and loading bindings

```swift
func saveBindings(to url: URL) throws {
    try input.exportBindings().write(to: url, options: .atomic)
}

func loadBindings(from url: URL) throws {
    try input.importBindings(Data(contentsOf: url))
}
```

### Recording and replaying

```swift
let recorder = InputRecorder()
input.recorder = recorder

// When a bug occurs:
try recorder.data().write(to: bugReportURL, options: .atomic)

// In a test or a later session:
input.player = try InputPlayback(data: Data(contentsOf: bugReportURL))
```

### Rumble and cursor capture

```swift
func onHeavyImpact(strength: Float) {
    input.rumble(player: 0, intensity: min(1, strength), sharpness: 0.6, duration: 0.2)
}

input.captureCursor(true)     // first-person look: use input.state.mouseDelta
input.captureCursor(false)    // on pause
```

## 16. Limitations

- **Limitation: action bindings read gamepad player 0 only.** `evaluate(_:)` uses player 0 for gamepad bindings. For more players, use the `player:` parameter of the polling API.
- **Limitation: dead zones are not settable through `InputSystem`.** `stickDeadZone` and `triggerDeadZone` exist on `InputState`, but its setter is private to the module.
- **Limitation: `.gamepadAxis` bindings** do not use `stickDeadZone`, and they contribute only the x component. Use `.stick(left:)` for two dimensions.
- **Limitation: no layout-aware key mapping.** `Key` names physical US ANSI positions. Use `text` for characters.
- **Limitation: key range.** Raw values must stay below 192. The largest current value is 157.
- **Limitation: only extended gamepad profiles** are registered.
- **Limitation: rumble depends on the controller.** `supportsHaptics` is never set in this repository.
- **Limitation: macOS only.** `MacInputBackend` is the only backend. Other platforms must enqueue the same events.
- **Limitation: escape cannot be bound.**
- **Limitation: playback replaces live input.** Recordings store events and frame indices only, with no timestamps.
- **Limitation: duplicate action names** without contexts give an unspecified winner.
- **Limitation: import replaces whole maps,** including actions the file does not list.
- **Limitation: no tests in this snapshot.** No `FeroxInputTests` target is declared in `Package.swift`. The behaviour described here comes from the source.

## 17. Related documents

- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md): where `beginFrame()` and the frame phases sit in the loop.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md): systems that read input, and the phases they run in.
- [13-Physics.md](13-Physics.md): fixed-step simulation that consumes input.
- [15-User-Interface.md](15-User-Interface.md): navigation and input consumption by menus.
- [20-Gameplay-API.md](20-Gameplay-API.md): gameplay-level use of actions.
- [21-Performance.md](21-Performance.md): measuring input evaluation cost.
- [29-API-Reference.md](29-API-Reference.md): the complete API listing.
