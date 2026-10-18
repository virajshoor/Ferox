import FeroxCore
import Foundation

/// A run of uniformly styled text produced by the rich-text parser.
public struct TextRun: Sendable, Hashable {
    public var text: String
    public var font: UIFontDescriptor
    public var color: Color?
}

/// Lays out text into glyph quads. Implemented by `CoreTextFontProvider` on Apple
/// platforms and by `MonospaceFontProvider` (deterministic metrics) for tests and headless use.
public protocol UIFontProvider: AnyObject {
    /// Size of laid-out text, wrapping at `maxWidth` (nil = single line).
    func measure(_ runs: [TextRun], maxWidth: Float?) -> Vec2
    /// Glyph quads at `origin` (top-left), grouped per atlas page and colour.
    func layout(_ runs: [TextRun], origin: Vec2, maxWidth: Float?, alignment: TextAlignment, scale: Float) -> [(atlas: Int, color: Color?, quads: [GlyphQuad])]
    /// Line height for a font.
    func lineHeight(_ font: UIFontDescriptor) -> Float
    /// Caret x positions (one per grapheme boundary, starting at 0) for single-line text.
    func caretPositions(_ text: String, font: UIFontDescriptor) -> [Float]
}

public enum TextAlignment: String, Sendable, Codable { case leading, center, trailing }

/// Minimal markup: `<b>`, `<i>`, `<color=#RRGGBB>`, `<size=N>` with matching closing tags.
/// Unknown tags are rendered literally; nesting is supported; malformed input never fails.
public enum RichText {
    public static func parse(_ s: String, base: UIFontDescriptor) -> [TextRun] {
        var runs: [TextRun] = []
        var fontStack = [base]
        var colorStack: [Color?] = [nil]
        var buffer = ""
        func flush() {
            if !buffer.isEmpty {
                runs.append(TextRun(text: buffer, font: fontStack.last!, color: colorStack.last!))
                buffer = ""
            }
        }
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
                let tag = String(s[s.index(after: i)..<close])
                var handled = true
                switch tag {
                case "b": flush(); fontStack.append(fontStack.last!.with(bold: true))
                case "i": flush(); fontStack.append(fontStack.last!.with(italic: true))
                case "/b", "/i", "/size":
                    flush()
                    if fontStack.count > 1 { fontStack.removeLast() }
                case "/color":
                    flush()
                    if colorStack.count > 1 { colorStack.removeLast() }
                default:
                    if tag.hasPrefix("color=#"), let v = UInt32(tag.dropFirst(7), radix: 16), tag.count == 13 {
                        flush()
                        colorStack.append(Color(hex: v))
                    } else if tag.hasPrefix("size="), let v = Float(tag.dropFirst(5)), v > 0, v <= 512 {
                        flush()
                        fontStack.append(fontStack.last!.with(size: v))
                    } else {
                        handled = false
                    }
                }
                if handled {
                    i = s.index(after: close)
                    continue
                }
            }
            buffer.append(s[i])
            i = s.index(after: i)
        }
        flush()
        return runs
    }

    /// Strips markup, returning plain text (for accessibility labels and measurement caches).
    public static func plainText(_ s: String) -> String {
        parse(s, base: UIFontDescriptor(family: "", size: 1)).map(\.text).joined()
    }
}

/// Deterministic fixed-advance font metrics (advance = 0.6 × size, line height = 1.25 × size).
/// Produces quads into atlas page 0 with placeholder UVs; useful for layout tests.
public final class MonospaceFontProvider: UIFontProvider {
    public init() {}
    public func lineHeight(_ font: UIFontDescriptor) -> Float { (font.size * 1.25).rounded() }

    func lines(_ runs: [TextRun], maxWidth: Float?) -> [[(Character, UIFontDescriptor, Color?)]] {
        var lines: [[(Character, UIFontDescriptor, Color?)]] = [[]]
        var width: Float = 0
        for r in runs {
            for ch in r.text {
                if ch == "\n" {
                    lines.append([])
                    width = 0
                    continue
                }
                let adv = r.font.size * 0.6
                if let maxWidth, width + adv > maxWidth, !lines[lines.count - 1].isEmpty {
                    // Wrap at the last space on the line if possible.
                    if let sp = lines[lines.count - 1].lastIndex(where: { $0.0 == " " }) {
                        let tail = Array(lines[lines.count - 1][(sp + 1)...])
                        lines[lines.count - 1].removeSubrange(sp...)
                        lines.append(tail)
                        width = tail.reduce(0) { $0 + $1.1.size * 0.6 }
                    } else {
                        lines.append([])
                        width = 0
                    }
                }
                lines[lines.count - 1].append((ch, r.font, r.color))
                width += adv
            }
        }
        return lines
    }

    public func measure(_ runs: [TextRun], maxWidth: Float?) -> Vec2 {
        let ls = lines(runs, maxWidth: maxWidth)
        let w = ls.map { $0.reduce(0) { $0 + $1.1.size * 0.6 } }.max() ?? 0
        let h = ls.reduce(Float(0)) { acc, line in acc + lineHeight(line.first?.1 ?? runs.first?.font ?? UIFontDescriptor(family: "", size: 15)) }
        return Vec2(w, h)
    }

    public func layout(_ runs: [TextRun], origin: Vec2, maxWidth: Float?, alignment: TextAlignment, scale: Float) -> [(atlas: Int, color: Color?, quads: [GlyphQuad])] {
        var out: [(atlas: Int, color: Color?, quads: [GlyphQuad])] = []
        var y = origin.y
        let ls = lines(runs, maxWidth: maxWidth)
        let blockWidth = maxWidth ?? (ls.map { $0.reduce(0) { $0 + $1.1.size * 0.6 } }.max() ?? 0)
        for line in ls {
            let lw = line.reduce(0) { $0 + $1.1.size * 0.6 }
            var x = origin.x + (alignment == .center ? (blockWidth - lw) / 2 : alignment == .trailing ? blockWidth - lw : 0)
            let lh = lineHeight(line.first?.1 ?? runs.first?.font ?? UIFontDescriptor(family: "", size: 15))
            var quads: [GlyphQuad] = []
            for (ch, f, _) in line {
                if ch != " " { quads.append(GlyphQuad(frame: Rect(x: x, y: y, width: f.size * 0.6, height: f.size), uv: .unit)) }
                x += f.size * 0.6
            }
            out.append((0, line.first?.2, quads))
            y += lh
        }
        return out
    }

    public func caretPositions(_ text: String, font: UIFontDescriptor) -> [Float] {
        var xs: [Float] = [0]
        var x: Float = 0
        for _ in text {
            x += font.size * 0.6
            xs.append(x)
        }
        return xs
    }
}
