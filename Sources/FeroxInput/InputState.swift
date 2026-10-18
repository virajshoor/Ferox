import FeroxCore
import Foundation

/// Dead-zone and response shaping for analogue inputs.
public struct DeadZone: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, Sendable { case radial, axial }
    public var inner: Float = 0.15
    public var outer: Float = 0.95
    public var shape: Shape = .radial
    /// Response exponent (1 = linear, 2 = quadratic for finer control near centre).
    public var exponent: Float = 1
    public init(inner: Float = 0.15, outer: Float = 0.95, shape: Shape = .radial, exponent: Float = 1) {
        self.inner = inner
        self.outer = outer
        self.shape = shape
        self.exponent = exponent
    }

    func remap(_ m: Float) -> Float {
        guard m > inner else { return 0 }
        let t = ((m - inner) / max(outer - inner, 1e-4)).saturated
        return exponent == 1 ? t : pow(t, exponent)
    }

    /// Applies the dead zone to a stick vector.
    public func apply(_ v: Vec2) -> Vec2 {
        switch shape {
        case .radial:
            let m = v.length
            guard m > 1e-6 else { return .zero }
            return v / m * remap(m)
        case .axial:
            return Vec2(remap(Swift.abs(v.x)) * (v.x < 0 ? -1 : 1), remap(Swift.abs(v.y)) * (v.y < 0 ? -1 : 1))
        }
    }

    public func apply(_ x: Float) -> Float { remap(Swift.abs(x)) * (x < 0 ? -1 : 1) }
}

/// State of one connected gamepad.
public struct GamepadState: Sendable, Hashable {
    public var id: Int
    public var name: String
    public var isConnected = true
    /// Player slot (0-based) or nil if unassigned.
    public var player: Int?
    public var rawAxes = [Float](repeating: 0, count: GamepadAxis.allCases.count)
    var down: UInt32 = 0
    var previous: UInt32 = 0
    public var supportsHaptics = false

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    public func isDown(_ b: GamepadButton) -> Bool { down & (1 << UInt32(b.rawValue)) != 0 }
    public func wasPressed(_ b: GamepadButton) -> Bool { isDown(b) && previous & (1 << UInt32(b.rawValue)) == 0 }
    public func wasReleased(_ b: GamepadButton) -> Bool { !isDown(b) && previous & (1 << UInt32(b.rawValue)) != 0 }
    public func raw(_ a: GamepadAxis) -> Float { rawAxes[a.rawValue] }
}

/// Polled per-frame input state, rebuilt from events at the start of each frame.
///
/// "Pressed"/"released" flags are edge-triggered and valid for exactly one frame. Because
/// the engine may run several fixed steps per frame, consume edge-triggered input in
/// `update`, or latch it yourself for `fixedUpdate` (see Docs/14-Input.md).
public struct InputState: Sendable {
    // Keyboard bitsets (Key raw values < 192).
    var keys = [UInt64](repeating: 0, count: 3)
    var keysPrev = [UInt64](repeating: 0, count: 3)
    var keyRepeats: Set<Key> = []
    public internal(set) var modifiers: KeyModifiers = []
    public internal(set) var text = ""

    // Mouse
    public internal(set) var mousePosition = Vec2.zero
    public internal(set) var mouseDelta = Vec2.zero
    public internal(set) var scrollDelta = Vec2.zero
    public internal(set) var scrollIsPrecise = false
    public internal(set) var magnification: Float = 0
    public internal(set) var rotation: Float = 0
    var mouse: UInt8 = 0
    var mousePrev: UInt8 = 0
    public internal(set) var clickCount = 0

    // Gamepads keyed by backend id.
    public internal(set) var gamepads: [Int: GamepadState] = [:]
    public var stickDeadZone = DeadZone()
    public var triggerDeadZone = DeadZone(inner: 0.05, outer: 0.98, shape: .axial)

    public init() {}

    // MARK: Keyboard
    @inline(__always) static func bit(_ k: Key) -> (Int, UInt64) { (Int(k.rawValue) >> 6, 1 << UInt64(k.rawValue & 63)) }
    public func isDown(_ k: Key) -> Bool {
        let (w, b) = InputState.bit(k)
        return keys[w] & b != 0
    }
    public func wasPressed(_ k: Key) -> Bool {
        let (w, b) = InputState.bit(k)
        return keys[w] & b != 0 && keysPrev[w] & b == 0
    }
    public func wasReleased(_ k: Key) -> Bool {
        let (w, b) = InputState.bit(k)
        return keys[w] & b == 0 && keysPrev[w] & b != 0
    }
    /// Key-repeat events this frame (for text navigation, menus).
    public func didRepeat(_ k: Key) -> Bool { keyRepeats.contains(k) }

