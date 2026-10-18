import FeroxCore
import Foundation

/// A physical control an action can be bound to.
public enum InputBinding: Codable, Hashable, Sendable, CustomStringConvertible {
    case key(Key)
    case mouseButton(MouseButton)
    case gamepadButton(GamepadButton)
    /// Analogue axis; `scale` flips or scales it (e.g. -1 for inverted look).
    case gamepadAxis(GamepadAxis, scale: Float)
    /// Four keys forming a 2D vector (WASD / arrows).
    case keyComposite(up: Key, down: Key, left: Key, right: Key)
    /// Mouse motion delta (scaled), for look actions.
    case mouseDelta(scale: Float)
    case scrollWheel(scale: Float)
    /// A gamepad stick as a 2D vector.
    case stick(left: Bool)
    /// Binding active only while `modifier` is held (e.g. Shift+Click).
    indirect case chord(modifier: Key, InputBinding)

    public var description: String {
        switch self {
        case .key(let k): return k.description
        case .mouseButton(let b): return "Mouse \(b)"
        case .gamepadButton(let b): return "Pad \(b)"
        case .gamepadAxis(let a, let s): return "Pad \(a)\(s < 0 ? " (inverted)" : "")"
        case let .keyComposite(u, d, l, r): return "\(u)/\(l)/\(d)/\(r)"
        case .mouseDelta: return "Mouse Motion"
        case .scrollWheel: return "Scroll"
        case .stick(let left): return left ? "Left Stick" : "Right Stick"
        case let .chord(m, b): return "\(m)+\(b)"
        }
    }
}

public enum ActionKind: String, Codable, Sendable {
    /// Digital: `isPressed`, `wasPressed`, `wasReleased`.
    case button
    /// One-dimensional analogue value in [-1, 1] (or unbounded for mouse deltas).
    case axis
    /// Two-dimensional value (movement, look).
    case vector2
}

/// A named, rebindable action ("Jump", "Move", "Fire").
public struct InputAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var kind: ActionKind
    public var bindings: [InputBinding]
    /// Button threshold for analogue bindings driving button actions.
    public var pressThreshold: Float = 0.5
    public init(_ name: String, _ kind: ActionKind = .button, bindings: [InputBinding]) {
        self.name = name
        self.kind = kind
        self.bindings = bindings
    }
}

/// A named set of actions that can be enabled as a unit (Unity "Action Map").
public struct ActionMap: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var actions: [InputAction]
    public init(_ name: String, actions: [InputAction]) {
        self.name = name
        self.actions = actions
    }

    /// Default bindings for a typical action game, used by the examples.
    public static let defaultGameplay = ActionMap(
        "Gameplay",
        actions: [
            InputAction("Move", .vector2, bindings: [.keyComposite(up: .w, down: .s, left: .a, right: .d),
                                                     .keyComposite(up: .up, down: .down, left: .left, right: .right),
                                                     .stick(left: true)]),
            InputAction("Look", .vector2, bindings: [.mouseDelta(scale: 0.1), .stick(left: false)]),
            InputAction("Jump", .button, bindings: [.key(.space), .gamepadButton(.south)]),
            InputAction("Fire", .button, bindings: [.mouseButton(.left), .gamepadAxis(.rightTrigger, scale: 1)]),
            InputAction("Interact", .button, bindings: [.key(.e), .gamepadButton(.west)]),
            InputAction("Sprint", .button, bindings: [.key(.leftShift), .gamepadButton(.leftStick)]),
            InputAction("Pause", .button, bindings: [.key(.escape), .gamepadButton(.menu)]),
        ])

    public static let defaultUI = ActionMap(
        "UI",
        actions: [
            InputAction("Navigate", .vector2, bindings: [.keyComposite(up: .up, down: .down, left: .left, right: .right),
                                                         .stick(left: true)]),
            InputAction("Submit", .button, bindings: [.key(.enter), .key(.space), .gamepadButton(.south)]),
            InputAction("Cancel", .button, bindings: [.key(.escape), .gamepadButton(.east)]),
            InputAction("NextTab", .button, bindings: [.key(.tab), .gamepadButton(.rightShoulder)]),
        ])
}

/// Evaluated value of an action this frame.
public struct ActionValue: Sendable, Hashable {
    public var vector: Vec2 = .zero
    public var isPressed = false
    public var wasPressed = false
    public var wasReleased = false
    public var axis: Float { vector.x }
}

/// The engine's input hub: owns the raw `InputState`, evaluates action maps through an
/// input-context stack, supports rebinding, recording/playback and haptics.
///
/// Threading: platform backends call `enqueue` from the main thread (AppKit) or the
/// GameController handler queue; the engine calls `beginFrame()` once per frame on the
/// main thread, after which the state is immutable for the frame.
public final class InputSystem: @unchecked Sendable {
    public private(set) var state = InputState()
    private let queue = ThreadSafeQueue<InputEvent>()

