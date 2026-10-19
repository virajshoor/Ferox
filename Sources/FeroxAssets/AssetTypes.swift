import FeroxAnimation
import FeroxCore
import FeroxScene
import Foundation

/// Errors raised by importers and loaders. Messages are written for humans: they name the
/// file, the offending element and what was expected.
public enum AssetError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case unsupportedFormat(String)
    case corrupt(String, reason: String)
    case limitExceeded(String, reason: String)
    case invalidPath(String)
    case dependencyMissing(String, dependency: String)

    public var description: String {
        switch self {
        case .notFound(let p): return "Asset not found: \(p)"
        case .unsupportedFormat(let p): return "Unsupported asset format: \(p)"
        case .corrupt(let p, let r): return "Corrupt asset \(p): \(r)"
        case .limitExceeded(let p, let r): return "Asset \(p) exceeds limits: \(r)"
        case .invalidPath(let p): return "Invalid asset path: \(p)"
        case .dependencyMissing(let p, let d): return "Asset \(p) depends on missing \(d)"
        }
    }
}

/// Kind of asset, used by the database and editor browser.
public enum AssetKind: String, Codable, Sendable, CaseIterable {
    case texture, cubemap, model, material, audio, font, shader, spriteAtlas, tilemap, scene, prefab, animation, unknown

    public static func infer(fromExtension ext: String) -> AssetKind {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "tga", "bmp", "tif", "tiff", "heic", "hdr", "exr", "ktx", "ktx2": return .texture
        case "gltf", "glb": return .model
        case "fxmat": return .material
        case "wav", "aif", "aiff", "caf", "mp3", "m4a", "aac", "flac": return .audio
        case "ttf", "otf", "ttc": return .font
        case "metal": return .shader
        case "fxatlas", "atlas": return .spriteAtlas
        case "tmj", "fxtilemap": return .tilemap
        case "fxscene": return .scene
        case "fxprefab": return .prefab
        case "fxanim": return .animation
        default: return .unknown
        }
    }
}

// MARK: - Images

public enum PixelFormat: String, Codable, Sendable {
    case rgba8Unorm, rgba8UnormSRGB, rgba16Float, rgba32Float, r8Unorm, rg8Unorm

    public var bytesPerPixel: Int {
        switch self {
        case .rgba8Unorm, .rgba8UnormSRGB: return 4
        case .rgba16Float: return 8
        case .rgba32Float: return 16
        case .r8Unorm: return 1
        case .rg8Unorm: return 2
        }
    }
}

/// Decoded image, top row first. Colour images are stored with premultiplied alpha.
public struct ImageData: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var format: PixelFormat
    public var pixels: Data
    /// Additional mip levels (level 1…n), each half the previous size, if pre-generated.
    public var mips: [Data] = []
    /// Six faces for cubemaps (+X, −X, +Y, −Y, +Z, −Z); empty for 2D images.
    public var faces: [Data] = []

    public init(width: Int, height: Int, format: PixelFormat, pixels: Data) {
        self.width = width
        self.height = height
        self.format = format
        self.pixels = pixels
    }

    public var byteCount: Int { pixels.count + mips.reduce(0) { $0 + $1.count } + faces.reduce(0) { $0 + $1.count } }
    public var isCubemap: Bool { faces.count == 6 }

    /// Magenta/black checkerboard used for missing or corrupt textures.
    public static func checkerboard(size: Int = 64, cells: Int = 8) -> ImageData {
        var d = Data(count: size * size * 4)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<size {
                for x in 0..<size {
                    let on = ((x * cells / size) + (y * cells / size)) % 2 == 0
                    let i = (y * size + x) * 4
                    p[i] = on ? 255 : 0
                    p[i + 1] = 0
                    p[i + 2] = on ? 255 : 0
                    p[i + 3] = 255
                }
            }
        }
        return ImageData(width: size, height: size, format: .rgba8UnormSRGB, pixels: d)
    }

    /// A 1×1 solid colour image (linear components → sRGB 8-bit).
    public static func solid(_ c: Color, srgb: Bool = true) -> ImageData {
        let v = srgb ? c.srgb : c.vector
        let bytes = [v.x, v.y, v.z, v.w].map { UInt8(($0.saturated * 255).rounded()) }
        return ImageData(width: 1, height: 1, format: srgb ? .rgba8UnormSRGB : .rgba8Unorm, pixels: Data(bytes))
    }

    /// Generates a full box-filtered mip chain for RGBA8 images (CPU; used when the GPU
    /// blit encoder is unavailable, e.g. in tests). sRGB images are filtered in linear space.
    public mutating func generateMips() {
        guard format == .rgba8Unorm || format == .rgba8UnormSRGB else { return }
        mips.removeAll()
        let srgb = format == .rgba8UnormSRGB
        var w = width
        var h = height
        var src = [UInt8](pixels)
        while w > 1 || h > 1 {
            let nw = max(1, w / 2)
            let nh = max(1, h / 2)
            var dst = [UInt8](repeating: 0, count: nw * nh * 4)
            for y in 0..<nh {
                for x in 0..<nw {
                    for c in 0..<4 {
                        var sum: Float = 0
                        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                            let sx = min(x * 2 + dx, w - 1)
                            let sy = min(y * 2 + dy, h - 1)
                            let v = Float(src[(sy * w + sx) * 4 + c]) / 255
                            sum += (srgb && c < 3) ? Color.srgbToLinear(v) : v
                        }
                        var avg = sum / 4
                        if srgb && c < 3 { avg = Color.linearToSrgb(avg) }
                        dst[(y * nw + x) * 4 + c] = UInt8((avg.saturated * 255).rounded())
                    }
                }
            }
            mips.append(Data(dst))
            src = dst
            w = nw
            h = nh
        }
    }
}

