import FeroxCore
import FeroxUI
import Foundation

/// Texture bound by a UI draw.
public enum UITextureBinding: Sendable, Hashable {
    /// Solid shapes only; the renderer binds its white texture.
    case none
    case image(AssetID)
    /// Font atlas page.
    case glyphAtlas(Int)
}

/// One UI draw call: a contiguous index range with one texture and scissor rectangle.
public struct UIBatch: Sendable, Hashable {
    public var texture: UITextureBinding
    /// Scissor rectangle in points (nil = whole viewport).
    public var clip: Rect?
    public var firstIndex: Int
    public var indexCount: Int
}

/// GPU-ready UI geometry for one frame.
public struct UIFrameData {
    public var vertices: [UIVertex] = []
    public var indices: [UInt32] = []
    public var batches: [UIBatch] = []
    public var uniforms = UIUniforms()
    public init() {}
}

/// Converts a `UIDrawList` into vertices and draws. Solid quads do not sample a texture,
/// so they join whichever batch is open; batches split only on texture or clip changes.
public enum UIBatcher {
    /// - Parameters:
    ///   - viewportSize: drawable size in points.
    ///   - scale: backing scale factor (pixels per point).
    public static func build(_ list: UIDrawList, viewportSize: Vec2, scale: Float) -> UIFrameData {
        var out = UIFrameData()
        out.uniforms.viewport = Vec4(max(viewportSize.x, 1), max(viewportSize.y, 1), scale, scale)
        var clipStack: [Rect] = []
        var current: UIBatch?

        func flush() {
            if let c = current, c.indexCount > 0 { out.batches.append(c) }
            current = nil
        }
        func begin(_ tex: UITextureBinding) {
            let clip = clipStack.last
            if var c = current, c.clip == clip {
                if c.texture == tex || tex == .none { return }
                if c.texture == .none {
                    // Promote a solid-only batch to the texture now needed.
                    c.texture = tex
                    current = c
                    return
                }
            }
            flush()
            current = UIBatch(texture: tex, clip: clip, firstIndex: out.indices.count, indexCount: 0)
        }
        func quad(
            _ r: Rect, uv: Rect, top: Vec4, bottom: Vec4, mode: Float, radius: Float,
            border: Float, borderColor: Vec4, pad: Float
        ) {
            let q = Rect(x: r.minX - pad, y: r.minY - pad, width: r.width + 2 * pad, height: r.height + 2 * pad)
            let rectInfo = Vec4(r.minX + r.width * 0.5, r.minY + r.height * 0.5, r.width * 0.5, r.height * 0.5)
            let params = Vec4(radius, border, mode, 0)
            // UVs follow the padded quad so textures stay aligned with the rect.
            let du = r.width > 0 ? uv.width / r.width * pad : 0
            let dv = r.height > 0 ? uv.height / r.height * pad : 0
            let corners: [(Vec2, Vec2, Vec4)] = [
                (Vec2(q.minX, q.minY), Vec2(uv.minX - du, uv.minY - dv), top),
                (Vec2(q.maxX, q.minY), Vec2(uv.maxX + du, uv.minY - dv), top),
                (Vec2(q.maxX, q.maxY), Vec2(uv.maxX + du, uv.maxY + dv), bottom),
                (Vec2(q.minX, q.maxY), Vec2(uv.minX - du, uv.maxY + dv), bottom),
            ]
            let base = UInt32(out.vertices.count)
            for c in corners {
                out.vertices.append(
                    UIVertex(
                        position: c.0, uv: c.1, color: c.2, rect: rectInfo, params: params,
                        borderColor: borderColor))
            }
            out.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            current?.indexCount += 6
        }

        for cmd in list.commands {
            switch cmd {
            case .rect(let frame, let color, let bottomColor, let radius, let borderWidth, let borderColor):
                guard frame.width > 0, frame.height > 0 else { continue }
                begin(.none)
                quad(
                    frame, uv: .unit, top: color.premultiplied, bottom: (bottomColor ?? color).premultiplied, mode: 0,
                    radius: radius, border: borderWidth, borderColor: borderColor.premultiplied, pad: 1)
            case .image(let frame, let texture, let uv, let tint, let radius):
                guard frame.width > 0, frame.height > 0 else { continue }
                begin(.image(texture))
                quad(
                    frame, uv: uv, top: tint.premultiplied, bottom: tint.premultiplied, mode: 1, radius: radius,
                    border: 0, borderColor: .zero, pad: radius > 0 ? 1 : 0)
            case .glyphs(let atlas, let quads, let color):
                begin(.glyphAtlas(atlas))
                let c = color.premultiplied
                for g in quads where g.frame.width > 0 && g.frame.height > 0 {
                    quad(
                        g.frame, uv: g.uv, top: c, bottom: c, mode: 2, radius: 0, border: 0, borderColor: .zero, pad: 0)
                }
            case .pushClip(let r):
                flush()
                clipStack.append(r)
            case .popClip:
                flush()
                if !clipStack.isEmpty { clipStack.removeLast() }
            }
        }
        flush()
        return out
    }

    /// Converts a clip rectangle in points to a pixel scissor clamped to the drawable.
    /// Returns nil when the clip is empty (the batch can be skipped).
    public static func scissor(_ clip: Rect?, scale: Float, drawable: SIMD2<Int>) -> (
        x: Int, y: Int, width: Int, height: Int
    )? {
        let w = max(drawable.x, 0)
        let h = max(drawable.y, 0)
        guard let c = clip else { return (0, 0, w, h) }
        let x0 = min(max(Int((c.minX * scale).rounded(.down)), 0), w)
        let y0 = min(max(Int((c.minY * scale).rounded(.down)), 0), h)
        let x1 = min(max(Int((c.maxX * scale).rounded(.up)), 0), w)
        let y1 = min(max(Int((c.maxY * scale).rounded(.up)), 0), h)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }
}