    public private(set) var maps: [String: ActionMap] = [:]
    /// Context stack: later entries have priority; a context with `consumes == true`
    /// hides actions of lower contexts (e.g. a pause menu over gameplay).
    public struct Context: Hashable, Sendable {
        public var name: String
        public var maps: [String]
        public var consumes: Bool
        public init(_ name: String, maps: [String], consumes: Bool = true) {
            self.name = name
            self.maps = maps
            self.consumes = consumes
        }
    }
    public private(set) var contexts: [Context] = []
    private var values: [String: ActionValue] = [:]

    /// Optional recorder/player.
    public var recorder: InputRecorder?
    public var player: InputPlayback?
    public private(set) var frame: UInt64 = 0

    /// Haptics implementation supplied by the platform backend.
    public var haptics: (any HapticsProvider)?

    /// Pending rebind request.
    private var rebind: (action: String, map: String, index: Int, completion: (InputBinding?) -> Void)?

    /// Events applied this frame (for UI routing and debugging).
    public private(set) var frameEvents: [InputEvent] = []

    public init() {}

    // MARK: Events

    /// Queues a raw event; thread-safe.
    public func enqueue(_ e: InputEvent) { queue.push(e) }

    /// Applies queued events and evaluates actions. Called by the engine at frame start.
    public func beginFrame() {
        frame &+= 1
        state.beginFrame()
        var events = queue.drain()
        if let player {
            events = player.events(forFrame: frame)
            if player.isFinished { self.player = nil }
        }
        recorder?.record(events, frame: frame)
        frameEvents = events
        for e in events {
            if handleRebind(e) { continue }
            state.apply(e)
        }
        evaluateActions()
    }

    // MARK: Action maps & contexts

    public func addMap(_ m: ActionMap) { maps[m.name] = m }
    public func removeMap(_ name: String) { maps[name] = nil }

    public func pushContext(_ c: Context) { contexts.append(c) }
    @discardableResult public func popContext() -> Context? { contexts.popLast() }
    public func removeContext(named name: String) { contexts.removeAll { $0.name == name } }
    public var activeContextName: String? { contexts.last?.name }

    /// Value of an action from the active contexts (top-most providing it wins).
    public func action(_ name: String) -> ActionValue { values[name] ?? ActionValue() }
    public func isPressed(_ name: String) -> Bool { action(name).isPressed }
    public func wasPressed(_ name: String) -> Bool { action(name).wasPressed }
    public func wasReleased(_ name: String) -> Bool { action(name).wasReleased }
    public func vector(_ name: String) -> Vec2 { action(name).vector }
    public func axis(_ name: String) -> Float { action(name).axis }

    private var previousPressed: Set<String> = []

    private func evaluateActions() {
        var newValues: [String: ActionValue] = [:]
        // Walk contexts from top; stop after the first consuming context.
        let ordered: [Context] = contexts.isEmpty ? [Context("Default", maps: Array(maps.keys), consumes: true)] : contexts.reversed()
        var visibleMaps: [ActionMap] = []
        for c in ordered {
            visibleMaps += c.maps.compactMap { maps[$0] }
            if c.consumes { break }
        }
        for m in visibleMaps {
            for a in m.actions where newValues[a.name] == nil {
                var v = ActionValue()
                for b in a.bindings {
                    let bv = evaluate(b)
                    switch a.kind {
                    case .vector2:
                        v.vector += bv
                    case .axis:
                        v.vector.x += bv.x
                    case .button:
                        if Swift.abs(bv.x) >= a.pressThreshold || bv.y >= a.pressThreshold { v.isPressed = true }
                    }
                }
                if a.kind == .vector2 && v.vector.lengthSquared > 1 && !a.bindings.contains(where: { if case .mouseDelta = $0 { return true } else { return false } }) {
                    v.vector = v.vector.normalized
                }
                if a.kind != .button { v.isPressed = v.vector.lengthSquared > a.pressThreshold * a.pressThreshold }
                let was = previousPressed.contains(a.name)
                v.wasPressed = v.isPressed && !was
                v.wasReleased = !v.isPressed && was
                newValues[a.name] = v
            }
        }
        previousPressed = Set(newValues.filter { $0.value.isPressed }.map(\.key))
        values = newValues
    }

    /// Evaluates a single binding as a vector (x for scalar bindings).
    public func evaluate(_ b: InputBinding) -> Vec2 {
        switch b {
        case .key(let k): return state.isDown(k) ? Vec2(1, 0) : .zero
        case .mouseButton(let m): return state.isDown(m) ? Vec2(1, 0) : .zero
        case .gamepadButton(let g): return state.isDown(g) ? Vec2(1, 0) : .zero
        case let .gamepadAxis(a, scale):
            let raw = state.gamepad(player: 0)?.raw(a) ?? 0
            let dz = (a == .leftTrigger || a == .rightTrigger) ? state.triggerDeadZone : DeadZone(shape: .axial)
            return Vec2(dz.apply(raw) * scale, 0)
        case let .keyComposite(u, d, l, r):
            var v = Vec2.zero
            if state.isDown(u) { v.y += 1 }
            if state.isDown(d) { v.y -= 1 }
            if state.isDown(l) { v.x -= 1 }
            if state.isDown(r) { v.x += 1 }
            return v
        case .mouseDelta(let s): return Vec2(state.mouseDelta.x, -state.mouseDelta.y) * s
        case .scrollWheel(let s): return state.scrollDelta * s
        case .stick(let left): return state.stick(left)
        case let .chord(modifier, inner): return state.isDown(modifier) ? evaluate(inner) : .zero
        }
    }

