import FeroxCore
import Foundation

/// Text label with optional rich-text markup and wrapping.
open class UILabel: UIElement {
    public var text: String { didSet { cachedRuns = nil } }
    public var font: UIFontDescriptor? { didSet { cachedRuns = nil } }
    public var color: Color?
    public var alignment: TextAlignment = .leading
    public var wraps = false
    public var richText = true
    private var cachedRuns: [TextRun]?
    private var cachedFont: UIFontDescriptor?

    public init(_ text: String, font: UIFontDescriptor? = nil, color: Color? = nil, name: String = "") {
        self.text = text
        self.font = font
        self.color = color
        super.init(name: name)
        accessibilityRole = .staticText
    }

    func runs(_ context: UIContext) -> [TextRun] {
        let f = font ?? context.theme.font
        if let c = cachedRuns, cachedFont == f { return c }
        let r = richText ? RichText.parse(text, base: f) : [TextRun(text: text, font: f, color: nil)]
        cachedRuns = r
        cachedFont = f
        return r
    }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        context.fonts.measure(runs(context), maxWidth: wraps ? available.x : nil)
    }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        super.draw(&list, context: context)
        let r = contentRect
        let base = color ?? (isEffectivelyEnabled ? context.theme.text : context.theme.textMuted)
        let size = context.fonts.measure(runs(context), maxWidth: wraps ? r.width : nil)
        let y = r.minY + max(0, (r.height - size.y) / 2)
        for group in context.fonts.layout(
            runs(context), origin: Vec2(r.minX, y), maxWidth: wraps || alignment != .leading ? r.width : nil,
            alignment: alignment, scale: context.scaleFactor)
        {
            list.glyphs(
                group.quads, atlas: group.atlas,
                color: (group.color ?? base).withAlpha((group.color ?? base).a * context.currentOpacity))
        }
    }

    public var plainText: String { richText ? RichText.plainText(text) : text }
}

/// Image from a texture asset (or a region of an atlas).
open class UIImage: UIElement {
    public var texture: AssetID
    public var uv: Rect = .unit
    public var tint: Color = .white
    /// Keep the image's aspect ratio inside the frame.
    public var preserveAspect = true
    public var nativeSize: Vec2

    public init(_ texture: AssetID, size: Vec2, uv: Rect = .unit, name: String = "") {
        self.texture = texture
        nativeSize = size
        self.uv = uv
        super.init(name: name)
        accessibilityRole = .image
    }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 { nativeSize }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        super.draw(&list, context: context)
        var r = contentRect
        if preserveAspect, nativeSize.x > 0, nativeSize.y > 0, r.width > 0, r.height > 0 {
            let s = min(r.width / nativeSize.x, r.height / nativeSize.y)
            let sz = nativeSize * s
            r = Rect(origin: r.center - sz / 2, size: sz)
        }
        list.image(r, texture, uv: uv, tint: tint.withAlpha(tint.a * context.currentOpacity), radius: cornerRadius)
    }
}

/// Push button with hover/pressed/focus/disabled states.
open class UIButton: UIElement {
    public let label: UILabel
    public var style: Style = .standard
    public enum Style: Sendable { case standard, primary, borderless }

    public init(_ title: String, style: Style = .standard, name: String = "", action: (() -> Void)? = nil) {
        label = UILabel(title)
        label.alignment = .center
        self.style = style
        super.init(name: name.isEmpty ? title : name)
        padding = EdgeInsets(horizontal: 14, vertical: 8)
        add(label)
        onClick = action
        accessibilityRole = .button
        accessibilityLabel = label.plainText
    }