// MARK: - Meshes

/// Interleaving-agnostic vertex streams. Optional streams are empty when absent.
public struct MeshData: Sendable, Hashable {
    public struct Submesh: Sendable, Hashable, Codable {
        public var indexOffset: Int
        public var indexCount: Int
        public var materialIndex: Int
        public init(indexOffset: Int, indexCount: Int, materialIndex: Int) {
            self.indexOffset = indexOffset
            self.indexCount = indexCount
            self.materialIndex = materialIndex
        }
    }
    public var name: String
    public var positions: [Vec3]
    public var normals: [Vec3] = []
    /// xyz tangent, w handedness (±1).
    public var tangents: [Vec4] = []
    public var uv0: [Vec2] = []
    public var uv1: [Vec2] = []
    public var colors: [Vec4] = []
    public var joints: [SIMD4<UInt16>] = []
    public var weights: [Vec4] = []
    public var indices: [UInt32]
    public var submeshes: [Submesh]
    public var bounds: AABB = .empty

    public init(name: String, positions: [Vec3], indices: [UInt32], submeshes: [Submesh]? = nil) {
        self.name = name
        self.positions = positions
        self.indices = indices
        self.submeshes = submeshes ?? [Submesh(indexOffset: 0, indexCount: indices.count, materialIndex: 0)]
        recomputeBounds()
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var isSkinned: Bool { !joints.isEmpty && joints.count == positions.count }

    public mutating func recomputeBounds() {
        var b = AABB.empty
        for p in positions { b.expand(p) }
        bounds = b
    }

    /// Checks stream lengths and index ranges.
    public func validate() throws {
        let n = positions.count
        func check<T>(_ s: [T], _ name: String) throws {
            if !s.isEmpty && s.count != n {
                throw AssetError.corrupt(self.name, reason: "\(name) has \(s.count) elements, expected \(n)")
            }
        }
        try check(normals, "NORMAL")
        try check(tangents, "TANGENT")
        try check(uv0, "TEXCOORD_0")
        try check(uv1, "TEXCOORD_1")
        try check(colors, "COLOR_0")
        try check(joints, "JOINTS_0")
        try check(weights, "WEIGHTS_0")
        if indices.count % 3 != 0 {
            throw AssetError.corrupt(name, reason: "index count \(indices.count) is not a multiple of 3")
        }
        if let bad = indices.first(where: { Int($0) >= n }) {
            throw AssetError.corrupt(name, reason: "index \(bad) out of range (vertex count \(n))")
        }
        for s in submeshes where s.indexOffset < 0 || s.indexOffset + s.indexCount > indices.count {
            throw AssetError.corrupt(
                name, reason: "submesh range \(s.indexOffset)+\(s.indexCount) exceeds \(indices.count) indices")
        }
    }

    /// Generates smooth area-weighted normals.
    public mutating func generateNormals() {
        var acc = [Vec3](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let i0 = Int(indices[t])
            let i1 = Int(indices[t + 1])
            let i2 = Int(indices[t + 2])
            let n = (positions[i1] - positions[i0]).cross(positions[i2] - positions[i0])
            acc[i0] += n
            acc[i1] += n
            acc[i2] += n
        }
        normals = acc.map { $0.lengthSquared > 0 ? $0.normalized : .up }
    }

    /// Generates per-vertex tangents from UV derivatives (Lengyel's method), orthogonalised
    /// against the normal with handedness in `w`. Requires normals and `uv0`.
    public mutating func generateTangents() {
        guard !uv0.isEmpty, normals.count == positions.count else { return }
        var tan = [Vec3](repeating: .zero, count: positions.count)
        var bit = [Vec3](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let i0 = Int(indices[t])
            let i1 = Int(indices[t + 1])
            let i2 = Int(indices[t + 2])
            let e1 = positions[i1] - positions[i0]
            let e2 = positions[i2] - positions[i0]
            let d1 = uv0[i1] - uv0[i0]
            let d2 = uv0[i2] - uv0[i0]
            let det = d1.x * d2.y - d2.x * d1.y
            guard Swift.abs(det) > 1e-12 else { continue }
            let r = 1 / det
            let sdir = (e1 * d2.y - e2 * d1.y) * r
            let tdir = (e2 * d1.x - e1 * d2.x) * r
            for i in [i0, i1, i2] {
                tan[i] += sdir
                bit[i] += tdir
            }
        }
        tangents = positions.indices.map { i in
            let n = normals[i]
            var t = tan[i] - n * n.dot(tan[i])
            if t.lengthSquared < 1e-12 { t = n.anyPerpendicular }
            t = t.normalized
            let w: Float = n.cross(t).dot(bit[i]) < 0 ? -1 : 1
            return Vec4(t, w)
        }
    }

    /// Unit cube used as the fallback for missing meshes.
    public static func cube(size: Float = 1) -> MeshData {
        let h = size / 2
        let faces: [(Vec3, Vec3, Vec3)] = [
            (Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)), (Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)),
            (Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, -1)), (Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)),
            (Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0)), (Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0)),
        ]
        var p: [Vec3] = []
        var n: [Vec3] = []
        var uv: [Vec2] = []
        var idx: [UInt32] = []
        for (normal, u, v) in faces {
            let base = UInt32(p.count)
            for (su, sv) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                p.append((normal + u * su + v * sv) * h)
                n.append(normal)
                uv.append(Vec2((su + 1) / 2, 1 - (sv + 1) / 2))
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        var m = MeshData(name: "Cube", positions: p, indices: idx)
        m.normals = n
        m.uv0 = uv
        m.generateTangents()
        return m
    }

    /// UV sphere.
    public static func sphere(radius: Float = 0.5, segments: Int = 32, rings: Int = 16) -> MeshData {
        var p: [Vec3] = []
        var n: [Vec3] = []
        var uv: [Vec2] = []
        var idx: [UInt32] = []
        for r in 0...rings {
            let v = Float(r) / Float(rings)
            let phi = v * .pi
            for s in 0...segments {
                let u = Float(s) / Float(segments)
                let theta = u * 2 * .pi
                let d = Vec3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                p.append(d * radius)
                n.append(d)
                uv.append(Vec2(u, v))
            }
        }
        let stride = UInt32(segments + 1)
        for r in 0..<UInt32(rings) {
            for s in 0..<UInt32(segments) {
                let a = r * stride + s
                let b = a + stride
                idx += [a, a + 1, b, a + 1, b + 1, b]
            }
        }
        var m = MeshData(name: "Sphere", positions: p, indices: idx)
        m.normals = n
        m.uv0 = uv
        m.generateTangents()
        return m
    }

    /// XZ plane facing +Y.
    public static func plane(size: Float = 1, subdivisions: Int = 1) -> MeshData {
        let n = max(1, subdivisions)
        var p: [Vec3] = []
        var uv: [Vec2] = []
        var idx: [UInt32] = []
        for z in 0...n {
            for x in 0...n {
                let u = Float(x) / Float(n)
                let v = Float(z) / Float(n)
                p.append(Vec3((u - 0.5) * size, 0, (v - 0.5) * size))
                uv.append(Vec2(u, v))
            }
        }
        let row = UInt32(n + 1)
        for z in 0..<UInt32(n) {
            for x in 0..<UInt32(n) {
                let a = z * row + x
                idx += [a, a + row, a + 1, a + 1, a + row, a + row + 1]
            }
        }
        var m = MeshData(name: "Plane", positions: p, indices: idx)
        m.normals = Array(repeating: .up, count: p.count)
        m.uv0 = uv
        m.generateTangents()
        return m
    }
}

