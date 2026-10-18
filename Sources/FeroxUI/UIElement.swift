import FeroxCore
import Foundation

/// How an element sizes itself along one axis.
public enum SizeSpec: Sendable, Hashable {
    /// Exactly this many points.
    case fixed(Float)
    /// Size to content.
    case fit
    /// Share remaining space in a stack (weight), or fill the parent otherwise.
    case fill(Float)
    /// Fraction of the parent's content size.
    case percent(Float)
}

/// Cross-axis alignment.
public enum UIAlignment: Sendable, Hashable { case start, center, end, stretch }

/// Unity-style anchors: corners of the element are positioned at fractions of the
/// parent's content rectangle plus point offsets. `Anchors.fill` stretches; `Anchors.center`
/// with offsets ±size/2 centres a fixed-size element.
public struct Anchors: Sendable, Hashable {
    public var min: Vec2
    public var max: Vec2
    public var offsetMin: Vec2
    public var offsetMax: Vec2
    public init(min: Vec2, max: Vec2, offsetMin: Vec2 = .zero, offsetMax: Vec2 = .zero) {
        self.min = min
        self.max = max
        self.offsetMin = offsetMin
        self.offsetMax = offsetMax
    }
    public static let fill = Anchors(min: .zero, max: Vec2(1, 1))
    /// Fixed size centred at an anchor point (e.g. (0.5, 0.5) for screen centre, (1, 0) top-right).
    public static func point(_ p: Vec2, size: Vec2, pivot: Vec2 = Vec2(0.5, 0.5), offset: Vec2 = .zero) -> Anchors {
        let lo = offset - size * pivot
        return Anchors(min: p, max: p, offsetMin: lo, offsetMax: lo + size)
    }
}

public enum AccessibilityRole: String, Sendable { case none, group, staticText, image, button, checkbox, slider, textField, list, popUpButton, scrollArea }

/// Pointer/keyboard event delivered to elements.
public enum UIEvent: Sendable {
    case pointerDown(Vec2, clickCount: Int)
    case pointerUp(Vec2, inside: Bool)
    case pointerDrag(Vec2, delta: Vec2)
    case scroll(Vec2, precise: Bool)
    case key(FeroxInputKey, modifiers: UIModifiers)
    case text(String)
    case activate
    case navigate(Vec2)
}

/// Keys relevant to UI (decoupled from FeroxInput.Key to keep the event enum small).
public enum FeroxInputKey: Sendable, Hashable { case left, right, up, down, home, end, backspace, delete, enter, escape, tab, a, c, v, x }

public struct UIModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = UIModifiers(rawValue: 1)
    public static let command = UIModifiers(rawValue: 2)
    public static let option = UIModifiers(rawValue: 4)
}

/// Base class of the in-game UI tree. UI elements are reference types (identity matters
/// for focus, hover and animation) and are distinct from ECS entities and sprites.
open class UIElement {
    public private(set) weak var parent: UIElement?
    public private(set) var children: [UIElement] = []
    public var name: String

    // Layout
    public var width: SizeSpec = .fit
    public var height: SizeSpec = .fit
    public var minSize = Vec2.zero
    public var maxSize = Vec2(repeating: .infinity)
    public var margin = EdgeInsets.zero
    public var padding = EdgeInsets.zero
    /// When set the element is positioned by anchors inside its parent's content rect,
    /// ignoring the parent's stacking.
    public var anchors: Anchors?
    public var alignSelf: UIAlignment?

    // Visual
    public var isVisible = true
    public var isEnabled = true
    public var opacity: Float = 1
    /// Visual-only translation and scale (do not affect layout; used for transitions).
    public var offset = Vec2.zero
    public var scale: Float = 1
    public var background: Color?
    public var backgroundBottom: Color?
    public var cornerRadius: Float = 0
    public var borderWidth: Float = 0
    public var borderColor: Color = .clear
    public var clipsChildren = false
    /// Higher values draw (and hit-test) above siblings.
    public var zIndex = 0

