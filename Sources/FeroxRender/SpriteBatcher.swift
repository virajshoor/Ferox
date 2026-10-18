import FeroxAnimation
import FeroxAssets
import FeroxCore
import FeroxScene
import Foundation

// 2D batching: sprites, shapes, tilemaps and (for orthographic cameras) CPU particles are
// sorted by sorting layer and order, transformed and tessellated into one indexed vertex
// stream, and split into draws only where texture, blend, filter or stencil state changes.
// No Metal code — the batching rules are unit-tested on Linux.

/// Stencil behaviour of a 2D draw (sprite masks).
public enum SpriteStencil: Sendable, Hashable {
    case none
    /// Writes `id` wherever the sprite's alpha passes the cut-off; no colour output.
    case write(UInt8)
    /// Draws only where the stencil equals `id`.
    case test(UInt8)
}

/// One 2D draw call: a contiguous range of `SpriteFrameData.indices`.
public struct SpriteBatch: Sendable, Hashable {
    /// nil binds the built-in white texture (shapes).
    public var texture: AssetID?
    public var normalMap: AssetID?
    public var blend: SpriteBlendMode
    public var filter: TextureFilter
    public var stencil: SpriteStencil
    public var firstIndex: Int
    public var indexCount: Int
}

/// Everything the 2D pass needs for one frame.
public struct SpriteFrameData {
    public var vertices: [SpriteVertex] = []
    public var indices: [UInt32] = []
    public var batches: [SpriteBatch] = []
    public var lights: [Light2D] = []
    public var uniforms = Sprite2DUniforms()
    /// True when any batch reads or writes the stencil buffer.
    public var usesStencil = false
    public var drawnObjects = 0
    public var culledObjects = 0
    public init() {}
    public var isEmpty: Bool { batches.isEmpty }
}

/// Builds `SpriteFrameData` from the world. Keeps a per-tilemap tessellation cache, so it
/// is a reference type owned by the renderer; it is not thread-safe.
public final class SpriteBatcher {
    /// Maximum 2D lights per frame (the shader loops over at most 64).
    public static let maxLights = 64
    /// Tiles per side of a tilemap chunk (culling and cache granularity).
    public static let chunkSize = 16

    struct TilemapChunk {
        var bounds: AABB  // local space
        var positions: [Vec2]
        var uvs: [Vec2]
    }
    struct TilemapCache {
        var revision: UInt64
        var signature: Int
        var chunks: [TilemapChunk]
    }
    private var tilemapCache: [Entity: TilemapCache] = [:]
    // Last frame's sizes, used to reserve capacity for the next frame's arrays.
    private var lastDrawableCount = 0
    private var lastVertexCount = 0
    private var lastIndexCount = 0
    private var lastBatchCount = 0

    public init() {}

    /// Number of cached tilemaps (exposed for leak tests).
    public var cachedTilemapCount: Int { tilemapCache.count }

    public func removeAllCaches() { tilemapCache.removeAll() }

    struct Drawable {
        var layer: Int
        var order: Int
        var entity: Entity
        var kind: Kind
        /// Append position; a stable tie-break, since one entity may hold a sprite and a
        /// shape with the same layer and order.
        var sequence: Int
        enum Kind {
            case sprite(SpriteRenderer, Mat4)
            case shape(ShapeRenderer, Mat4)
            case tilemap(Tilemap, Mat4)
            case particles(ParticleEmitter, ParticleState)
        }
    }