// MARK: - Materials

public enum AlphaMode: String, Codable, Sendable, CaseIterable { case opaque, mask, blend }

/// Metallic-roughness PBR material (glTF 2.0 model).
public struct MaterialData: Codable, Sendable, Hashable, Identifiable {
    public var id: AssetID
    public var name: String
    public var shader: String = "pbr"
    public var baseColor: Color = .white
    public var baseColorTexture: AssetID?
    public var metallic: Float = 0
    public var roughness: Float = 0.5
    /// Green = roughness, blue = metallic (glTF convention).
    public var metallicRoughnessTexture: AssetID?
    public var normalTexture: AssetID?
    public var normalScale: Float = 1
    public var occlusionTexture: AssetID?
    public var occlusionStrength: Float = 1
    public var emissive: Color = .black
    public var emissiveStrength: Float = 1
    public var emissiveTexture: AssetID?
    public var alphaMode: AlphaMode = .opaque
    public var alphaCutoff: Float = 0.5
    public var doubleSided = false
    public var unlit = false
    /// Shader variant feature flags (e.g. "VERTEX_COLOR"); combined with texture presence
    /// to choose a pipeline permutation.
    public var features: Set<String> = []
    /// Custom shader parameters for user materials.
    public var floatParameters: [String: Float] = [:]
    public var vectorParameters: [String: Vec4] = [:]