    // Interaction state
    public internal(set) var isHovered = false
    public internal(set) var isPressed = false
    public internal(set) var isFocused = false
    public var accessibilityLabel: String?
    public var accessibilityRole: AccessibilityRole = .none
    public var tooltip: String?
    /// Called when the element is clicked or activated by keyboard/controller.
    public var onClick: (() -> Void)?

    /// Final frame in UI points (valid after layout).
    public internal(set) var frame = Rect.zero
    /// Cached measured size.
    var measured = Vec2.zero

    public init(name: String = "") { self.name = name }

    // MARK: Tree

    @discardableResult
    open func add(_ child: UIElement) -> UIElement {
        child.removeFromParent()
        child.parent = self
        children.append(child)
        return child
    }

    public func add(_ elements: UIElement...) { for e in elements { add(e) } }

    public func removeFromParent() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    public func removeAllChildren() {
        for c in children { c.parent = nil }
        children.removeAll()
    }

    /// Depth-first search by name.
    public func find(_ name: String) -> UIElement? {
        if self.name == name { return self }
        for c in children { if let f = c.find(name) { return f } }
        return nil
    }

    public var contentRect: Rect { frame.insetBy(padding) }

    /// Whether this element and all ancestors are enabled.
    public var isEffectivelyEnabled: Bool { isEnabled && (parent?.isEffectivelyEnabled ?? true) }

    // MARK: Overridable behaviour

    /// Can receive keyboard/controller focus.
    open var isFocusable: Bool { false }
    /// Scroll containers return true to receive scroll events from descendants.
    open var isScrollable: Bool { false }

    /// Intrinsic content size (excluding padding) for `.fit` sizing.
    open func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        // Default container: overlay — the max extent of non-anchored children.
        var size = Vec2.zero
        for c in children where c.isVisible && c.anchors == nil {
            let m = c.measure(available: available, context: context)
            size = pointwiseMax(size, m + Vec2(c.margin.horizontal, c.margin.vertical))
        }
        return size
    }

    /// Positions children inside `contentRect`. The default is overlay layout.
    open func arrangeChildren(context: UIContext) {
        for c in children where c.isVisible {
            if c.anchors != nil {
                c.arrangeAnchored(in: contentRect, context: context)
            } else {
                let avail = Rect(
                    x: contentRect.minX + c.margin.left, y: contentRect.minY + c.margin.top,
                    width: max(0, contentRect.width - c.margin.horizontal), height: max(0, contentRect.height - c.margin.vertical))
                let size = c.resolvedSize(in: avail.size, measured: c.measure(available: avail.size, context: context))
                let align = c.alignSelf ?? .stretch
                let w = (align == .stretch && isFlexible(c.width)) ? avail.width : size.x
                let h = (align == .stretch && isFlexible(c.height)) ? avail.height : size.y
                let x: Float, y: Float
                switch align {
                case .start, .stretch: (x, y) = (avail.minX, avail.minY)
                case .center: (x, y) = (avail.minX + (avail.width - w) / 2, avail.minY + (avail.height - h) / 2)
                case .end: (x, y) = (avail.maxX - w, avail.maxY - h)
                }
                c.arrange(Rect(x: x, y: y, width: w, height: h), context: context)
            }
        }
    }

    /// Draws the element (not its children).
    open func draw(_ list: inout UIDrawList, context: UIContext) {
        if let bg = background {
            list.rect(frame, bg, bottom: backgroundBottom, radius: cornerRadius, border: borderWidth, borderColor: borderColor)
        } else if borderWidth > 0 {
            list.rect(frame, .clear, radius: cornerRadius, border: borderWidth, borderColor: borderColor)
        }
    }

    /// Handles an event; return true to consume it.
    open func handle(_ event: UIEvent, context: UIContext) -> Bool {
        if case .activate = event, let onClick, isEffectivelyEnabled {
            onClick()
            return true
        }
        return false
    }

    /// Called every frame (animations, caret blink).
    open func tick(dt: Float, context: UIContext) {}

    // MARK: Layout internals

    func isFlexible(_ s: SizeSpec) -> Bool {
        if case .fill = s { return true }
        if case .fit = s { return true }
        return false
    }

    /// Measured outer size (content + padding, clamped), excluding margin.
    func measure(available: Vec2, context: UIContext) -> Vec2 {
        let inner = Vec2(max(0, available.x - padding.horizontal), max(0, available.y - padding.vertical))
        let content = contentSize(available: inner, context: context)
        var s = content + Vec2(padding.horizontal, padding.vertical)
        if case .fixed(let w) = width { s.x = w }
        if case .percent(let p) = width { s.x = available.x * p }
        if case .fixed(let h) = height { s.y = h }
        if case .percent(let p) = height { s.y = available.y * p }
        s = pointwiseMin(pointwiseMax(s, minSize), maxSize)
        measured = s
        return s
    }

    func resolvedSize(in available: Vec2, measured m: Vec2) -> Vec2 {
        var s = m
        if case .fill = width { s.x = available.x }
        if case .fill = height { s.y = available.y }
        return pointwiseMin(pointwiseMax(s, minSize), maxSize)
    }

    func arrangeAnchored(in parentRect: Rect, context: UIContext) {
        guard let a = anchors else { return }
        let lo = parentRect.origin + parentRect.size * a.min + a.offsetMin
        let hi = parentRect.origin + parentRect.size * a.max + a.offsetMax
        arrange(Rect(origin: lo, size: pointwiseMax(hi - lo, .zero)), context: context)
    }

    func arrange(_ r: Rect, context: UIContext) {
        frame = r
        arrangeChildren(context: context)
    }

    /// Children sorted for drawing (stable by zIndex).
    var drawOrder: [UIElement] {
        children.enumerated().sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }.map(\.element)
    }

    /// Animates visual properties.
    public func animate(opacity: Float? = nil, offset: Vec2? = nil, scale: Float? = nil, duration: Float, easing: UIEasing = .easeOut, context: UIContext) {
        context.animator.add(UIAnimation(element: self, fromOpacity: self.opacity, toOpacity: opacity ?? self.opacity,
                                         fromOffset: self.offset, toOffset: offset ?? self.offset,
                                         fromScale: self.scale, toScale: scale ?? self.scale, duration: max(duration, 1e-3), easing: easing))
    }
}