    // MARK: Rebinding

    /// Captures the next key/button/axis press as the new binding at `index` of `action`
    /// in `map`. Escape cancels. The completion receives the new binding (or nil).
    public func beginRebind(action: String, in map: String, bindingIndex: Int, completion: @escaping (InputBinding?) -> Void) {
        rebind = (action, map, bindingIndex, completion)
    }

    public var isRebinding: Bool { rebind != nil }

    private func handleRebind(_ e: InputEvent) -> Bool {
        guard let r = rebind else { return false }
        var binding: InputBinding?
        switch e {
        case .keyDown(.escape, _, _):
            rebind = nil
            r.completion(nil)
            return true
        case .keyDown(let k, false, _): binding = .key(k)
        case .mouseDown(let b, _): binding = .mouseButton(b)
        case .gamepadButton(_, let b, true): binding = .gamepadButton(b)
        case let .gamepadAxis(_, a, v) where Swift.abs(v) > 0.6: binding = .gamepadAxis(a, scale: v < 0 ? -1 : 1)
        default: return false
        }
        guard let binding, var m = maps[r.map], let ai = m.actions.firstIndex(where: { $0.name == r.action }) else { return false }
        if r.index < m.actions[ai].bindings.count {
            m.actions[ai].bindings[r.index] = binding
        } else {
            m.actions[ai].bindings.append(binding)
        }
        maps[r.map] = m
        rebind = nil
        r.completion(binding)
        return true
    }

    /// Serializes all maps (for saving user bindings).
    public func exportBindings() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(maps.values.sorted { $0.name < $1.name })
    }

    public func importBindings(_ data: Data) throws {
        let list = try JSONDecoder().decode([ActionMap].self, from: data)
        for m in list { maps[m.name] = m }
    }

    // MARK: Players & haptics

    public func assign(gamepad id: Int, toPlayer player: Int) {
        for k in state.gamepads.keys where state.gamepads[k]!.player == player { state.gamepads[k]!.player = nil }
        state.gamepads[id]?.player = player
    }

    /// Plays a rumble on the player's gamepad if supported.
    public func rumble(player: Int = 0, intensity: Float, sharpness: Float = 0.5, duration: Double) {
        guard let g = state.gamepad(player: player) else { return }
        haptics?.rumble(gamepad: g.id, intensity: intensity.saturated, sharpness: sharpness.saturated, duration: duration)
    }

    /// Mouse capture (relative mode for FPS cameras); implemented by the platform backend.
    public var setCursorCaptured: ((Bool) -> Void)?
    public private(set) var isCursorCaptured = false
    public func captureCursor(_ captured: Bool) {
        isCursorCaptured = captured
        setCursorCaptured?(captured)
    }
}

/// Rumble/haptics backend abstraction.
public protocol HapticsProvider: AnyObject {
    func rumble(gamepad: Int, intensity: Float, sharpness: Float, duration: Double)
}

// MARK: - Recording & playback

/// Records raw input events per frame (deterministic replays, automated tests, bug reports).
public final class InputRecorder {
    public struct Frame: Codable, Hashable, Sendable {
        public var frame: UInt64
        public var events: [InputEvent]
    }
    public private(set) var frames: [Frame] = []
    private var startFrame: UInt64?
    public init() {}

    func record(_ events: [InputEvent], frame: UInt64) {
        let base = startFrame ?? frame
        startFrame = base
        if !events.isEmpty { frames.append(Frame(frame: frame - base, events: events)) }
    }

    public func data() throws -> Data { try JSONEncoder().encode(frames) }
}

/// Replays a recording, replacing live input while active.
public final class InputPlayback {
    private var frames: [InputRecorder.Frame]
    private var cursor = 0
    private var startFrame: UInt64?
    public init(frames: [InputRecorder.Frame]) { self.frames = frames.sorted { $0.frame < $1.frame } }
    public convenience init(data: Data) throws {
        self.init(frames: try JSONDecoder().decode([InputRecorder.Frame].self, from: data))
    }
    public var isFinished: Bool { cursor >= frames.count }

    func events(forFrame f: UInt64) -> [InputEvent] {
        let base = startFrame ?? f
        startFrame = base
        let rel = f - base
        var out: [InputEvent] = []
        while cursor < frames.count && frames[cursor].frame <= rel {
            out += frames[cursor].events
            cursor += 1
        }
        return out
    }
}