    public init(id: AssetID = AssetID(), name: String) {
        self.id = id
        self.name = name
    }

    public static let `default` = MaterialData(id: AssetID("ferox-default-material"), name: "Default")
}

// MARK: - Models

/// Scene graph imported from a model file.
public struct ModelData: Sendable, Hashable {
    public struct Node: Sendable, Hashable {
        public var name: String
        public var transform: TRS
        public var children: [Int]
        public var mesh: Int?
        public var skin: Int?
        public var light: Light?
        public var camera: Camera?
    }
    public struct Skin: Sendable, Hashable {
        public var name: String
        public var joints: [Int]
        public var skeleton: Skeleton
    }
    public var name: String
    public var nodes: [Node]
    public var roots: [Int]
    public var meshes: [MeshData]
    public var materials: [MaterialData]
    public var images: [ImageData?]
    /// Per-image role hints (sRGB colour vs linear data), parallel to `images`.
    public var imageIsColor: [Bool]
    /// Maps material texture IDs to image indices.
    public var textureImageIndex: [AssetID: Int]
    public var skins: [Skin]
    public var animations: [AnimationClip]
}

// MARK: - Sprite atlases and tilemaps

/// A texture atlas with named frames (normalised UV rects plus pixel sizes).
public struct SpriteAtlas: Codable, Sendable, Hashable {
    public struct Frame: Codable, Sendable, Hashable {
        public var name: String
        public var uv: Rect
        public var pixelSize: Vec2
        public var pivot: Vec2
    }
    public var texture: AssetID
    public var texturePath: String
    public var size: Vec2
    public var frames: [Frame]

    public func frame(named n: String) -> Frame? { frames.first { $0.name == n } }

    /// Frames whose names share a prefix, sorted naturally ("run_0", "run_1", …) — for flipbooks.
    public func sequence(prefix: String) -> [Frame] {
        frames.filter { $0.name.hasPrefix(prefix) }.sorted {
            $0.name.compare($1.name, options: .numeric) == .orderedAscending
        }
    }

    /// Builds an atlas for a uniform grid sprite sheet.
    public static func grid(
        texture: AssetID, texturePath: String, size: Vec2, columns: Int, rows: Int, prefix: String = "frame"
    ) -> SpriteAtlas {
        var frames: [Frame] = []
        let cw = 1 / Float(max(columns, 1))
        let ch = 1 / Float(max(rows, 1))
        for r in 0..<rows {
            for c in 0..<columns {
                frames.append(
                    Frame(
                        name: "\(prefix)_\(r * columns + c)",
                        uv: Rect(x: Float(c) * cw, y: Float(r) * ch, width: cw, height: ch),
                        pixelSize: Vec2(size.x * cw, size.y * ch), pivot: Vec2(0.5, 0.5)))
            }
        }
        return SpriteAtlas(texture: texture, texturePath: texturePath, size: size, frames: frames)
    }

