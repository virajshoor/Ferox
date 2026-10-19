import FeroxCore
import Foundation

/// Backend-agnostic UI draw commands, produced by `UIContext` and consumed by the
/// renderer's UI pass. Coordinates are in UI points with the origin at the top-left;
/// the renderer multiplies by the backing scale factor.
public struct UIDrawList: Sendable {
    public enum Command: Sendable {
        /// Rounded rectangle with optional vertical gradient and border.
        case rect(
            frame: Rect, color: Color, bottomColor: Color?, cornerRadius: Float, borderWidth: Float, borderColor: Color)
        /// Textured quad (`texture` resolved by the renderer's asset bridge).
        case image(frame: Rect, texture: AssetID, uv: Rect, tint: Color, cornerRadius: Float)
        /// Glyph quads referencing the font atlas page `atlas`.
        case glyphs(atlas: Int, quads: [GlyphQuad], color: Color)
        case pushClip(Rect)
        case popClip
    }
    public private(set) var commands: [Command] = []
    private var clipStack: [Rect] = []
    public init() {}

    public mutating func rect(
        _ r: Rect, _ c: Color, bottom: Color? = nil, radius: Float = 0, border: Float = 0, borderColor: Color = .clear
    ) {
        guard c.a > 0.001 || (border > 0 && borderColor.a > 0.001) || (bottom?.a ?? 0) > 0.001 else { return }
        guard currentClip.map({ $0.intersects(r) }) ?? true else { return }
        commands.append(
            .rect(
                frame: r, color: c, bottomColor: bottom, cornerRadius: radius, borderWidth: border,
                borderColor: borderColor))
    }
    public mutating func image(_ r: Rect, _ tex: AssetID, uv: Rect = .unit, tint: Color = .white, radius: Float = 0) {
        guard currentClip.map({ $0.intersects(r) }) ?? true else { return }
        commands.append(.image(frame: r, texture: tex, uv: uv, tint: tint, cornerRadius: radius))
    }
    public mutating func glyphs(_ quads: [GlyphQuad], atlas: Int, color: Color) {
        guard !quads.isEmpty else { return }
        commands.append(.glyphs(atlas: atlas, quads: quads, color: color))
    }
    public mutating func pushClip(_ r: Rect) {
        let clipped = currentClip.map { $0.intersection(r) } ?? r
        clipStack.append(clipped)
        commands.append(.pushClip(clipped))
    }
    public mutating func popClip() {
        guard !clipStack.isEmpty else { return }
        clipStack.removeLast()
        commands.append(.popClip)
    }
    public var currentClip: Rect? { clipStack.last }
    public mutating func removeAll() {
        commands.removeAll(keepingCapacity: true)
        clipStack.removeAll()
    }
}

/// One positioned glyph: screen rectangle and atlas texture coordinates.
public struct GlyphQuad: Sendable, Hashable {
    public var frame: Rect
    public var uv: Rect
    public init(frame: Rect, uv: Rect) {
        self.frame = frame
        self.uv = uv
    }
}

/// Visual theme shared by built-in controls.
public struct UITheme: Sendable, Hashable {
    public var background = Color(hex: 0x16161A)
    public var surface = Color(hex: 0x222229)
    public var surfaceHover = Color(hex: 0x2C2C35)
    public var surfacePressed = Color(hex: 0x1B1B21)
    public var border = Color(hex: 0x3A3A45)
    public var text = Color(hex: 0xEDEDF2)
    public var textMuted = Color(hex: 0x9A9AA8)
    public var accent = Color.feroxAccent
    public var accentText = Color(hex: 0x111111)
    public var focusRing = Color(hex: 0x6CB4FF)
    public var cornerRadius: Float = 6
    public var font = UIFontDescriptor(family: "SF Pro", size: 15)
    public var spacing: Float = 8
    /// Minimum interactive size in points (accessibility guideline: 44 pt touch, 24 pt pointer).
    public var minimumHitSize: Float = 24
    public init() {}

    /// High-contrast variant for accessibility.
    public static var highContrast: UITheme {
        var t = UITheme()
        t.background = .black
        t.surface = Color(hex: 0x111111)
        t.surfaceHover = Color(hex: 0x333333)
        t.border = .white
        t.text = .white
        t.textMuted = Color(hex: 0xDDDDDD)
        t.accent = Color(hex: 0xFFD60A)
        t.focusRing = Color(hex: 0x00E5FF)
        return t
    }
}

public struct UIFontDescriptor: Sendable, Hashable {
    public var family: String
    public var size: Float
    public var bold = false
    public var italic = false
    public init(family: String, size: Float, bold: Bool = false, italic: Bool = false) {
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
    }
    public func with(size: Float? = nil, bold: Bool? = nil, italic: Bool? = nil) -> UIFontDescriptor {
        UIFontDescriptor(
            family: family, size: size ?? self.size, bold: bold ?? self.bold, italic: italic ?? self.italic)
    }
}