    open override var isFocusable: Bool { isEffectivelyEnabled && isVisible }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        let s = super.contentSize(available: available, context: context)
        let m = context.theme.minimumHitSize
        return pointwiseMax(s, Vec2(m, m) - Vec2(padding.horizontal, padding.vertical))
    }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        let t = context.theme
        let enabled = isEffectivelyEnabled
        var fill: Color
        switch style {
        case .primary: fill = isPressed ? t.accent * 0.8 : (isHovered ? t.accent * 1.1 : t.accent)
        case .standard: fill = isPressed ? t.surfacePressed : (isHovered ? t.surfaceHover : t.surface)
        case .borderless: fill = isPressed ? t.surfacePressed : (isHovered ? t.surfaceHover : .clear)
        }
        if !enabled { fill = fill.withAlpha(fill.a * 0.4) }
        let o = context.currentOpacity
        list.rect(
            frame, fill.withAlpha(fill.a * o), radius: t.cornerRadius, border: style == .standard ? 1 : 0,
            borderColor: t.border.withAlpha(o))
        if isFocused {
            list.rect(
                frame.insetBy(EdgeInsets(all: -3)), .clear, radius: t.cornerRadius + 3, border: 2,
                borderColor: t.focusRing.withAlpha(o))
        }
        label.color = style == .primary ? t.accentText : (enabled ? t.text : t.textMuted)
    }

    open override func handle(_ event: UIEvent, context: UIContext) -> Bool {
        guard isEffectivelyEnabled else { return false }
        switch event {
        case .pointerUp(_, let inside):
            if inside { onClick?() }
            return true
        case .pointerDown: return true
        case .activate:
            onClick?()
            return true
        default: return false
        }
    }
}

/// Checkbox-style toggle.
open class UIToggle: UIElement {
    public var isOn: Bool
    public var onChange: ((Bool) -> Void)?
    public let label: UILabel

    public init(_ title: String, isOn: Bool = false, name: String = "", onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        label = UILabel(title)
        super.init(name: name.isEmpty ? title : name)
        padding = EdgeInsets(top: 4, left: 30, bottom: 4, right: 4)
        add(label)
        accessibilityRole = .checkbox
        accessibilityLabel = label.plainText
    }

    open override var isFocusable: Bool { isEffectivelyEnabled && isVisible }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        let t = context.theme
        let o = context.currentOpacity
        let box = Rect(x: frame.minX + 4, y: frame.center.y - 10, width: 20, height: 20)
        list.rect(
            box, (isOn ? t.accent : t.surface).withAlpha(o), radius: 4, border: 1, borderColor: t.border.withAlpha(o))
        if isOn { list.rect(box.insetBy(EdgeInsets(all: 6)), t.accentText.withAlpha(o), radius: 2) }
        if isFocused {
            list.rect(
                box.insetBy(EdgeInsets(all: -3)), .clear, radius: 6, border: 2, borderColor: t.focusRing.withAlpha(o))
        }
    }

    public func setOn(_ v: Bool) {
        guard v != isOn else { return }
        isOn = v
        onChange?(v)
    }

    open override func handle(_ event: UIEvent, context: UIContext) -> Bool {
        guard isEffectivelyEnabled else { return false }
        switch event {
        case .pointerUp(_, let inside):
            if inside { setOn(!isOn) }
            return true
        case .pointerDown: return true
        case .activate:
            setOn(!isOn)
            return true
        default: return false
        }
    }
}

/// Horizontal slider with optional step; supports drag, click, keyboard and controller.
open class UISlider: UIElement {
    public var value: Float
    public var range: ClosedRange<Float>
    public var step: Float?
    public var onChange: ((Float) -> Void)?

    public init(
        value: Float, range: ClosedRange<Float> = 0...1, step: Float? = nil, name: String = "",
        onChange: ((Float) -> Void)? = nil
    ) {
        self.value = min(max(value, range.lowerBound), range.upperBound)
        self.range = range
        self.step = step
        self.onChange = onChange
        super.init(name: name)
        height = .fixed(24)
        width = .fill(1)
        minSize = Vec2(80, 24)
        accessibilityRole = .slider
    }

    open override var isFocusable: Bool { isEffectivelyEnabled && isVisible }
    public var normalized: Float { (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-6) }

    public func setValue(_ v: Float) {
        var nv = min(max(v, range.lowerBound), range.upperBound)
        if let step, step > 0 { nv = range.lowerBound + ((nv - range.lowerBound) / step).rounded() * step }
        guard nv != value else { return }
        value = nv
        onChange?(nv)
    }