    /// Builds the 2D frame as seen by `camera` (normally `RenderFrameData.camera`).
    /// `targetSize` is the render-target size in pixels (pixel snapping).
    public func build(world: World, assets: AssetManager, camera: RenderCamera,
                      targetSize: SIMD2<Int>) -> SpriteFrameData {
        var out = SpriteFrameData()
        let cam = camera.camera

        // Pixel-perfect cameras snap their position to whole texels.
        var view = camera.view
        if cam.pixelPerfect && cam.projection == .orthographic {
            let ppu = max(cam.pixelsPerUnit, 1e-3)
            var w = camera.world
            let t = w.c3
            w.c3 = Vec4((t.x * ppu).rounded() / ppu, (t.y * ppu).rounded() / ppu, t.z, 1)
            view = w.affineInverse
        }
        let viewProjection = camera.projection * view
        let frustum = Frustum(viewProjection: viewProjection)
        let cameraXY = Vec2(camera.position.x, camera.position.y)

        func matrix(_ e: Entity) -> Mat4 {
            var m = world.get(WorldTransform.self, e)?.matrix ?? world.worldMatrix(of: e)
            if let p = world.get(Parallax.self, e) {
                // factor 1 = world-locked, 0 = follows the camera.
                let o = cameraXY * (Vec2(1, 1) - p.factor)
                m.c3.x += o.x
                m.c3.y += o.y
            }
            return m
        }
        func visible(_ e: Entity) -> Bool {
            world.isActiveInHierarchy(e) && cam.cullingMask.contains(world.get(Layer.self, e)?.mask ?? .default)
        }

        var drawables: [Drawable] = []
        drawables.reserveCapacity(lastDrawableCount)
        world.read(SpriteRenderer.self) { e, s in
            guard visible(e) else { return }
            drawables.append(Drawable(layer: s.sortingLayer, order: s.orderInLayer, entity: e, kind: .sprite(s, matrix(e)),
                                      sequence: drawables.count))
        }
        world.read(ShapeRenderer.self) { e, s in
            guard visible(e) else { return }
            drawables.append(Drawable(layer: s.sortingLayer, order: s.orderInLayer, entity: e, kind: .shape(s, matrix(e)),
                                      sequence: drawables.count))
        }
        var liveTilemaps = Set<Entity>()
        world.read(Tilemap.self) { e, t in
            guard visible(e) else { return }
            liveTilemaps.insert(e)
            drawables.append(Drawable(layer: t.sortingLayer, order: Int.min, entity: e, kind: .tilemap(t, matrix(e)),
                                      sequence: drawables.count))
        }
        // Drop caches of tilemaps that were destroyed or hidden, so they cannot leak.
        if tilemapCache.count != liveTilemaps.count || tilemapCache.keys.contains(where: { !liveTilemaps.contains($0) }) {
            tilemapCache = tilemapCache.filter { liveTilemaps.contains($0.key) }
        }
        if cam.projection == .orthographic {
            world.read(ParticleEmitter.self) { e, em in
                guard em.simulation == .cpu, let st = world.get(ParticleState.self, e), st.pool.count > 0,
                      visible(e) else { return }
                drawables.append(Drawable(layer: em.sortingLayer, order: 0, entity: e, kind: .particles(em, st),
                                          sequence: drawables.count))
            }
        }
        // A strict total order: layer, order, entity, then append sequence for ties.
        drawables.sort { a, b in
            if a.layer != b.layer { return a.layer < b.layer }
            if a.order != b.order { return a.order < b.order }
            if a.entity != b.entity { return a.entity < b.entity }
            return a.sequence < b.sequence
        }
        lastDrawableCount = drawables.count

        var emitter = BatchEmitter()
        emitter.vertices.reserveCapacity(lastVertexCount)
        emitter.indices.reserveCapacity(lastIndexCount)
        emitter.batches.reserveCapacity(lastBatchCount)
        for d in drawables {
            switch d.kind {
            case let .sprite(s, m):
                if emitSprite(s, m, assets: assets, frustum: frustum, into: &emitter) {
                    out.drawnObjects += 1
                } else {
                    out.culledObjects += 1
                }
            case let .shape(s, m):
                if emitShape(s, m, frustum: frustum, into: &emitter) { out.drawnObjects += 1 } else { out.culledObjects += 1 }
            case let .tilemap(t, m):
                if emitTilemap(t, m, entity: d.entity, assets: assets, frustum: frustum, into: &emitter) {
                    out.drawnObjects += 1
                } else {
                    out.culledObjects += 1
                }
            case let .particles(em, st):
                emitParticles(em, st, camera: camera, assets: assets, into: &emitter)
                out.drawnObjects += 1
            }
        }
        emitter.flush()
        out.vertices = emitter.vertices
        out.indices = emitter.indices
        out.batches = emitter.batches
        lastVertexCount = out.vertices.count
        lastIndexCount = out.indices.count
        lastBatchCount = out.batches.count
        out.usesStencil = out.batches.contains { $0.stencil != .none }
        out.lights = Self.lights(world: world, camera: camera, frustum: frustum)

        var u = Sprite2DUniforms()
        u.viewProjection = viewProjection
        let env = world.entities(with: Environment.self).first.flatMap { world.get(Environment.self, $0) }
        // Without 2D lights, lit sprites show their unlit colour; with lights, the
        // environment's ambient colour fills the unlit areas.
        u.ambient = out.lights.isEmpty ? Vec4(1, 1, 1, 1) : Vec4(env?.ambientColor.rgb ?? Vec3(0.1, 0.1, 0.1), 1)
        u.counts = SIMD4(UInt32(out.lights.count), 0, 0, 0)
        u.params = Vec4(cam.pixelPerfect ? 1 : 0, Float(max(targetSize.x, 1)), Float(max(targetSize.y, 1)), 0.5)
        out.uniforms = u
        return out
    }

