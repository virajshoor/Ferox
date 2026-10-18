import FeroxCore
import FeroxInput
import Foundation

/// Root of the in-game UI: owns the element tree, performs layout, routes input
/// (pointer, keyboard, controller), manages focus and popups, runs transitions and
/// produces a `UIDrawList` for the renderer each frame.
///
/// The UI lives in "points"; `scaleFactor` (backing scale × user UI scale) converts to
/// pixels in the renderer. Set `userScale` for accessibility text/UI scaling.
public final class UIContext {
    public let root = UIElement(name: "Root")
    public let popupLayer = UIElement(name: "Popups")
    public var theme = UITheme()
    public var fonts: any UIFontProvider
    public var clipboard: (any UIClipboard)?
    public let animator = UIAnimator()
    /// Backing scale of the display (2 on Retina) — set by the host.
    public var backingScale: Float = 2
    /// User preference multiplier (accessibility "larger UI").
    public var userScale: Float = 1
    public var scaleFactor: Float { backingScale * userScale }
    /// Size of the UI canvas in points (window size / userScale).
    public private(set) var size = Vec2(1280, 720)

    public private(set) weak var focused: UIElement?
    public private(set) weak var hovered: UIElement?
    private weak var captured: UIElement?
    private var popupOwners: [ObjectIdentifier: UIElement] = [:]
    private var lastPointer = Vec2.zero
    /// True when the pointer is over a UI element this frame; games should ignore world clicks.
    public private(set) var pointerOverUI = false
    /// True while a text field has focus; games should ignore keyboard gameplay input.
    public var wantsKeyboard: Bool { focused is UITextField }
    var opacityStack: [Float] = [1]
    var currentOpacity: Float { opacityStack.last ?? 1 }
    private var navRepeat: Float = 0
    private var lastNav = Vec2.zero

    public init(fonts: any UIFontProvider = MonospaceFontProvider()) {
        self.fonts = fonts
        root.add(popupLayer)
        popupLayer.anchors = .fill
        popupLayer.zIndex = 10_000
    }

    /// Adds a top-level element (screen or HUD layer).
    public func add(_ e: UIElement) {
        root.add(e)
        // Keep popups last.
        root.add(popupLayer)
    }

    // MARK: Frame

    /// Runs layout, input routing and animations. `input` is this frame's polled state.
    public func update(input: InputState?, dt: Float, viewportPoints: Vec2) {
        size = viewportPoints / max(userScale, 0.1)
        animator.update(dt: dt)
        layout()
        if let input { route(input, dt: dt) }
        tick(root, dt: dt)
    }

    public func layout() {
        root.frame = Rect(origin: .zero, size: size)
        root.arrangeChildren(context: self)
    }

    private func tick(_ e: UIElement, dt: Float) {
        e.tick(dt: dt, context: self)
        for c in e.children where c.isVisible { tick(c, dt: dt) }
    }

    // MARK: Hit testing

    /// Topmost interactive element under `p` (popups first, honours clipping and zIndex).
    public func hitTest(_ p: Vec2) -> UIElement? { hit(root, p, clip: nil) }

    private func hit(_ e: UIElement, _ p: Vec2, clip: Rect?) -> UIElement? {
        guard e.isVisible, e.opacity > 0.01 else { return nil }
        let clipNow = e.clipsChildren ? (clip.map { $0.intersection(e.frame) } ?? e.frame) : clip
        for c in e.drawOrder.reversed() {
            if let h = hit(c, p, clip: clipNow) { return h }
        }
        if let clip, !clip.contains(p) { return nil }
        let interactive = e.isFocusable || e.onClick != nil || e.isScrollable || e.background != nil
        return interactive && e !== root && e !== popupLayer && e.frame.contains(p) ? e : nil
    }

    // MARK: Focus

    public func focus(_ e: UIElement?) {
        guard focused !== e else { return }
        focused?.isFocused = false
        focused = e
        e?.isFocused = true
        if let e { scrollIntoView(e) }
    }

    private func scrollIntoView(_ e: UIElement) {
        var p = e.parent
        while let cur = p {
            if let sv = cur as? UIScrollView { sv.scrollToVisible(e) }
            p = cur.parent
        }
    }

    /// Focusable elements in tree order (restricted to the top popup when one is open).
    public func focusables() -> [UIElement] {
        var out: [UIElement] = []
        func walk(_ e: UIElement) {
            guard e.isVisible else { return }
            if e.isFocusable { out.append(e) }
            for c in e.drawOrder { walk(c) }
        }
        if let top = popupLayer.children.last { walk(top) } else { walk(root) }
        return out
    }