    func setFromPointer(_ p: Vec2) {
        let t = ((p.x - frame.minX - 8) / max(frame.width - 16, 1)).saturated
        setValue(range.lowerBound + t * (range.upperBound - range.lowerBound))
    }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        let t = context.theme
        let o = context.currentOpacity
        let track = Rect(x: frame.minX + 8, y: frame.center.y - 2, width: max(0, frame.width - 16), height: 4)
        list.rect(track, t.surfaceHover.withAlpha(o), radius: 2)
        list.rect(Rect(origin: track.origin, size: Vec2(track.width * normalized, 4)), t.accent.withAlpha(o), radius: 2)
        let knob = Rect(x: track.minX + track.width * normalized - 8, y: frame.center.y - 8, width: 16, height: 16)
        list.rect(knob, (isPressed ? t.accent : t.text).withAlpha(o), radius: 8)
        if isFocused {
            list.rect(
                knob.insetBy(EdgeInsets(all: -3)), .clear, radius: 11, border: 2, borderColor: t.focusRing.withAlpha(o))
        }
    }

    open override func handle(_ event: UIEvent, context: UIContext) -> Bool {
        guard isEffectivelyEnabled else { return false }
        let increment = step ?? (range.upperBound - range.lowerBound) / 20
        switch event {
        case .pointerDown(let p, _):
            setFromPointer(p)
            return true
        case .pointerDrag(let p, _):
            setFromPointer(p)
            return true
        case .pointerUp: return true
        case .key(.left, _), .key(.down, _):
            setValue(value - increment)
            return true
        case .key(.right, _), .key(.up, _):
            setValue(value + increment)
            return true
        case .navigate(let d) where Swift.abs(d.x) > 0.5:
            setValue(value + (d.x > 0 ? increment : -increment))
            return true
        default: return false
        }
    }
}

/// Single-line editable text field with caret, selection-free editing and placeholder.
open class UITextField: UIElement {
    public var text: String { didSet { caret = min(caret, text.count) } }
    public var placeholder: String
    public var maxLength: Int
    public var onChange: ((String) -> Void)?
    public var onSubmit: ((String) -> Void)?
    /// Caret position in characters.
    public private(set) var caret: Int
    private var blink: Float = 0

    public init(text: String = "", placeholder: String = "", maxLength: Int = 256, name: String = "") {
        self.text = text
        self.placeholder = placeholder
        self.maxLength = maxLength
        caret = text.count
        super.init(name: name)
        padding = EdgeInsets(horizontal: 10, vertical: 6)
        width = .fill(1)
        minSize = Vec2(80, 30)
        clipsChildren = true
        accessibilityRole = .textField
        accessibilityLabel = placeholder
    }

