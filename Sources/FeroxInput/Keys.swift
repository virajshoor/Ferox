import Foundation

/// Platform-independent keyboard key identifiers (physical positions on a US ANSI layout,
/// like USB HID usages). Text entry should use `InputEvent.text` instead of keys.
public enum Key: UInt16, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case a = 0, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case num0 = 30, num1, num2, num3, num4, num5, num6, num7, num8, num9
    case escape = 50, enter, tab, space, backspace, delete, insert, home, end, pageUp, pageDown
    case left = 70, right, up, down
    case leftShift = 80, rightShift, leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand,
        capsLock, function
    case f1 = 100, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case minus = 120, equals, leftBracket, rightBracket, backslash, semicolon, quote, comma, period, slash, grave
    case keypad0 = 140, keypad1, keypad2, keypad3, keypad4, keypad5, keypad6, keypad7, keypad8, keypad9,
        keypadDecimal, keypadPlus, keypadMinus, keypadMultiply, keypadDivide, keypadEnter, keypadEquals, keypadClear

    public var description: String {
        switch self {
        case .space: return "Space"
        case .enter: return "Return"
        case .escape: return "Esc"
        case .leftShift, .rightShift: return "Shift"
        case .leftCommand, .rightCommand: return "⌘"
        case .leftOption, .rightOption: return "⌥"
        case .leftControl, .rightControl: return "⌃"
        default: return String(describing: self).uppercased()
        }
    }
}

public enum MouseButton: Int, Codable, CaseIterable, Sendable { case left = 0, right, middle, button4, button5 }

/// Gamepad buttons using the standard extended-gamepad layout. Labels follow the Xbox
/// convention for names; `displayName` adapts per controller family when known.
public enum GamepadButton: Int, Codable, CaseIterable, Sendable {
    case south = 0  // A / Cross
    case east  // B / Circle
    case west  // X / Square
    case north  // Y / Triangle
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger  // digital view of the triggers (threshold 0.5)
    case leftStick, rightStick  // stick clicks
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case menu, options, home
}

public enum GamepadAxis: Int, Codable, CaseIterable, Sendable {
    case leftX = 0, leftY, rightX, rightY, leftTrigger, rightTrigger
}

/// Modifier keys held during an event.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// Raw input event produced by a platform backend (or by playback).
public enum InputEvent: Codable, Hashable, Sendable {
    case keyDown(Key, repeat: Bool, modifiers: KeyModifiers)
    case keyUp(Key, modifiers: KeyModifiers)
    /// Text produced by the keyboard (after layout and IME), for text fields.
    case text(String)
    /// Position in points relative to the view's top-left, plus raw delta (unaffected by capture).
    case mouseMove(position: Vec2Codable, delta: Vec2Codable)
    case mouseDown(MouseButton, clickCount: Int)
    case mouseUp(MouseButton)
    /// Scroll delta in points; `precise` is true for trackpads/Magic Mouse.
    case scroll(delta: Vec2Codable, precise: Bool)
    /// Trackpad pinch (magnification delta) and rotation (degrees).
    case magnify(Float)
    case rotate(Float)
    case gamepadConnected(id: Int, name: String)
    case gamepadDisconnected(id: Int)
    case gamepadButton(id: Int, GamepadButton, pressed: Bool)
    case gamepadAxis(id: Int, GamepadAxis, value: Float)
    /// The window lost focus: all keys and buttons are released.
    case focusLost
}

/// Codable 2-vector (SIMD Codable layout is an array, which is fine, but this keeps event JSON readable).
public struct Vec2Codable: Codable, Hashable, Sendable {
    public var x: Float, y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
    public init(_ v: SIMD2<Float>) { x = v.x; y = v.y }
    public var simd: SIMD2<Float> { SIMD2(x, y) }
}