    // MARK: Batch building

    struct BatchEmitter {
        var vertices: [SpriteVertex] = []
        var indices: [UInt32] = []
        var batches: [SpriteBatch] = []
        var current: SpriteBatch?

        mutating func begin(texture: AssetID?, normalMap: AssetID?, blend: SpriteBlendMode,
                            filter: TextureFilter, stencil: SpriteStencil) {
            if let c = current, c.texture == texture, c.normalMap == normalMap, c.blend == blend,
               c.filter == filter, c.stencil == stencil {
                return
            }
            flush()
            current = SpriteBatch(texture: texture, normalMap: normalMap, blend: blend, filter: filter,
                                  stencil: stencil, firstIndex: indices.count, indexCount: 0)
        }

        mutating func flush() {
            if let c = current, c.indexCount > 0 { batches.append(c) }
            current = nil
        }

        /// Appends triangles; `local` indices refer to `verts`.
        mutating func add(_ verts: [SpriteVertex], _ local: [UInt32]) {
            guard !verts.isEmpty, !local.isEmpty else { return }
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: verts)
            indices.append(contentsOf: local.map { $0 + base })
            current?.indexCount += local.count
        }

        mutating func quad(_ p: [Vec2], _ uv: [Vec2], _ color: Vec4, lit: Bool) {
            add((0..<4).map { SpriteVertex(position: p[$0], uv: uv[$0], color: color, lit: lit) }, [0, 1, 2, 0, 2, 3])
        }
    }

    static func xy(_ m: Mat4, _ p: Vec2) -> Vec2 {
        let w = m.transformAffine(Vec3(p.x, p.y, 0))
        return Vec2(w.x, w.y)
    }

    static func worldBounds(_ pts: [Vec2], z: Float) -> AABB {
        var lo = Vec3(repeating: .greatestFiniteMagnitude), hi = Vec3(repeating: -.greatestFiniteMagnitude)
        for p in pts {
            lo = pointwiseMin(lo, Vec3(p.x, p.y, z))
            hi = pointwiseMax(hi, Vec3(p.x, p.y, z))
        }
        lo.z -= 0.01
        hi.z += 0.01
        return AABB(min: lo, max: hi)
    }

    static func stencil(isMask: Bool, id: UInt8) -> SpriteStencil {
        if isMask { return .write(max(id, 1)) }
        return id == 0 ? .none : .test(id)
    }

    /// Premultiplied vertex colour; additive sprites keep alpha 0 so they only add light.
    static func vertexColor(_ c: Color, blend: SpriteBlendMode) -> Vec4 {
        switch blend {
        case .premultiplied: return c.vector
        case .additive: var v = c.premultiplied; v.w = 0; return v
        default: return c.premultiplied
        }
    }

    func emitSprite(_ s: SpriteRenderer, _ m: Mat4, assets: AssetManager, frustum: Frustum,
                    into e: inout BatchEmitter) -> Bool {
        let handle = assets.texture(s.texture, srgb: true)
        var size = s.size
        if size == nil {
            guard let img = handle.value else { return false }  // size unknown until loaded
            let ppu = max(s.pixelsPerUnit, 1e-3)
            size = Vec2(Float(img.width) * s.uvRect.width, Float(img.height) * s.uvRect.height) / ppu
        }
        guard let sz = size, sz.x > 0, sz.y > 0 else { return false }
        let x0 = -s.pivot.x * sz.x, y0 = -s.pivot.y * sz.y
        let local = [Vec2(x0, y0), Vec2(x0 + sz.x, y0), Vec2(x0 + sz.x, y0 + sz.y), Vec2(x0, y0 + sz.y)]
        let p = local.map { Self.xy(m, $0) }
        guard frustum.intersects(Self.worldBounds(p, z: m.c3.z)) else { return false }

        let r = s.uvRect
        var u0 = r.minX, u1 = r.maxX, vTop = r.minY, vBottom = r.maxY
        if s.flipX { swap(&u0, &u1) }
        if s.flipY { swap(&vTop, &vBottom) }
        let uv = [Vec2(u0, vBottom), Vec2(u1, vBottom), Vec2(u1, vTop), Vec2(u0, vTop)]
        if let n = s.normalMap { _ = assets.texture(n, srgb: false) }
        e.begin(texture: s.texture, normalMap: s.receives2DLighting ? s.normalMap : nil, blend: s.blend,
                filter: s.filter, stencil: Self.stencil(isMask: s.isMask, id: s.maskID))
        e.quad(p, uv, Self.vertexColor(s.color, blend: s.blend), lit: s.receives2DLighting)
        return true
    }

    func emitShape(_ s: ShapeRenderer, _ m: Mat4, frustum: Frustum, into e: inout BatchEmitter) -> Bool {
        var outline: [Vec2] = []
        var filled = true
        var closedStroke = true
        switch s.shape {
        case let .rectangle(size, radius): outline = Tessellator.roundedRect(size: size, cornerRadius: radius)
        case let .circle(radius, segments): outline = Tessellator.circle(radius: radius, segments: segments)
        case let .polygon(points): outline = points
        case let .line(a, b):
            outline = [a, b]; filled = false; closedStroke = false
        case let .polyline(points, closed):
            outline = points; filled = false; closedStroke = closed
        }
        guard !outline.isEmpty else { return false }
        let world = outline.map { Self.xy(m, $0) }
        // Pad by the stroke so thick outlines are not culled early.
        var bounds = Self.worldBounds(world, z: m.c3.z)
        let pad = max(s.strokeWidth, 0.05) * max(m.c0.xyz.length, m.c1.xyz.length)
        bounds = AABB(min: bounds.min - Vec3(pad, pad, 0), max: bounds.max + Vec3(pad, pad, 0))
        guard frustum.intersects(bounds) else { return false }

        e.begin(texture: nil, normalMap: nil, blend: .alpha, filter: .linear, stencil: .none)
        let minY = outline.map(\.y).min() ?? 0, maxY = outline.map(\.y).max() ?? 0
        let span = max(maxY - minY, 1e-6)
        func gradientColor(_ p: Vec2) -> Vec4 { s.fill.evaluate((p.y - minY) / span).premultiplied }

        if filled {
            let idx = Tessellator.triangulate(outline)
            let verts = (0..<outline.count).map { SpriteVertex(position: world[$0], uv: Vec2(0.5, 0.5), color: gradientColor(outline[$0])) }
            e.add(verts, idx)
            if s.strokeWidth > 0 {
                let st = Tessellator.stroke(outline, width: s.strokeWidth, closed: true)
                let c = s.strokeColor.premultiplied
                e.add(st.positions.map { SpriteVertex(position: Self.xy(m, $0), uv: Vec2(0.5, 0.5), color: c) }, st.indices)
            }
        } else {
            // Lines use the fill gradient along their length; zero width means a hairline
            // of 0.02 world units.
            let st = Tessellator.stroke(outline, width: s.strokeWidth > 0 ? s.strokeWidth : 0.02, closed: closedStroke)
            var lengths: [Float] = [0]
            for i in 1..<max(outline.count, 1) { lengths.append(lengths[i - 1] + outline[i].distance(to: outline[i - 1])) }
            let total = max(lengths.last ?? 0, 1e-6)
            let verts = st.positions.enumerated().map { i, p in
                let t = lengths[min(i / 2, lengths.count - 1)] / total
                return SpriteVertex(position: Self.xy(m, p), uv: Vec2(0.5, 0.5), color: s.fill.evaluate(t).premultiplied)
            }
            e.add(verts, st.indices)
        }
        return true
    }

    func emitTilemap(_ t: Tilemap, _ m: Mat4, entity: Entity, assets: AssetManager, frustum: Frustum,
                     into e: inout BatchEmitter) -> Bool {
        guard t.width > 0, t.height > 0, t.tiles.count == t.width * t.height else { return false }
        _ = assets.texture(t.tileset, srgb: true)
        var h = Hasher()
        h.combine(t.width); h.combine(t.height); h.combine(t.tileSize.x); h.combine(t.tileSize.y)
        h.combine(t.tilesetColumns); h.combine(t.tilesetRows)
        let signature = h.finalize()
        let cache: TilemapCache
        if let c = tilemapCache[entity], c.revision == t.revision, c.signature == signature {
            cache = c
        } else {
            cache = TilemapCache(revision: t.revision, signature: signature, chunks: Self.buildChunks(t))
            tilemapCache[entity] = cache
        }
        let color = t.color.premultiplied
        var any = false
        for chunk in cache.chunks where !chunk.positions.isEmpty {
            guard frustum.intersects(chunk.bounds.transformed(by: m)) else { continue }
            if !any {
                e.begin(texture: t.tileset, normalMap: nil, blend: .alpha, filter: .nearest, stencil: .none)
                any = true
            }
            let quads = chunk.positions.count / 4
            var verts: [SpriteVertex] = []
            verts.reserveCapacity(chunk.positions.count)
            for i in 0..<chunk.positions.count {
                verts.append(SpriteVertex(position: Self.xy(m, chunk.positions[i]), uv: chunk.uvs[i], color: color))
            }
            var idx: [UInt32] = []
            idx.reserveCapacity(quads * 6)
            for q in 0..<quads {
                let b = UInt32(q * 4)
                idx += [b, b + 1, b + 2, b, b + 2, b + 3]
            }
            e.add(verts, idx)
        }
        return any
    }

    static func buildChunks(_ t: Tilemap) -> [TilemapChunk] {
        let cs = chunkSize
        var chunks: [TilemapChunk] = []
        let maxTile = Int32(t.tilesetColumns * t.tilesetRows)
        // Half-texel inset avoids bleeding from neighbouring tiles under filtering.
        let inset = Vec2(0.5 / Float(max(t.tilesetColumns * 64, 1)), 0.5 / Float(max(t.tilesetRows * 64, 1)))
        for cy in stride(from: 0, to: t.height, by: cs) {
            for cx in stride(from: 0, to: t.width, by: cs) {
                var pos: [Vec2] = [], uv: [Vec2] = []
                for y in cy..<min(cy + cs, t.height) {
                    for x in cx..<min(cx + cs, t.width) {
                        let tile = t.tiles[y * t.width + x]
                        guard tile >= 0, tile < maxTile else { continue }
                        let x0 = Float(x) * t.tileSize.x, y0 = Float(y) * t.tileSize.y
                        let x1 = x0 + t.tileSize.x, y1 = y0 + t.tileSize.y
                        pos += [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
                        let r = t.uvRect(for: tile)
                        let u0 = r.minX + inset.x, u1 = r.maxX - inset.x
                        let vt = r.minY + inset.y, vb = r.maxY - inset.y
                        uv += [Vec2(u0, vb), Vec2(u1, vb), Vec2(u1, vt), Vec2(u0, vt)]
                    }
                }
                let lo = Vec3(Float(cx) * t.tileSize.x, Float(cy) * t.tileSize.y, -0.01)
                let hi = Vec3(Float(min(cx + cs, t.width)) * t.tileSize.x, Float(min(cy + cs, t.height)) * t.tileSize.y, 0.01)
                chunks.append(TilemapChunk(bounds: AABB(min: pointwiseMin(lo, hi), max: pointwiseMax(lo, hi)), positions: pos, uvs: uv))
            }
        }
        return chunks
    }

    func emitParticles(_ em: ParticleEmitter, _ st: ParticleState, camera: RenderCamera, assets: AssetManager,
                       into e: inout BatchEmitter) {
        let pool = st.pool
        if let t = em.texture { _ = assets.texture(t, srgb: true) }
        e.begin(texture: em.texture, normalMap: nil, blend: em.blend, filter: .linear, stencil: .none)
        let local = em.space == .local
        let cols = max(em.sheetGrid.x, 1), rows = max(em.sheetGrid.y, 1)
        let frames = cols * rows
        var verts: [SpriteVertex] = []
        var idx: [UInt32] = []
        verts.reserveCapacity(pool.count * 4)
        idx.reserveCapacity(pool.count * 6)
        for i in 0..<pool.count {
            let t = min(max(pool.ages[i] / max(pool.lifetimes[i], 1e-4), 0), 1)
            let p3 = local ? st.emitterMatrix.transformAffine(pool.positions[i]) : pool.positions[i]
            let size = pool.sizes[i] * (em.sizeOverLifetime.sample(t) ?? 1) * 0.5
            let c = Self.vertexColor(em.colorOverLifetime.evaluate(t), blend: em.blend)
            let rot = pool.rotations[i]
            let cs = cos(rot), sn = sin(rot)
            let corners = [Vec2(-1, -1), Vec2(1, -1), Vec2(1, 1), Vec2(-1, 1)].map { k in
                Vec2(p3.x, p3.y) + Vec2(k.x * cs - k.y * sn, k.x * sn + k.y * cs) * size
            }
            // Flipbook frame from age (sheetFPS > 0) or normalised lifetime.
            var frame = 0
            if frames > 1 {
                frame = em.sheetFPS > 0 ? Int(pool.ages[i] * em.sheetFPS) % frames : min(Int(t * Float(frames)), frames - 1)
            }
            let fw = 1 / Float(cols), fh = 1 / Float(rows)
            let u0 = Float(frame % cols) * fw, v0 = Float(frame / cols) * fh
            let uv = [Vec2(u0, v0 + fh), Vec2(u0 + fw, v0 + fh), Vec2(u0 + fw, v0), Vec2(u0, v0)]
            let base = UInt32(verts.count)
            for k in 0..<4 { verts.append(SpriteVertex(position: corners[k], uv: uv[k], color: c)) }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        e.add(verts, idx)
    }

    // MARK: Lights

    static func lights(world: World, camera: RenderCamera, frustum: Frustum) -> [Light2D] {
        var out: [(Light2D, Float)] = []
        world.read(Light.self) { e, l in
            guard l.is2D, l.intensity > 0, l.type != .directional, world.isActiveInHierarchy(e) else { return }
            let m = world.get(WorldTransform.self, e)?.matrix ?? world.worldMatrix(of: e)
            let p = m.translation
            let radius = max(l.range, 1e-3)
            guard frustum.intersects(AABB(min: Vec3(p.x - radius, p.y - radius, -0.01 + min(p.z, 0)),
                                          max: Vec3(p.x + radius, p.y + radius, 0.01 + max(p.z, 0)))) else { return }
            var d = Light2D()
            // Height above the sprite plane: |z|, or a quarter of the range on the plane.
            let height = abs(p.z) > 0.01 ? abs(p.z) : radius * 0.25
            d.positionRadius = Vec4(p.x, p.y, height, radius)
            d.color = Vec4(l.color.rgb * l.intensity, 2)
            if l.type == .spot {
                let f = m.transformDirection(.forward)
                let dir = Vec2(f.x, f.y)
                let outer = min(max(l.outerConeAngle, 0.001), .pi - 0.001)
                d.params = Vec4(0, cos(outer), dir.lengthSquared > 1e-8 ? dir.normalized.x : 1,
                                dir.lengthSquared > 1e-8 ? dir.normalized.y : 0)
            }
            out.append((d, (Vec2(p.x, p.y) - Vec2(camera.position.x, camera.position.y)).lengthSquared))
        }
        if out.count > maxLights {
            out.sort { $0.1 < $1.1 }
            out.removeLast(out.count - maxLights)
        }
        return out.map(\.0)
    }
}