    open override var isFocusable: Bool { isEffectivelyEnabled && isVisible }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        Vec2(120, context.fonts.lineHeight(context.theme.font))
    }

    open override func tick(dt: Float, context: UIContext) {
        blink = isFocused ? (blink + dt).truncatingRemainder(dividingBy: 1) : 0
    }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        let t = context.theme
        let o = context.currentOpacity
        list.rect(
            frame, t.surfacePressed.withAlpha(o), radius: t.cornerRadius, border: isFocused ? 2 : 1,
            borderColor: (isFocused ? t.focusRing : t.border).withAlpha(o))
        let r = contentRect
        let showPlaceholder = text.isEmpty && !isFocused
        let runs = [TextRun(text: showPlaceholder ? placeholder : text, font: t.font, color: nil)]
        list.pushClip(r)
        let lh = context.fonts.lineHeight(t.font)
        for g in context.fonts.layout(
            runs, origin: Vec2(r.minX, r.center.y - lh / 2), maxWidth: nil, alignment: .leading,
            scale: context.scaleFactor)
        {
            list.glyphs(g.quads, atlas: g.atlas, color: (showPlaceholder ? t.textMuted : t.text).withAlpha(o))
        }
        if isFocused && blink < 0.6 {
            let xs = context.fonts.caretPositions(text, font: t.font)
            let x = r.minX + (caret < xs.count ? xs[caret] : (xs.last ?? 0))
            list.rect(Rect(x: x, y: r.center.y - lh / 2, width: 1.5, height: lh), t.text.withAlpha(o))
        }
        list.popClip()
    }

    func insert(_ s: String) {
        let filtered = s.filter { !$0.isNewline }
        guard !filtered.isEmpty, text.count + filtered.count <= maxLength else { return }
        let idx = text.index(text.startIndex, offsetBy: caret)
        text.insert(contentsOf: filtered, at: idx)
        caret += filtered.count
        blink = 0
        onChange?(text)
    }

    open override func handle(_ event: UIEvent, context: UIContext) -> Bool {
        guard isEffectivelyEnabled else { return false }
        switch event {
        case .pointerDown(let p, _):
            let xs = context.fonts.caretPositions(text, font: context.theme.font)
            let local = p.x - contentRect.minX
            caret =
                xs.enumerated().min { Swift.abs($0.element - local) < Swift.abs($1.element - local) }?.offset
                ?? text.count
            return true
        case .pointerUp: return true
        case .text(let s):
            insert(s)
            return true
        case .key(let k, let mods):
            switch k {
            case .left: caret = max(0, caret - 1)
            case .right: caret = min(text.count, caret + 1)
            case .home: caret = 0
            case .end: caret = text.count
            case .backspace:
                guard caret > 0 else { return true }
                let i = text.index(text.startIndex, offsetBy: caret - 1)
                text.remove(at: i)
                caret -= 1
                onChange?(text)
            case .delete:
                guard caret < text.count else { return true }
                text.remove(at: text.index(text.startIndex, offsetBy: caret))
                onChange?(text)
            case .enter:
                onSubmit?(text)
            case .v where mods.contains(.command):
                if let s = context.clipboard?.read() { insert(s) }
            case .c where mods.contains(.command):
                context.clipboard?.write(text)
            default: return false
            }
            blink = 0
            return true
        case .activate:
            return true
        default: return false
        }
    }
}

/// Clipboard bridge provided by the platform host.
public protocol UIClipboard: AnyObject {
    func read() -> String?
    func write(_ s: String)
}

/// Vertically scrolling container. Content is its single child (often a vertical stack).
open class UIScrollView: UIElement {
    public private(set) var scrollOffset: Float = 0
    public var content: UIElement
    private var velocity: Float = 0

    public init(content: UIElement, name: String = "") {
        self.content = content
        super.init(name: name)
        clipsChildren = true
        add(content)
        accessibilityRole = .scrollArea
    }

    open override var isScrollable: Bool { true }

    public var maxOffset: Float { max(0, content.frame.height - contentRect.height) }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        let s = content.measure(available: Vec2(available.x, .infinity), context: context)
        return Vec2(s.x, min(s.y, available.y.isFinite ? available.y : s.y))
    }

    open override func arrangeChildren(context: UIContext) {
        let r = contentRect
        let s = content.measure(available: Vec2(r.width, .infinity), context: context)
        scrollOffset = min(max(scrollOffset, 0), max(0, s.y - r.height))
        content.arrange(Rect(x: r.minX, y: r.minY - scrollOffset, width: r.width, height: s.y), context: context)
    }

    public func scroll(by dy: Float) {
        scrollOffset = min(max(scrollOffset + dy, 0), maxOffset)
    }

    /// Scrolls so `element` (a descendant) is fully visible.
    public func scrollToVisible(_ element: UIElement) {
        let r = contentRect
        if element.frame.minY < r.minY {
            scroll(by: element.frame.minY - r.minY)
        } else if element.frame.maxY > r.maxY {
            scroll(by: element.frame.maxY - r.maxY)
        }
    }

    open override func tick(dt: Float, context: UIContext) {
        if Swift.abs(velocity) > 1 {
            scroll(by: velocity * dt)
            velocity *= exp(-6 * dt)
        }
    }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        super.draw(&list, context: context)
    }

    /// Draws the scrollbar above the content (called by the context after children).
    func drawOverlay(_ list: inout UIDrawList, context: UIContext) {
        guard maxOffset > 0 else { return }
        let r = contentRect
        let ratio = r.height / max(content.frame.height, 1)
        let h = max(24, r.height * ratio)
        let y = r.minY + (r.height - h) * (scrollOffset / maxOffset)
        list.rect(
            Rect(x: r.maxX - 5, y: y, width: 3, height: h),
            context.theme.textMuted.withAlpha(0.6 * context.currentOpacity), radius: 1.5)
    }

    open override func handle(_ event: UIEvent, context: UIContext) -> Bool {
        switch event {
        case .scroll(let d, let precise):
            if precise { scroll(by: -d.y) } else { velocity += -d.y * 12 }
            return true
        case .pointerDrag(_, let delta):
            scroll(by: -delta.y)
            return true
        default: return false
        }
    }
}

