#if canImport(CoreText) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import FeroxCore
import Foundation

/// An 8-bit coverage atlas page filled on demand with rasterised glyphs.
public final class GlyphAtlasPage {
    public let width: Int
    public let height: Int
    public internal(set) var pixels: [UInt8]
    /// Incremented whenever glyphs are added (the renderer re-uploads on change).
    public internal(set) var revision: UInt64 = 0
    var shelfY = 1
    var shelfX = 1
    var shelfHeight = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height)
    }

    /// Shelf packing; returns the top-left of a w×h region or nil when full.
    func allocate(_ w: Int, _ h: Int) -> (Int, Int)? {
        if shelfX + w + 1 > width {
            shelfY += shelfHeight + 1
            shelfX = 1
            shelfHeight = 0
        }
        guard shelfY + h + 1 <= height, w + 2 <= width else { return nil }
        let p = (shelfX, shelfY)
        shelfX += w + 1
        shelfHeight = max(shelfHeight, h)
        return p
    }
}

/// Text layout and glyph rasterisation with Core Text (kerning, ligatures, font fallback
/// and complex scripts handled by the system shaper). Glyphs are rasterised at the
/// current `scale` (pixels per point) into `pages`, which the renderer uploads as R8 textures.
public final class CoreTextFontProvider: UIFontProvider {
    public private(set) var pages: [GlyphAtlasPage] = []
    public let pageSize: Int
    private struct GlyphKey: Hashable {
        let font: String
        let size: Int
        let glyph: CGGlyph
    }
    private struct GlyphEntry {
        let page: Int
        let uv: Rect
        let bounds: CGRect  // in pixels, relative to the pen position (y up)
    }
    private var glyphs: [GlyphKey: GlyphEntry] = [:]
    private var fonts: [UIFontDescriptor: CTFont] = [:]
    private static let runKey = NSAttributedString.Key("FeroxRunIndex")

    public init(pageSize: Int = 1024) {
        self.pageSize = pageSize
        pages = [GlyphAtlasPage(width: pageSize, height: pageSize)]
    }