    // MARK: Mouse
    public func isDown(_ b: MouseButton) -> Bool { mouse & (1 << UInt8(b.rawValue)) != 0 }
    public func wasPressed(_ b: MouseButton) -> Bool { isDown(b) && mousePrev & (1 << UInt8(b.rawValue)) == 0 }
    public func wasReleased(_ b: MouseButton) -> Bool { !isDown(b) && mousePrev & (1 << UInt8(b.rawValue)) != 0 }

    // MARK: Gamepad
    /// Gamepad assigned to `player`, if connected.
    public func gamepad(player: Int) -> GamepadState? { gamepads.values.first { $0.player == player && $0.isConnected } }

    /// Left/right stick with the stick dead zone applied.
    public func stick(_ left: Bool, player: Int = 0) -> Vec2 {
        guard let g = gamepad(player: player) else { return .zero }
        let v = left ? Vec2(g.raw(.leftX), g.raw(.leftY)) : Vec2(g.raw(.rightX), g.raw(.rightY))
        return stickDeadZone.apply(v)
    }
    public func trigger(_ left: Bool, player: Int = 0) -> Float {
        guard let g = gamepad(player: player) else { return 0 }
        return triggerDeadZone.apply(g.raw(left ? .leftTrigger : .rightTrigger))
    }
    public func isDown(_ b: GamepadButton, player: Int = 0) -> Bool { gamepad(player: player)?.isDown(b) ?? false }
    public func wasPressed(_ b: GamepadButton, player: Int = 0) -> Bool { gamepad(player: player)?.wasPressed(b) ?? false }

    /// Any input this frame (useful for "press any key" screens and device switching).
    public var anyKeyPressed: Bool {
        for w in 0..<keys.count where keys[w] & ~keysPrev[w] != 0 { return true }
        return mouse & ~mousePrev != 0 || gamepads.values.contains { $0.down & ~$0.previous != 0 }
    }

    // MARK: Event application

    mutating func beginFrame() {
        keysPrev = keys
        mousePrev = mouse
        for k in gamepads.keys { gamepads[k]!.previous = gamepads[k]!.down }
        mouseDelta = .zero
        scrollDelta = .zero
        magnification = 0
        rotation = 0
        text = ""
        keyRepeats.removeAll(keepingCapacity: true)
        clickCount = 0
    }

    mutating func apply(_ e: InputEvent) {
        switch e {
        case let .keyDown(k, rep, mods):
            let (w, b) = InputState.bit(k)
            keys[w] |= b
            modifiers = mods
            if rep { keyRepeats.insert(k) }
        case let .keyUp(k, mods):
            let (w, b) = InputState.bit(k)
            keys[w] &= ~b
            modifiers = mods
        case .text(let s):
            text += s
        case let .mouseMove(p, d):
            mousePosition = p.simd
            mouseDelta += d.simd
        case let .mouseDown(b, count):
            mouse |= 1 << UInt8(b.rawValue)
            clickCount = count
        case .mouseUp(let b):
            mouse &= ~(1 << UInt8(b.rawValue))
        case let .scroll(d, precise):
            scrollDelta += d.simd
            scrollIsPrecise = precise
        case .magnify(let m): magnification += m
        case .rotate(let r): rotation += r
        case let .gamepadConnected(id, name):
            var g = gamepads[id] ?? GamepadState(id: id, name: name)
            g.isConnected = true
            g.name = name
            if g.player == nil { g.player = nextFreePlayer() }
            gamepads[id] = g
        case .gamepadDisconnected(let id):
            gamepads[id]?.isConnected = false
            gamepads[id]?.down = 0
            gamepads[id]?.rawAxes = [Float](repeating: 0, count: GamepadAxis.allCases.count)
        case let .gamepadButton(id, b, pressed):
            guard gamepads[id] != nil else { return }
            if pressed { gamepads[id]!.down |= 1 << UInt32(b.rawValue) } else { gamepads[id]!.down &= ~(1 << UInt32(b.rawValue)) }
        case let .gamepadAxis(id, a, v):
            gamepads[id]?.rawAxes[a.rawValue] = v.clamped(-1, 1)
            // Mirror triggers as digital buttons.
            if a == .leftTrigger { apply(.gamepadButton(id: id, .leftTrigger, pressed: v > 0.5)) }
            if a == .rightTrigger { apply(.gamepadButton(id: id, .rightTrigger, pressed: v > 0.5)) }
        case .focusLost:
            keys = [0, 0, 0]
            mouse = 0
            modifiers = []
        }
    }

    func nextFreePlayer() -> Int {
        let used = Set(gamepads.values.compactMap { $0.isConnected ? $0.player : nil })
        var p = 0
        while used.contains(p) { p += 1 }
        return p
    }
}