/// Virtualised list: only rows intersecting the viewport are instantiated, so very long
/// lists stay cheap. Rows have a fixed height.
open class UIListView: UIElement {
    public var rowHeight: Float
    public var count: Int {
        didSet {
            rows.removeAll()
            removeAllChildren()
        }
    }
    public var makeRow: (Int) -> UIElement
    public private(set) var selectedIndex: Int?
    public var onSelect: ((Int) -> Void)?
    public private(set) var scrollOffset: Float = 0
    private var rows: [Int: UIElement] = [:]

    public init(count: Int, rowHeight: Float = 32, name: String = "", makeRow: @escaping (Int) -> UIElement) {
        self.count = count
        self.rowHeight = rowHeight
        self.makeRow = makeRow
        super.init(name: name)
        clipsChildren = true
        accessibilityRole = .list
    }

    open override var isScrollable: Bool { true }
    open override var isFocusable: Bool { count > 0 && isVisible }
    var maxOffset: Float { max(0, Float(count) * rowHeight - contentRect.height) }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        Vec2(available.x, Float(count) * rowHeight)
    }

    open override func arrangeChildren(context: UIContext) {
        let r = contentRect
        scrollOffset = min(max(scrollOffset, 0), maxOffset)
        let first = max(0, Int(scrollOffset / rowHeight))
        let last = min(count - 1, Int((scrollOffset + r.height) / rowHeight))
        let visible = first <= last ? Set(first...last) : []
        for (i, e) in rows where !visible.contains(i) {
            e.removeFromParent()
            rows[i] = nil
        }
        for i in visible.sorted() {
            let e =
                rows[i]
                ?? {
                    let row = makeRow(i)
                    rows[i] = row
                    add(row)
                    return row
                }()
            e.background = i == selectedIndex ? context.theme.accent.withAlpha(0.25) : nil
            e.arrange(
                Rect(x: r.minX, y: r.minY + Float(i) * rowHeight - scrollOffset, width: r.width, height: rowHeight),
                context: context)
        }
    }

    public func select(_ i: Int?) {
        guard let i, i >= 0, i < count else {
            selectedIndex = nil
            return
        }
        selectedIndex = i
        let top = Float(i) * rowHeight
        if top < scrollOffset { scrollOffset = top }
        if top + rowHeight > scrollOffset + contentRect.height { scrollOffset = top + rowHeight - contentRect.height }
        onSelect?(i)
    }

    open override func handle(_ event: UIEvent, context: UIContext) -> Bool {
        switch event {
        case .scroll(let d, _):
            scrollOffset = min(max(scrollOffset - d.y, 0), maxOffset)
            return true
        case .pointerUp(let p, true):
            select(Int((p.y - contentRect.minY + scrollOffset) / rowHeight))
            return true
        case .pointerDown: return true
        case .key(.down, _), .navigate(Vec2(0, -1)):
            select(min(count - 1, (selectedIndex ?? -1) + 1))
            return true
        case .key(.up, _), .navigate(Vec2(0, 1)):
            select(max(0, (selectedIndex ?? 1) - 1))
            return true
        default: return false
        }
    }
}