    /// Parses Ferox atlas JSON or the widely used TexturePacker "JSON (Hash/Array)" format.
    public static func parse(_ data: Data, path: String, resolveTexture: (String) -> AssetID) throws -> SpriteAtlas {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AssetError.corrupt(path, reason: "not valid JSON")
        }
        let imageName = root["meta"]?["image"]?.stringValue ?? root["texture"]?.stringValue
        guard let imageName else { throw AssetError.corrupt(path, reason: "missing meta.image / texture") }
        let w = root["meta"]?["size"]?["w"]?.floatValue ?? root["size"]?[0]?.floatValue ?? 0
        let h = root["meta"]?["size"]?["h"]?.floatValue ?? root["size"]?[1]?.floatValue ?? 0
        guard w > 0, h > 0 else { throw AssetError.corrupt(path, reason: "atlas size must be positive") }
        var frames: [Frame] = []
        func addFrame(_ name: String, _ f: JSONValue) throws {
            guard let rect = f["frame"], let x = rect["x"]?.floatValue, let y = rect["y"]?.floatValue,
                let fw = rect["w"]?.floatValue, let fh = rect["h"]?.floatValue
            else { throw AssetError.corrupt(path, reason: "frame '\(name)' lacks x/y/w/h") }
            let pivot = Vec2(f["pivot"]?["x"]?.floatValue ?? 0.5, f["pivot"]?["y"]?.floatValue ?? 0.5)
            frames.append(
                Frame(
                    name: name, uv: Rect(x: x / w, y: y / h, width: fw / w, height: fh / h),
                    pixelSize: Vec2(fw, fh), pivot: pivot))
        }
        switch root["frames"] {
        case .object(let dict)?:
            for (name, f) in dict.sorted(by: { $0.key < $1.key }) { try addFrame(name, f) }
        case .array(let arr)?:
            for f in arr { try addFrame(f["filename"]?.stringValue ?? "frame\(frames.count)", f) }
        default:
            throw AssetError.corrupt(path, reason: "missing 'frames'")
        }
        return SpriteAtlas(texture: resolveTexture(imageName), texturePath: imageName, size: Vec2(w, h), frames: frames)
    }
}

/// Imports Tiled JSON maps (`.tmj`): the first tile layer and the first tileset.
public enum TiledImporter {
    public static func parse(_ data: Data, path: String, resolveTexture: (String) -> AssetID) throws -> Tilemap {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AssetError.corrupt(path, reason: "not valid JSON")
        }
        guard let w = root["width"]?.intValue, let h = root["height"]?.intValue, w > 0, h > 0, w * h <= 16_777_216
        else {
            throw AssetError.corrupt(path, reason: "invalid map width/height")
        }
        guard let layer = root["layers"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "tilelayer" }),
            let raw = layer["data"]?.arrayValue
        else {
            throw AssetError.unsupportedFormat(
                "\(path) (no uncompressed tile layer; export with CSV/JSON array encoding)")
        }
        guard raw.count == w * h else {
            throw AssetError.corrupt(path, reason: "tile data has \(raw.count) entries, expected \(w * h)")
        }
        guard let ts = root["tilesets"]?[0] else { throw AssetError.corrupt(path, reason: "no tileset") }
        let firstGID = ts["firstgid"]?.intValue ?? 1
        let columns = ts["columns"]?.intValue ?? 1
        let count = ts["tilecount"]?.intValue ?? columns
        let image = ts["image"]?.stringValue ?? ""
        let rows = max(1, (count + columns - 1) / max(columns, 1))
        var map = Tilemap(tileset: resolveTexture(image), columns: columns, rows: rows, width: w, height: h)
        // Tiled stores rows top-first; Ferox tilemaps are bottom-first.
        for y in 0..<h {
            for x in 0..<w {
                let gid = (raw[y * w + x].intValue ?? 0) & 0x1FFF_FFFF  // strip flip flags
                map.tiles[(h - 1 - y) * w + x] = gid == 0 ? -1 : Int32(gid - firstGID)
            }
        }
        return map
    }
}
