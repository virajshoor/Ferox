#if canImport(AppKit) && canImport(GameController)
import AppKit
import CoreHaptics
import FeroxCore
import Foundation
import GameController

/// macOS input backend: translates `NSEvent`s from the game view and polls controllers
/// through Apple's GameController framework, feeding `InputSystem`.
///
/// The view forwards its keyboard/mouse events via `handle(_:in:)`; controller state is
/// polled once per frame in `poll()` (before `InputSystem.beginFrame()`), emitting events
/// only for values that changed.
@MainActor
public final class MacInputBackend: NSObject, HapticsProvider {
    public let input: InputSystem
    private var controllerIDs: [ObjectIdentifier: Int] = [:]
    private var controllers: [Int: GCController] = [:]
    private var lastButtons: [Int: [GamepadButton: Bool]] = [:]
    private var lastAxes: [Int: [GamepadAxis: Float]] = [:]
    private var hapticEngines: [Int: CHHapticEngine] = [:]
    private var nextID = 1
    private var observers: [any NSObjectProtocol] = []

    public init(input: InputSystem) {
        self.input = input
        super.init()
        input.haptics = self
        input.setCursorCaptured = { [weak self] captured in
            MainActor.assumeIsolated { self?.setCursorCaptured(captured) }
        }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let c = note.object as? GCController else { return }
                MainActor.assumeIsolated { self?.connect(c) }
            })
        observers.append(
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let c = note.object as? GCController else { return }
                MainActor.assumeIsolated { self?.disconnect(c) }
            })
        GCController.shouldMonitorBackgroundEvents = false
        for c in GCController.controllers() { connect(c) }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Controllers

    private func connect(_ c: GCController) {
        let key = ObjectIdentifier(c)
        guard controllerIDs[key] == nil, c.extendedGamepad != nil else { return }
        let id = nextID
        nextID += 1
        controllerIDs[key] = id
        controllers[id] = c
        input.enqueue(.gamepadConnected(id: id, name: c.vendorName ?? "Gamepad"))
        Log.info("Input", "Controller connected: \(c.vendorName ?? "unknown") (id \(id))")
    }

    private func disconnect(_ c: GCController) {
        guard let id = controllerIDs.removeValue(forKey: ObjectIdentifier(c)) else { return }
        controllers[id] = nil
        lastButtons[id] = nil
        lastAxes[id] = nil
        hapticEngines[id]?.stop(completionHandler: nil)
        hapticEngines[id] = nil
        input.enqueue(.gamepadDisconnected(id: id))
        Log.info("Input", "Controller disconnected (id \(id))")
    }

    /// Polls connected controllers. Call once per frame before `InputSystem.beginFrame()`.
    public func poll() {
        for (id, c) in controllers {
            guard let g = c.extendedGamepad else { continue }
            let buttons: [(GamepadButton, Bool)] = [
                (.south, g.buttonA.isPressed), (.east, g.buttonB.isPressed), (.west, g.buttonX.isPressed),
                (.north, g.buttonY.isPressed), (.leftShoulder, g.leftShoulder.isPressed),
                (.rightShoulder, g.rightShoulder.isPressed), (.leftStick, g.leftThumbstickButton?.isPressed ?? false),
                (.rightStick, g.rightThumbstickButton?.isPressed ?? false), (.dpadUp, g.dpad.up.isPressed),
                (.dpadDown, g.dpad.down.isPressed), (.dpadLeft, g.dpad.left.isPressed), (.dpadRight, g.dpad.right.isPressed),
                (.menu, g.buttonMenu.isPressed), (.options, g.buttonOptions?.isPressed ?? false),
                (.home, g.buttonHome?.isPressed ?? false),
            ]
            var lb = lastButtons[id] ?? [:]
            for (b, pressed) in buttons where lb[b] != pressed {
                lb[b] = pressed
                input.enqueue(.gamepadButton(id: id, b, pressed: pressed))
            }
            lastButtons[id] = lb
            let axes: [(GamepadAxis, Float)] = [
                (.leftX, g.leftThumbstick.xAxis.value), (.leftY, g.leftThumbstick.yAxis.value),
                (.rightX, g.rightThumbstick.xAxis.value), (.rightY, g.rightThumbstick.yAxis.value),
                (.leftTrigger, g.leftTrigger.value), (.rightTrigger, g.rightTrigger.value),
            ]
            var la = lastAxes[id] ?? [:]
            for (a, v) in axes where Swift.abs((la[a] ?? 0) - v) > 1e-4 {
                la[a] = v
                input.enqueue(.gamepadAxis(id: id, a, value: v))
            }
            lastAxes[id] = la
        }
    }

    // MARK: Haptics

    public nonisolated func rumble(gamepad: Int, intensity: Float, sharpness: Float, duration: Double) {
        MainActor.assumeIsolated { self.playRumble(gamepad, intensity, sharpness, duration) }
    }

    private func playRumble(_ id: Int, _ intensity: Float, _ sharpness: Float, _ duration: Double) {
        guard let c = controllers[id], let haptics = c.haptics else { return }
        do {
            let engine: CHHapticEngine
            if let e = hapticEngines[id] {
                engine = e
            } else {
                guard let e = haptics.createEngine(withLocality: .default) else { return }
                try e.start()
                hapticEngines[id] = e
                engine = e
            }
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ], relativeTime: 0, duration: duration)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            Log.warning("Input", "Haptics unavailable: \(error)")
        }
    }

    // MARK: Cursor

    private func setCursorCaptured(_ captured: Bool) {
        CGAssociateMouseAndMouseCursorPosition(captured ? 0 : 1)
        if captured { NSCursor.hide() } else { NSCursor.unhide() }
    }

    // MARK: NSEvent translation

    /// Translates an AppKit event. Returns true if consumed.
    @discardableResult
    public func handle(_ event: NSEvent, in view: NSView) -> Bool {
        switch event.type {
        case .keyDown:
            if let k = MacInputBackend.key(for: event.keyCode) {
                input.enqueue(.keyDown(k, repeat: event.isARepeat, modifiers: modifiers(event.modifierFlags)))
            }
            if let chars = event.characters, !chars.isEmpty, !event.modifierFlags.contains(.command) {
                let filtered = chars.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
                if !filtered.isEmpty { input.enqueue(.text(String(String.UnicodeScalarView(filtered)))) }
            }
            return true
        case .keyUp:
            if let k = MacInputBackend.key(for: event.keyCode) {
                input.enqueue(.keyUp(k, modifiers: modifiers(event.modifierFlags)))
            }
            return true
        case .flagsChanged:
            handleFlags(event)
            return true
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let p = position(event, view)
            input.enqueue(.mouseMove(position: Vec2Codable(p), delta: Vec2Codable(Float(event.deltaX), Float(event.deltaY))))
            return true
        case .leftMouseDown:
            input.enqueue(.mouseDown(.left, clickCount: event.clickCount))
            return true
        case .leftMouseUp:
            input.enqueue(.mouseUp(.left))
            return true
        case .rightMouseDown:
            input.enqueue(.mouseDown(.right, clickCount: event.clickCount))
            return true
        case .rightMouseUp:
            input.enqueue(.mouseUp(.right))
            return true
        case .otherMouseDown:
            if let b = MouseButton(rawValue: min(event.buttonNumber, 4)) { input.enqueue(.mouseDown(b, clickCount: event.clickCount)) }
            return true
        case .otherMouseUp:
            if let b = MouseButton(rawValue: min(event.buttonNumber, 4)) { input.enqueue(.mouseUp(b)) }
            return true
        case .scrollWheel:
            let scale: Float = event.hasPreciseScrollingDeltas ? 1 : 10
            input.enqueue(
                .scroll(delta: Vec2Codable(Float(event.scrollingDeltaX) * scale, Float(event.scrollingDeltaY) * scale),
                        precise: event.hasPreciseScrollingDeltas))
            return true
        case .magnify:
            input.enqueue(.magnify(Float(event.magnification)))
            return true
        case .rotate:
            input.enqueue(.rotate(event.rotation))
            return true
        default:
            return false
        }
    }

    public func focusLost() { input.enqueue(.focusLost) }

    private func position(_ event: NSEvent, _ view: NSView) -> Vec2 {
        let p = view.convert(event.locationInWindow, from: nil)
        let y = view.isFlipped ? p.y : view.bounds.height - p.y
        return Vec2(Float(p.x), Float(y))
    }

    private func modifiers(_ f: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        return m
    }

    private func handleFlags(_ event: NSEvent) {
        guard let k = MacInputBackend.key(for: event.keyCode) else { return }
        // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) distinguish left/right keys.
        let raw = event.modifierFlags.rawValue
        let down: Bool
        switch k {
        case .leftControl: down = raw & 0x0001 != 0
        case .leftShift: down = raw & 0x0002 != 0
        case .rightShift: down = raw & 0x0004 != 0
        case .leftCommand: down = raw & 0x0008 != 0
        case .rightCommand: down = raw & 0x0010 != 0
        case .leftOption: down = raw & 0x0020 != 0
        case .rightOption: down = raw & 0x0040 != 0
        case .rightControl: down = raw & 0x2000 != 0
        case .capsLock: down = event.modifierFlags.contains(.capsLock)
        case .function: down = event.modifierFlags.contains(.function)
        default: return
        }
        let mods = modifiers(event.modifierFlags)
        input.enqueue(down ? .keyDown(k, repeat: false, modifiers: mods) : .keyUp(k, modifiers: mods))
    }

    /// macOS virtual key code → `Key` (Carbon `kVK_*` values).
    public static func key(for code: UInt16) -> Key? { keyTable[code] }

    private static let keyTable: [UInt16: Key] = [
        0x00: .a, 0x01: .s, 0x02: .d, 0x03: .f, 0x04: .h, 0x05: .g, 0x06: .z, 0x07: .x, 0x08: .c, 0x09: .v,
        0x0B: .b, 0x0C: .q, 0x0D: .w, 0x0E: .e, 0x0F: .r, 0x10: .y, 0x11: .t, 0x12: .num1, 0x13: .num2,
        0x14: .num3, 0x15: .num4, 0x16: .num6, 0x17: .num5, 0x18: .equals, 0x19: .num9, 0x1A: .num7,
        0x1B: .minus, 0x1C: .num8, 0x1D: .num0, 0x1E: .rightBracket, 0x1F: .o, 0x20: .u, 0x21: .leftBracket,
        0x22: .i, 0x23: .p, 0x24: .enter, 0x25: .l, 0x26: .j, 0x27: .quote, 0x28: .k, 0x29: .semicolon,
        0x2A: .backslash, 0x2B: .comma, 0x2C: .slash, 0x2D: .n, 0x2E: .m, 0x2F: .period, 0x30: .tab,
        0x31: .space, 0x32: .grave, 0x33: .backspace, 0x35: .escape, 0x36: .rightCommand, 0x37: .leftCommand,
        0x38: .leftShift, 0x39: .capsLock, 0x3A: .leftOption, 0x3B: .leftControl, 0x3C: .rightShift,
        0x3D: .rightOption, 0x3E: .rightControl, 0x3F: .function, 0x41: .keypadDecimal, 0x43: .keypadMultiply,
        0x45: .keypadPlus, 0x47: .keypadClear, 0x4B: .keypadDivide, 0x4C: .keypadEnter, 0x4E: .keypadMinus,
        0x51: .keypadEquals, 0x52: .keypad0, 0x53: .keypad1, 0x54: .keypad2, 0x55: .keypad3, 0x56: .keypad4,
        0x57: .keypad5, 0x58: .keypad6, 0x59: .keypad7, 0x5B: .keypad8, 0x5C: .keypad9, 0x60: .f5, 0x61: .f6,
        0x62: .f7, 0x63: .f3, 0x64: .f8, 0x65: .f9, 0x67: .f11, 0x6D: .f10, 0x6F: .f12, 0x72: .insert,
        0x73: .home, 0x74: .pageUp, 0x75: .delete, 0x76: .f4, 0x77: .end, 0x78: .f2, 0x79: .pageDown, 0x7A: .f1,
        0x7B: .left, 0x7C: .right, 0x7D: .down, 0x7E: .up,
    ]
}
#endif