/// Lays children out along an axis with spacing, `.fill` weights and cross-axis alignment.
open class UIStack: UIElement {
    public enum Axis: Sendable { case horizontal, vertical }
    public enum Justify: Sendable { case start, center, end, spaceBetween }
    public var axis: Axis
    public var spacing: Float
    public var alignment: UIAlignment
    public var justify: Justify = .start

    public init(_ axis: Axis, spacing: Float = 8, alignment: UIAlignment = .stretch, name: String = "", _ children: [UIElement] = []) {
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
        super.init(name: name)
        for c in children { add(c) }
        accessibilityRole = .group
    }

    @inline(__always) func main(_ v: Vec2) -> Float { axis == .horizontal ? v.x : v.y }
    @inline(__always) func cross(_ v: Vec2) -> Float { axis == .horizontal ? v.y : v.x }
    @inline(__always) func vec(main m: Float, cross c: Float) -> Vec2 { axis == .horizontal ? Vec2(m, c) : Vec2(c, m) }
    func mainSpec(_ e: UIElement) -> SizeSpec { axis == .horizontal ? e.width : e.height }
    func crossSpec(_ e: UIElement) -> SizeSpec { axis == .horizontal ? e.height : e.width }
    func mainMargin(_ e: UIElement) -> Float { axis == .horizontal ? e.margin.horizontal : e.margin.vertical }
    func crossMargin(_ e: UIElement) -> Float { axis == .horizontal ? e.margin.vertical : e.margin.horizontal }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        let items = children.filter { $0.isVisible && $0.anchors == nil }
        var m: Float = 0, c: Float = 0
        for e in items {
            let s = e.measure(available: available, context: context)
            if case .fill = mainSpec(e) {} else { m += main(s) }
            m += mainMargin(e)
            c = max(c, cross(s) + crossMargin(e))
        }
        m += spacing * Float(max(0, items.count - 1))
        return vec(main: m, cross: c)
    }

    open override func arrangeChildren(context: UIContext) {
        let r = contentRect
        let items = children.filter { $0.isVisible && $0.anchors == nil }
        for c in children where c.isVisible && c.anchors != nil { c.arrangeAnchored(in: r, context: context) }
        guard !items.isEmpty else { return }
        let avail = r.size
        var used: Float = spacing * Float(items.count - 1)
        var totalWeight: Float = 0
        var sizes: [Vec2] = []
        for e in items {
            let s = e.measure(available: avail, context: context)
            sizes.append(s)
            used += mainMargin(e)
            if case .fill(let w) = mainSpec(e) { totalWeight += max(w, 0.0001) } else { used += main(s) }
        }
        let free = max(0, main(avail) - used)
        var gap = spacing
        var cursor = main(r.origin)
        if totalWeight == 0 {
            switch justify {
            case .start: break
            case .center: cursor += free / 2
            case .end: cursor += free
            case .spaceBetween: if items.count > 1 { gap += free / Float(items.count - 1) }
            }
        }
        for (i, e) in items.enumerated() {
            var mainSize = main(sizes[i])
            if case .fill(let w) = mainSpec(e) { mainSize = free * max(w, 0.0001) / totalWeight }
            mainSize = min(max(mainSize, main(e.minSize)), main(e.maxSize))
            let crossAvail = cross(avail) - crossMargin(e)
            let align = e.alignSelf ?? alignment
            var crossSize = cross(sizes[i])
            switch crossSpec(e) {
            case .fixed, .percent: break
            case .fill: crossSize = crossAvail
            case .fit: if align == .stretch { crossSize = crossAvail }
            }
            crossSize = min(max(crossSize, cross(e.minSize)), cross(e.maxSize))
            let marginLead = axis == .horizontal ? e.margin.left : e.margin.top
            let crossLead = axis == .horizontal ? e.margin.top : e.margin.left
            var crossPos = cross(r.origin) + crossLead
            switch align {
            case .start, .stretch: break
            case .center: crossPos += (crossAvail - crossSize) / 2
            case .end: crossPos += crossAvail - crossSize
            }
            cursor += marginLead
            let origin = vec(main: cursor, cross: crossPos)
            e.arrange(Rect(origin: origin, size: vec(main: mainSize, cross: crossSize)), context: context)
            cursor += mainSize + mainMargin(e) - marginLead + gap
        }
    }
}