    func ctFont(_ d: UIFontDescriptor, scale: Float) -> CTFont {
        let key = UIFontDescriptor(family: d.family, size: d.size * scale, bold: d.bold, italic: d.italic)
        if let f = fonts[key] { return f }
        let size = CGFloat(key.size)
        var font: CTFont
        if d.family.isEmpty || d.family == "SF Pro" || d.family == "System" {
            font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        } else {
            font = CTFontCreateWithName(d.family as CFString, size, nil)
        }
        var traits: CTFontSymbolicTraits = []
        if d.bold { traits.insert(.traitBold) }
        if d.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = styled }
        fonts[key] = font
        return font
    }

    func attributed(_ runs: [TextRun], scale: Float) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (i, r) in runs.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont(r.font, scale: scale),
                CoreTextFontProvider.runKey: i,
            ]
            s.append(NSAttributedString(string: r.text, attributes: attrs))
        }
        return s
    }

    public func lineHeight(_ font: UIFontDescriptor) -> Float {
        let f = ctFont(font, scale: 1)
        return Float(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)).rounded(.up)
    }

    public func measure(_ runs: [TextRun], maxWidth: Float?) -> Vec2 {
        guard !runs.isEmpty else { return .zero }
        let fs = CTFramesetterCreateWithAttributedString(attributed(runs, scale: 1))
        let constraint = CGSize(width: CGFloat(maxWidth ?? .greatestFiniteMagnitude), height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, constraint, nil)
        return Vec2(Float(size.width).rounded(.up), Float(size.height).rounded(.up))
    }

    public func caretPositions(_ text: String, font: UIFontDescriptor) -> [Float] {
        let line = CTLineCreateWithAttributedString(attributed([TextRun(text: text, font: font, color: nil)], scale: 1))
        var xs: [Float] = [0]
        var utf16 = 0
        for ch in text {
            utf16 += ch.utf16.count
            xs.append(Float(CTLineGetOffsetForStringIndex(line, utf16, nil)))
        }
        return xs
    }

    public func layout(_ runs: [TextRun], origin: Vec2, maxWidth: Float?, alignment: TextAlignment, scale: Float) -> [(atlas: Int, color: Color?, quads: [GlyphQuad])] {
        guard !runs.isEmpty else { return [] }
        let s = max(scale, 0.5)
        let str = attributed(runs, scale: s)
        let fs = CTFramesetterCreateWithAttributedString(str)
        let width = CGFloat((maxWidth ?? 100_000) * s)
        let pathHeight: CGFloat = 1_000_000
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: pathHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var groups: [Int: [Int: [GlyphQuad]]] = [:]  // run index → page → quads
        for (li, line) in lines.enumerated() {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            var dx: CGFloat = 0
            if maxWidth != nil {
                switch alignment {
                case .leading: dx = 0
                case .center: dx = (width - lineWidth) / 2
                case .trailing: dx = width - lineWidth
                }
            }
            let baselineDown = pathHeight - origins[li].y
            guard let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in glyphRuns {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runIndex = (attrs[CoreTextFontProvider.runKey.rawValue] as? Int) ?? 0
                let font: CTFont
                if let f = attrs[kCTFontAttributeName as String], CFGetTypeID(f as CFTypeRef) == CTFontGetTypeID() {
                    font = f as! CTFont  // type checked above; Core Text substitutes fallback fonts per run
                } else {
                    font = ctFont(runs[min(runIndex, runs.count - 1)].font, scale: s)
                }
                var gl = [CGGlyph](repeating: 0, count: count)
                var pos = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gl)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
                for i in 0..<count {
                    guard let entry = glyph(gl[i], font: font) else { continue }
                    let penX = origins[li].x + pos[i].x + dx
                    let x = (penX + entry.bounds.minX) / CGFloat(s)
                    let top = (baselineDown - entry.bounds.maxY) / CGFloat(s)
                    let q = GlyphQuad(
                        frame: Rect(x: origin.x + Float(x), y: origin.y + Float(top),
                                    width: Float(entry.bounds.width / CGFloat(s)), height: Float(entry.bounds.height / CGFloat(s))),
                        uv: entry.uv)
                    groups[runIndex, default: [:]][entry.page, default: []].append(q)
                }
            }
        }
        var out: [(atlas: Int, color: Color?, quads: [GlyphQuad])] = []
        for (ri, pagesForRun) in groups.sorted(by: { $0.key < $1.key }) {
            for (page, quads) in pagesForRun.sorted(by: { $0.key < $1.key }) {
                out.append((page, runs[min(ri, runs.count - 1)].color, quads))
            }
        }
        return out
    }

    /// Rasterises (or fetches) a glyph. Returns nil for empty glyphs (spaces).
    private func glyph(_ g: CGGlyph, font: CTFont) -> GlyphEntry? {
        let name = CTFontCopyPostScriptName(font) as String
        let key = GlyphKey(font: name, size: Int(CTFontGetSize(font) * 4), glyph: g)
        if let e = glyphs[key] { return e }
        var glyph = g
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &rect, 1)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let pad: CGFloat = 1
        let bounds = rect.insetBy(dx: -pad, dy: -pad).integral
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0, w < pageSize, h < pageSize else { return nil }
        var pageIndex = pages.count - 1
        var slot = pages[pageIndex].allocate(w, h)
        if slot == nil {
            pages.append(GlyphAtlasPage(width: pageSize, height: pageSize))
            pageIndex = pages.count - 1
            slot = pages[pageIndex].allocate(w, h)
        }
        guard let origin = slot else { return nil }
        let (sx, sy) = origin
        var bitmap = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = bitmap.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldAntialias(true)
            ctx.setFillColor(gray: 1, alpha: 1)
            var p = CGPoint(x: -bounds.minX, y: -bounds.minY)
            CTFontDrawGlyphs(font, &glyph, &p, 1, ctx)
            return true
        }
        guard ok else { return nil }
        // Bitmap-context memory is top row first, matching the atlas layout.
        let page = pages[pageIndex]
        for row in 0..<h {
            let src = row * w
            let dst = (sy + row) * page.width + sx
            page.pixels.replaceSubrange(dst..<(dst + w), with: bitmap[src..<(src + w)])
        }
        page.revision &+= 1
        let uv = Rect(x: Float(sx) / Float(page.width), y: Float(sy) / Float(page.height),
                      width: Float(w) / Float(page.width), height: Float(h) / Float(page.height))
        let entry = GlyphEntry(page: pageIndex, uv: uv, bounds: bounds)
        glyphs[key] = entry
        return entry
    }
}
#endif