    /// Moves focus to the nearest focusable element in `direction` (spatial navigation for
    /// arrow keys, D-pad and sticks).
    public func navigate(_ direction: Vec2) {
        let all = focusables()
        guard let current = focused, all.contains(where: { $0 === current }) else {
            focus(all.first)
            return
        }
        let c = current.frame.center
        var best: UIElement?
        var bestScore = Float.infinity
        for e in all where e !== current {
            let d = e.frame.center - c
            let along = d.dot(direction)
            guard along > 1 else { continue }
            let perpendicular = (d - direction * along).length
            let score = along + perpendicular * 2
            if score < bestScore {
                bestScore = score
                best = e
            }
        }
        if let best { focus(best) }
    }

    public func focusNext(reverse: Bool = false) {
        let all = focusables()
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0 === focused } ?? (reverse ? 0 : -1)
        let n = (i + (reverse ? -1 : 1) + all.count) % all.count
        focus(all[n])
    }

    // MARK: Popups

    public func presentPopup(_ e: UIElement, owner: UIElement) {
        popupLayer.add(e)
        popupOwners[ObjectIdentifier(e)] = owner
    }

    public func dismissPopup(_ e: UIElement) {
        popupOwners[ObjectIdentifier(e)] = nil
        e.removeFromParent()
    }

    public var hasPopup: Bool { !popupLayer.children.isEmpty }

    // MARK: Input routing

    private func dispatch(_ event: UIEvent, to e: UIElement?) -> Bool {
        var cur = e
        while let c = cur {
            if c.handle(event, context: self) { return true }
            cur = c.parent
        }
        return false
    }

    private func setHovered(_ e: UIElement?) {
        guard hovered !== e else { return }
        hovered?.isHovered = false
        hovered = e
        e?.isHovered = true
    }

    func uiKey(_ k: Key) -> FeroxInputKey? {
        switch k {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .home: return .home
        case .end: return .end
        case .backspace: return .backspace
        case .delete: return .delete
        case .enter, .keypadEnter: return .enter
        case .escape: return .escape
        case .tab: return .tab
        case .a: return .a
        case .c: return .c
        case .v: return .v
        case .x: return .x
        default: return nil
        }
    }

    private func route(_ input: InputState, dt: Float) {
        let p = input.mousePosition / max(userScale, 0.1)
        let target = captured ?? hitTest(p)
        pointerOverUI = hitTest(p) != nil
        if captured == nil { setHovered(target) }

        if input.wasPressed(MouseButton.left) {
            // Clicking outside an open popup dismisses it.
            if let top = popupLayer.children.last, !top.frame.contains(p), let owner = popupOwners[ObjectIdentifier(top)] as? UIDropdown {
                owner.closePopup(self)
            }
            if let t = hitTest(p) {
                captured = t
                t.isPressed = true
                if t.isFocusable { focus(t) } else if !(t is UIScrollView) { focus(nil) }
                _ = dispatch(.pointerDown(p, clickCount: input.clickCount), to: t)
            } else {
                focus(nil)
            }
        }
        if let c = captured, input.isDown(MouseButton.left), input.mouseDelta != .zero {
            _ = dispatch(.pointerDrag(p, delta: input.mouseDelta / max(userScale, 0.1)), to: c)
        }
        if input.wasReleased(MouseButton.left), let c = captured {
            c.isPressed = false
            _ = dispatch(.pointerUp(p, inside: c.frame.contains(p)), to: c)
            captured = nil
        }
        if input.scrollDelta != .zero, let t = hitTest(p) {
            var cur: UIElement? = t
            while let c = cur, !c.isScrollable { cur = c.parent }
            if let s = cur { _ = s.handle(.scroll(input.scrollDelta, precise: input.scrollIsPrecise), context: self) }
        }
        lastPointer = p

        // Keyboard
        var mods: UIModifiers = []
        if input.modifiers.contains(.shift) { mods.insert(.shift) }
        if input.modifiers.contains(.command) { mods.insert(.command) }
        if input.modifiers.contains(.option) { mods.insert(.option) }
        if !input.text.isEmpty, let f = focused { _ = f.handle(.text(input.text), context: self) }
        for k in Key.allCases where input.wasPressed(k) || input.didRepeat(k) {
            if k == .tab {
                focusNext(reverse: mods.contains(.shift))
                continue
            }
            guard let uk = uiKey(k) else { continue }
            if let f = focused, f.handle(.key(uk, modifiers: mods), context: self) { continue }
            switch uk {
            case .left: navigate(Vec2(-1, 0))
            case .right: navigate(Vec2(1, 0))
            case .up: navigate(Vec2(0, -1))
            case .down: navigate(Vec2(0, 1))
            case .enter: _ = dispatch(.activate, to: focused)
            case .escape: cancel()
            default: break
            }
        }
        if input.wasPressed(.space), !(focused is UITextField), let f = focused { _ = dispatch(.activate, to: f) }

        // Controller (player 0): D-pad / left stick navigation with auto-repeat.
        var nav = Vec2.zero
        if input.isDown(.dpadUp) { nav.y -= 1 }
        if input.isDown(.dpadDown) { nav.y += 1 }
        if input.isDown(.dpadLeft) { nav.x -= 1 }
        if input.isDown(.dpadRight) { nav.x += 1 }
        let stick = input.stick(true)
        if nav == .zero && stick.length > 0.6 {
            nav = Swift.abs(stick.x) > Swift.abs(stick.y) ? Vec2(stick.x > 0 ? 1 : -1, 0) : Vec2(0, stick.y > 0 ? -1 : 1)
        }
        if nav != .zero {
            navRepeat -= dt
            if nav != lastNav || navRepeat <= 0 {
                navRepeat = nav != lastNav ? 0.4 : 0.12
                // Let the focused control consume (sliders change value); else move focus.
                let consumed = focused.map { $0.handle(.navigate(Vec2(nav.x, -nav.y)), context: self) } ?? false
                if !consumed { navigate(nav) }
            }
        } else {
            navRepeat = 0
        }
        lastNav = nav
        if input.wasPressed(.south) { _ = dispatch(.activate, to: focused) }
        if input.wasPressed(.east) { cancel() }
    }

    private func cancel() {
        if let top = popupLayer.children.last {
            if let owner = popupOwners[ObjectIdentifier(top)] as? UIDropdown { owner.closePopup(self) } else { dismissPopup(top) }
        } else {
            focus(nil)
        }
    }

    // MARK: Drawing

    /// Builds the draw list for this frame.
    public func draw() -> UIDrawList {
        var list = UIDrawList()
        opacityStack = [1]
        draw(root, &list)
        return list
    }

    private func draw(_ e: UIElement, _ list: inout UIDrawList) {
        guard e.isVisible, e.opacity > 0.001 else { return }
        opacityStack.append(currentOpacity * e.opacity)
        defer { opacityStack.removeLast() }
        let original = e.frame
        if e.offset != .zero || e.scale != 1 {
            // Visual transforms are applied by temporarily moving the frame subtree.
            translate(e, by: e.offset, scale: e.scale, around: original.center)
        }
        e.draw(&list, context: self)
        if e.clipsChildren { list.pushClip(e.frame) }
        for c in e.drawOrder { draw(c, &list) }
        if let sv = e as? UIScrollView { sv.drawOverlay(&list, context: self) }
        if e.clipsChildren { list.popClip() }
        if e.offset != .zero || e.scale != 1 {
            translate(e, by: -e.offset, scale: 1 / max(e.scale, 1e-4), around: original.center + e.offset)
        }
    }

    private func translate(_ e: UIElement, by d: Vec2, scale s: Float, around c: Vec2) {
        let f = e.frame
        let newOrigin = c + (f.origin - c) * s + d
        e.frame = Rect(origin: newOrigin, size: f.size * s)
        for child in e.children { translate(child, by: d, scale: s, around: c) }
    }

    // MARK: Accessibility

    /// Flattened accessibility tree for the platform host to expose (VoiceOver).
    public struct AccessibilityNode: Sendable {
        public var label: String
        public var role: AccessibilityRole
        public var frame: Rect
        public var isFocused: Bool
        public var value: String?
    }

    public func accessibilityNodes() -> [AccessibilityNode] {
        var out: [AccessibilityNode] = []
        func walk(_ e: UIElement) {
            guard e.isVisible else { return }
            if e.accessibilityRole != .none && e.accessibilityRole != .group {
                var value: String?
                if let s = e as? UISlider { value = String(format: "%.2f", s.value) }
                if let t = e as? UIToggle { value = t.isOn ? "on" : "off" }
                if let tf = e as? UITextField { value = tf.text }
                let label = e.accessibilityLabel ?? (e as? UILabel)?.plainText ?? e.name
                out.append(AccessibilityNode(label: label, role: e.accessibilityRole, frame: e.frame, isFocused: e.isFocused, value: value))
            }
            for c in e.drawOrder { walk(c) }
        }
        walk(root)
        return out
    }
}
