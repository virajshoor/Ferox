import Foundation

/// Linear-space RGBA colour with straight (non-premultiplied) alpha.
///
/// All lighting maths in Ferox happens in linear space; use `init(srgb:)`/`srgbHex`
/// when working with colours authored in sRGB (colour pickers, CSS-style hex codes).
@frozen
public struct Color: Hashable, Codable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float

    @inlinable public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    @inlinable public init(_ v: Vec4) { self.init(v.x, v.y, v.z, v.w) }
    @inlinable public var vector: Vec4 { Vec4(r, g, b, a) }
    @inlinable public var rgb: Vec3 { Vec3(r, g, b) }
    @inlinable public var premultiplied: Vec4 { Vec4(r * a, g * a, b * a, a) }

    /// Creates a linear colour from sRGB-encoded components.
    public init(srgb r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.init(Color.srgbToLinear(r), Color.srgbToLinear(g), Color.srgbToLinear(b), a)
    }

    /// Creates a linear colour from a `0xRRGGBB` or `0xRRGGBBAA` sRGB hex value.
    public init(hex: UInt32, hasAlpha: Bool = false) {
        let v = hasAlpha ? hex : (hex << 8) | 0xFF
        self.init(
            srgb: Float((v >> 24) & 0xFF) / 255, Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255,
            Float(v & 0xFF) / 255)
    }

    @inlinable public static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    @inlinable public static func linearToSrgb(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    public var srgb: Vec4 { Vec4(Color.linearToSrgb(r), Color.linearToSrgb(g), Color.linearToSrgb(b), a) }

    @inlinable public func withAlpha(_ a: Float) -> Color { Color(r, g, b, a) }
    @inlinable public func lerp(to o: Color, _ t: Float) -> Color { Color(vector.lerp(to: o.vector, t)) }
    @inlinable public static func * (c: Color, s: Float) -> Color { Color(c.r * s, c.g * s, c.b * s, c.a) }
    @inlinable public static func * (a: Color, b: Color) -> Color { Color(a.vector * b.vector) }

    /// Relative luminance (Rec. 709 coefficients, linear input).
    @inlinable public var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Hue/saturation/value constructor; `h` in [0, 1). The result is interpreted as sRGB.
    public static func hsv(_ h: Float, _ s: Float, _ v: Float, alpha: Float = 1) -> Color {
        let hh = (h - h.rounded(.down)) * 6
        let i = Int(hh)
        let f = hh - Float(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Float, Float, Float)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return Color(srgb: r, g, b, alpha)
    }

    public static let white = Color(1, 1, 1)
    public static let black = Color(0, 0, 0)
    public static let clear = Color(0, 0, 0, 0)
    public static let red = Color(1, 0, 0)
    public static let green = Color(0, 1, 0)
    public static let blue = Color(0, 0, 1)
    public static let yellow = Color(1, 1, 0)
    public static let cyan = Color(0, 1, 1)
    public static let magenta = Color(1, 0, 1)
    public static let gray = Color(0.2158605, 0.2158605, 0.2158605)  // sRGB 0.5

    /// The Ferox brand accent (sRGB #FF5A1F, "ferric orange").
    public static let feroxAccent = Color(hex: 0xFF5A1F)
}

/// A colour gradient with arbitrary stops, evaluated in linear space.
public struct Gradient: Hashable, Codable, Sendable {
    public struct Stop: Hashable, Codable, Sendable {
        public var position: Float
        public var color: Color
        public init(_ position: Float, _ color: Color) { self.position = position; self.color = color }
    }
    public var stops: [Stop]

    public init(stops: [Stop]) { self.stops = stops.sorted { $0.position < $1.position } }
    public init(_ a: Color, _ b: Color) { self.init(stops: [Stop(0, a), Stop(1, b)]) }

    public func evaluate(_ t: Float) -> Color {
        guard let first = stops.first, let last = stops.last else { return .white }
        if t <= first.position { return first.color }
        if t >= last.position { return last.color }
        for i in 1..<stops.count where t <= stops[i].position {
            let a = stops[i - 1], b = stops[i]
            let span = b.position - a.position
            return a.color.lerp(to: b.color, span > 0 ? (t - a.position) / span : 0)
        }
        return last.color
    }
}