// MARK: - Animation

public enum UIEasing: Sendable {
    case linear, easeIn, easeOut, easeInOut, spring
    func apply(_ t: Float) -> Float {
        let x = t.saturated
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .easeInOut: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .spring: return 1 - cos(x * .pi * 2.5) * exp(-6 * x)
        }
    }
}

struct UIAnimation {
    weak var element: UIElement?
    var fromOpacity: Float, toOpacity: Float
    var fromOffset: Vec2, toOffset: Vec2
    var fromScale: Float, toScale: Float
    var duration: Float
    var easing: UIEasing
    var elapsed: Float = 0

    init(element: UIElement, fromOpacity: Float, toOpacity: Float, fromOffset: Vec2, toOffset: Vec2, fromScale: Float, toScale: Float,
         duration: Float, easing: UIEasing) {
        self.element = element
        self.fromOpacity = fromOpacity
        self.toOpacity = toOpacity
        self.fromOffset = fromOffset
        self.toOffset = toOffset
        self.fromScale = fromScale
        self.toScale = toScale
        self.duration = duration
        self.easing = easing
    }
}

public final class UIAnimator {
    private var animations: [UIAnimation] = []
    public init() {}
    func add(_ a: UIAnimation) {
        // A new animation on an element replaces the previous one.
        animations.removeAll { $0.element === a.element || $0.element == nil }
        animations.append(a)
    }
    public var activeCount: Int { animations.count }
    public func update(dt: Float) {
        for i in animations.indices {
            animations[i].elapsed += dt
            let a = animations[i]
            guard let e = a.element else { continue }
            let t = a.easing.apply(a.elapsed / a.duration)
            e.opacity = Float.lerp(a.fromOpacity, a.toOpacity, t)
            e.offset = a.fromOffset.lerp(to: a.toOffset, t)
            e.scale = Float.lerp(a.fromScale, a.toScale, t)
        }
        animations.removeAll { $0.element == nil || $0.elapsed >= $0.duration }
    }
}