/// Drop-down selector that opens a popup list in the context's popup layer.
open class UIDropdown: UIElement {
    public var options: [String]
    public private(set) var selectedIndex: Int
    public var onChange: ((Int) -> Void)?
    private weak var popup: UIElement?

    public init(options: [String], selected: Int = 0, name: String = "", onChange: ((Int) -> Void)? = nil) {
        self.options = options
        selectedIndex = min(max(selected, 0), max(options.count - 1, 0))
        self.onChange = onChange
        super.init(name: name)
        padding = EdgeInsets(horizontal: 12, vertical: 6)
        minSize = Vec2(120, 30)
        accessibilityRole = .popUpButton
    }

    open override var isFocusable: Bool { isEffectivelyEnabled && isVisible }
    public var isOpen: Bool { popup != nil }

    open override func contentSize(available: Vec2, context: UIContext) -> Vec2 {
        let f = context.theme.font
        let w =
            options.map { context.fonts.measure([TextRun(text: $0, font: f, color: nil)], maxWidth: nil).x }.max() ?? 0
        return Vec2(w + 20, context.fonts.lineHeight(f))
    }

    open override func draw(_ list: inout UIDrawList, context: UIContext) {
        let t = context.theme
        let o = context.currentOpacity
        list.rect(
            frame, (isHovered ? t.surfaceHover : t.surface).withAlpha(o), radius: t.cornerRadius, border: 1,
            borderColor: t.border.withAlpha(o))
        if isFocused {
            list.rect(
                frame.insetBy(EdgeInsets(all: -3)), .clear, radius: t.cornerRadius + 3, border: 2,
                borderColor: t.focusRing.withAlpha(o))
        }
        let r = contentRect
        let title = options.indices.contains(selectedIndex) ? options[selectedIndex] : ""
        let lh = context.fonts.lineHeight(t.font)
        for g in context.fonts.layout(
            [TextRun(text: title + "  ▾", font: t.font, color: nil)], origin: Vec2(r.minX, r.center.y - lh / 2),
            maxWidth: nil, alignment: .leading, scale: context.scaleFactor)
        {
            list.glyphs(g.quads, atlas: g.atlas, color: t.text.withAlpha(o))
        }
    }

    public func select(_ i: Int) {
        guard options.indices.contains(i), i != selectedIndex else { return }
        selectedIndex = i
        onChange?(i)
    }

    func openPopup(_ context: UIContext) {
        let menu = UIStack(.vertical, spacing: 0, name: "\(name).popup")
        menu.background = context.theme.surface
        menu.borderWidth = 1
        menu.borderColor = context.theme.border
        menu.cornerRadius = context.theme.cornerRadius
        menu.padding = EdgeInsets(all: 4)
        for (i, o) in options.enumerated() {
            let b = UIButton(o, style: .borderless) { [weak self, weak context] in
                self?.select(i)
                if let context { self?.closePopup(context) }
            }
            b.label.alignment = .leading
            menu.add(b)
        }
        let size = menu.measure(available: Vec2(frame.width, 400), context: context)
        menu.anchors = Anchors(
            min: .zero, max: .zero, offsetMin: Vec2(frame.minX, frame.maxY + 4),
            offsetMax: Vec2(frame.minX + max(frame.width, size.x), frame.maxY + 4 + size.y))
        context.presentPopup(menu, owner: self)
        popup = menu
        if let first = menu.children.indices.contains(selectedIndex)
            ? menu.children[selectedIndex] : menu.children.first
        {
            context.focus(first)
        }
    }

    func closePopup(_ context: UIContext) {
        if let p = popup { context.dismissPopup(p) }
        popup = nil
        context.focus(self)
    }

    open override func handle(_ event: UIEvent, context: UIContext) -> Bool {
        guard isEffectivelyEnabled else { return false }
        switch event {
        case .pointerUp(_, true), .activate:
            if isOpen { closePopup(context) } else { openPopup(context) }
            return true
        case .pointerDown: return true
        default: return false
        }
    }
}
