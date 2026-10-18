import FeroxAnimation
import FeroxCore
import FeroxScene
import Foundation

/// glTF 2.0 importer (`.gltf` with external or data-URI buffers, and binary `.glb`).
///
/// Supported: triangle-list meshes with POSITION/NORMAL/TANGENT/TEXCOORD_0/1/COLOR_0/
/// JOINTS_0/WEIGHTS_0, all accessor component types (normalised integers included),
/// byte strides, metallic-roughness materials with textures, KHR_materials_emissive_strength,
/// KHR_materials_unlit, KHR_lights_punctual, node hierarchies (TRS or matrix), cameras,
/// skins and animations (LINEAR, STEP, CUBICSPLINE).
///
/// Not supported (rejected with a clear error or ignored with a warning): sparse
/// accessors, Draco/meshopt compression, morph-target rendering (weights are imported as
/// animation channels only), non-triangle primitive modes, KHR_texture_transform.
///
/// Security: every URI is resolved through `SafePath` (no absolute paths, no `..` escape),
/// every accessor/bufferView range is bounds-checked, and element counts are capped by
/// `DecodeLimits`.
public struct GLTFImporter {
    public var limits: DecodeLimits
    /// Decodes embedded/external images; nil skips image decoding (tests, headless tools).
    public var imageDecoder: ((Data, String) throws -> ImageData)?

    public init(limits: DecodeLimits = .default, imageDecoder: ((Data, String) throws -> ImageData)? = ImageDecoder.decode) {
        self.limits = limits
        self.imageDecoder = imageDecoder
    }

    // MARK: Entry points

    public func load(url: URL, root: SafePath) throws -> ModelData {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw AssetError.notFound(url.path) }
        let baseDir = root.relativePath(for: url.deletingLastPathComponent()) ?? ""
        return try load(data: data, name: url.deletingPathExtension().lastPathComponent, baseDirectory: baseDir, root: root)
    }

    /// Parses glTF or GLB bytes. External URIs are resolved relative to `baseDirectory`
    /// inside `root`.
    public func load(data: Data, name: String, baseDirectory: String = "", root: SafePath? = nil) throws -> ModelData {
        guard data.count <= limits.maxFileBytes else { throw AssetError.limitExceeded(name, reason: "file larger than \(limits.maxFileBytes) bytes") }
        let isGLB = data.count >= 12 && data.prefix(4) == Data("glTF".utf8)
        let (json, binChunk): (Data, Data?) = try isGLB ? parseGLB(data, name: name) : (data, nil)
        let doc: Document
        do { doc = try JSONDecoder().decode(Document.self, from: json) } catch {
            throw AssetError.corrupt(name, reason: "invalid glTF JSON: \(error)")
        }
        guard doc.asset.version.hasPrefix("2.") else {
            throw AssetError.unsupportedFormat("\(name) (glTF version \(doc.asset.version); only 2.x is supported)")
        }
        for ext in doc.extensionsRequired ?? [] where !GLTFImporter.supportedExtensions.contains(ext) {
            throw AssetError.unsupportedFormat("\(name) requires unsupported extension \(ext)")
        }
        var ctx = Context(doc: doc, name: name, binChunk: binChunk, baseDirectory: baseDirectory, root: root, limits: limits)
        return try build(&ctx)
    }

    public static let supportedExtensions: Set<String> = [
        "KHR_materials_emissive_strength", "KHR_lights_punctual", "KHR_materials_unlit",
    ]

    func parseGLB(_ data: Data, name: String) throws -> (Data, Data?) {
        func u32(_ o: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian }
        }
        guard u32(4) == 2 else { throw AssetError.unsupportedFormat("\(name) (GLB container version \(u32(4)))") }
        let total = Int(u32(8))
        guard total <= data.count else { throw AssetError.corrupt(name, reason: "GLB length \(total) exceeds file size \(data.count)") }
        var offset = 12
        var json: Data?
        var bin: Data?
        while offset + 8 <= total {
            let len = Int(u32(offset))
            let type = u32(offset + 4)
            let start = offset + 8
            guard len >= 0, start + len <= total else { throw AssetError.corrupt(name, reason: "GLB chunk exceeds file bounds") }
            let chunk = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + len))
            if type == 0x4E4F_534A { json = chunk }  // "JSON"
            else if type == 0x004E_4942 { bin = chunk }  // "BIN\0"
            offset = start + ((len + 3) & ~3)
        }
        guard let json else { throw AssetError.corrupt(name, reason: "GLB has no JSON chunk") }
        return (json, bin)
    }

    // MARK: JSON schema (subset)

    struct Document: Decodable {
        struct Asset: Decodable { var version: String }
        struct Buffer: Decodable { var uri: String?; var byteLength: Int }
        struct BufferView: Decodable { var buffer: Int; var byteOffset: Int?; var byteLength: Int; var byteStride: Int? }
        struct Accessor: Decodable {
            var bufferView: Int?
            var byteOffset: Int?
            var componentType: Int
            var normalized: Bool?
            var count: Int
            var type: String
            var sparse: JSONValue?
        }
        struct Primitive: Decodable {
            var attributes: [String: Int]
            var indices: Int?
            var material: Int?
            var mode: Int?
        }
        struct Mesh: Decodable { var name: String?; var primitives: [Primitive] }
        struct TextureInfo: Decodable { var index: Int; var texCoord: Int?; var scale: Float?; var strength: Float? }
        struct PBR: Decodable {
            var baseColorFactor: [Float]?
            var baseColorTexture: TextureInfo?
            var metallicFactor: Float?
            var roughnessFactor: Float?
            var metallicRoughnessTexture: TextureInfo?
        }
        struct Material: Decodable {
            var name: String?
            var pbrMetallicRoughness: PBR?
            var normalTexture: TextureInfo?
            var occlusionTexture: TextureInfo?
            var emissiveTexture: TextureInfo?
            var emissiveFactor: [Float]?
            var alphaMode: String?
            var alphaCutoff: Float?
            var doubleSided: Bool?
            var extensions: [String: JSONValue]?
        }
        struct Texture: Decodable { var source: Int?; var sampler: Int? }
        struct Image: Decodable { var uri: String?; var mimeType: String?; var bufferView: Int?; var name: String? }
        struct Node: Decodable {
            var name: String?
            var children: [Int]?
            var mesh: Int?
            var skin: Int?
            var camera: Int?
            var matrix: [Float]?
            var translation: [Float]?
            var rotation: [Float]?
            var scale: [Float]?
            var extensions: [String: JSONValue]?
        }
        struct Scene: Decodable { var nodes: [Int]? }
        struct Skin: Decodable { var name: String?; var joints: [Int]; var inverseBindMatrices: Int?; var skeleton: Int? }
        struct AnimChannel: Decodable {
            struct Target: Decodable { var node: Int?; var path: String }
            var sampler: Int
            var target: Target
        }
        struct AnimSampler: Decodable { var input: Int; var output: Int; var interpolation: String? }
        struct Animation: Decodable { var name: String?; var channels: [AnimChannel]; var samplers: [AnimSampler] }
        struct CameraDef: Decodable {
            struct Persp: Decodable { var yfov: Float; var znear: Float; var zfar: Float?; var aspectRatio: Float? }
            struct Ortho: Decodable { var xmag: Float; var ymag: Float; var znear: Float; var zfar: Float }
            var type: String
            var perspective: Persp?
            var orthographic: Ortho?
        }

        var asset: Asset
        var buffers: [Buffer]?
        var bufferViews: [BufferView]?
        var accessors: [Accessor]?
        var meshes: [Mesh]?
        var materials: [Material]?
        var textures: [Texture]?
        var images: [Image]?
        var nodes: [Node]?
        var scenes: [Scene]?
        var scene: Int?
        var skins: [Skin]?
        var animations: [Animation]?
        var cameras: [CameraDef]?
        var extensions: [String: JSONValue]?
        var extensionsRequired: [String]?
        var extensionsUsed: [String]?
    }

    struct Context {
        let doc: Document
        let name: String
        let binChunk: Data?
        let baseDirectory: String
        let root: SafePath?
        let limits: DecodeLimits
        var buffers: [Int: Data] = [:]

        init(doc: Document, name: String, binChunk: Data?, baseDirectory: String, root: SafePath?, limits: DecodeLimits) {
            self.doc = doc
            self.name = name
            self.binChunk = binChunk
            self.baseDirectory = baseDirectory
            self.root = root
            self.limits = limits
        }

        func fail(_ reason: String) -> AssetError { AssetError.corrupt(name, reason: reason) }

        func resolveURI(_ uri: String) throws -> Data {
            if uri.hasPrefix("data:") {
                guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64") else {
                    throw fail("unsupported data URI (only base64 is supported)")
                }
                guard let d = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { throw fail("invalid base64 data URI") }
                return d
            }
            guard let root else { throw AssetError.dependencyMissing(name, dependency: uri) }
            let decoded = uri.removingPercentEncoding ?? uri
            let rel = baseDirectory.isEmpty ? decoded : baseDirectory + "/" + decoded
            let url: URL
            do { url = try root.resolve(rel) } catch { throw AssetError.invalidPath("\(uri) in \(name): \(error)") }
            guard let d = try? Data(contentsOf: url) else { throw AssetError.dependencyMissing(name, dependency: rel) }
            return d
        }

        mutating func buffer(_ i: Int) throws -> Data {
            if let b = buffers[i] { return b }
            guard let defs = doc.buffers, defs.indices.contains(i) else { throw fail("buffer \(i) does not exist") }
            let def = defs[i]
            let data: Data
            if let uri = def.uri {
                data = try resolveURI(uri)
            } else {
                guard let bin = binChunk else { throw fail("buffer \(i) has no URI and the file has no BIN chunk") }
                data = bin
            }
            guard data.count >= def.byteLength else { throw fail("buffer \(i) is \(data.count) bytes, declared \(def.byteLength)") }
            buffers[i] = data
            return data
        }

        mutating func bufferView(_ i: Int) throws -> (Data, Int) {
            guard let views = doc.bufferViews, views.indices.contains(i) else { throw fail("bufferView \(i) does not exist") }
            let v = views[i]
            let b = try buffer(v.buffer)
            let off = v.byteOffset ?? 0
            guard off >= 0, v.byteLength >= 0, off + v.byteLength <= b.count else {
                throw fail("bufferView \(i) range \(off)+\(v.byteLength) exceeds buffer size \(b.count)")
            }
            return (b.subdata(in: (b.startIndex + off)..<(b.startIndex + off + v.byteLength)), v.byteStride ?? 0)
        }

        static func components(_ type: String) -> Int? {
            ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16][type]
        }
        static func componentSize(_ ct: Int) -> Int? { [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][ct] }

        /// Reads an accessor as floats (normalised integers mapped to [0,1]/[-1,1]).
        mutating func floats(_ index: Int) throws -> (values: [Float], components: Int) {
            guard let accs = doc.accessors, accs.indices.contains(index) else { throw fail("accessor \(index) does not exist") }
            let a = accs[index]
            if a.sparse != nil { throw AssetError.unsupportedFormat("\(name): sparse accessor \(index)") }
            guard let nc = Context.components(a.type), let cs = Context.componentSize(a.componentType) else {
                throw fail("accessor \(index) has invalid type \(a.type)/\(a.componentType)")
            }
            guard a.count >= 0, a.count * nc <= limits.maxElementCount else {
                throw AssetError.limitExceeded(name, reason: "accessor \(index) has \(a.count) elements")
            }
            guard let bv = a.bufferView else { return (Array(repeating: 0, count: a.count * nc), nc) }
            let (data, strideDecl) = try bufferView(bv)
            let elemSize = nc * cs
            let stride = strideDecl > 0 ? strideDecl : elemSize
            let base = a.byteOffset ?? 0
            guard a.count == 0 || base + stride * (a.count - 1) + elemSize <= data.count else {
                throw fail("accessor \(index) reads past the end of bufferView \(bv)")
            }
            let normalized = a.normalized ?? false
            var out = [Float](repeating: 0, count: a.count * nc)
            data.withUnsafeBytes { raw in
                for i in 0..<a.count {
                    for c in 0..<nc {
                        let o = base + i * stride + c * cs
                        let v: Float
                        switch a.componentType {
                        case 5126: v = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian)
                        case 5121:
                            let x = raw.load(fromByteOffset: o, as: UInt8.self)
                            v = normalized ? Float(x) / 255 : Float(x)
                        case 5120:
                            let x = raw.load(fromByteOffset: o, as: Int8.self)
                            v = normalized ? max(Float(x) / 127, -1) : Float(x)
                        case 5123:
                            let x = raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian
                            v = normalized ? Float(x) / 65535 : Float(x)
                        case 5122:
                            let x = Int16(bitPattern: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian)
                            v = normalized ? max(Float(x) / 32767, -1) : Float(x)
                        default:
                            v = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian)
                        }
                        out[i * nc + c] = v
                    }
                }
            }
            return (out, nc)
        }

        mutating func indices(_ index: Int, vertexCount: Int) throws -> [UInt32] {
            guard let accs = doc.accessors, accs.indices.contains(index) else { throw fail("accessor \(index) does not exist") }
            let a = accs[index]
            guard a.type == "SCALAR", [5121, 5123, 5125].contains(a.componentType) else {
                throw fail("index accessor \(index) must be an unsigned SCALAR")
            }
            let (f, _) = try floats(index)
            var out = [UInt32](repeating: 0, count: f.count)
            for i in f.indices {
                let v = UInt32(f[i])
                guard Int(v) < vertexCount else { throw fail("index \(v) out of range (\(vertexCount) vertices)") }
                out[i] = v
            }
            return out
        }
    }

    // MARK: Build

    func build(_ ctx: inout Context) throws -> ModelData {
        let doc = ctx.doc
        let name = ctx.name
        // Textures/images → stable IDs inside the model.
        var images: [ImageData?] = []
        var imageIsColor = [Bool](repeating: false, count: doc.images?.count ?? 0)
        var textureImageIndex: [AssetID: Int] = [:]
        func texID(_ info: Document.TextureInfo?, color: Bool) -> AssetID? {
            guard let info, let tex = doc.textures?[safe: info.index], let src = tex.source else { return nil }
            if color, src < imageIsColor.count { imageIsColor[src] = true }
            let id = AssetID("\(name)#image\(src)")
            textureImageIndex[id] = src
            return id
        }

        // Materials
        var materials: [MaterialData] = []
        for (i, m) in (doc.materials ?? []).enumerated() {
            var md = MaterialData(id: AssetID("\(name)#material\(i)"), name: m.name ?? "Material\(i)")
            if let pbr = m.pbrMetallicRoughness {
                if let f = pbr.baseColorFactor, f.count == 4 { md.baseColor = Color(f[0], f[1], f[2], f[3]) }
                md.metallic = pbr.metallicFactor ?? 1
                md.roughness = pbr.roughnessFactor ?? 1
                md.baseColorTexture = texID(pbr.baseColorTexture, color: true)
                md.metallicRoughnessTexture = texID(pbr.metallicRoughnessTexture, color: false)
            } else {
                md.metallic = 1
                md.roughness = 1
            }
            md.normalTexture = texID(m.normalTexture, color: false)
            md.normalScale = m.normalTexture?.scale ?? 1
            md.occlusionTexture = texID(m.occlusionTexture, color: false)
            md.occlusionStrength = m.occlusionTexture?.strength ?? 1
            md.emissiveTexture = texID(m.emissiveTexture, color: true)
            if let e = m.emissiveFactor, e.count == 3 { md.emissive = Color(e[0], e[1], e[2]) }
            if let s = m.extensions?["KHR_materials_emissive_strength"]?["emissiveStrength"]?.floatValue { md.emissiveStrength = s }
            if m.extensions?["KHR_materials_unlit"] != nil { md.unlit = true }
            md.alphaMode = AlphaMode(rawValue: (m.alphaMode ?? "OPAQUE").lowercased()) ?? .opaque
            md.alphaCutoff = m.alphaCutoff ?? 0.5
            md.doubleSided = m.doubleSided ?? false
            materials.append(md)
        }
        if materials.isEmpty { materials.append(MaterialData(id: AssetID("\(name)#material-default"), name: "Default")) }

        // Images
        for (i, img) in (doc.images ?? []).enumerated() {
            guard let decoder = imageDecoder else {
                images.append(nil)
                continue
            }
            do {
                let bytes: Data
                if let uri = img.uri {
                    bytes = try ctx.resolveURI(uri)
                } else if let bv = img.bufferView {
                    bytes = try ctx.bufferView(bv).0
                } else {
                    throw ctx.fail("image \(i) has neither uri nor bufferView")
                }
                var decoded = try decoder(bytes, "\(name) image \(i)")
                if !(i < imageIsColor.count && imageIsColor[i]) && decoded.format == .rgba8UnormSRGB { decoded.format = .rgba8Unorm }
                images.append(decoded)
            } catch {
                Log.error("Assets", "\(name): image \(i) failed to load (\(error)); using fallback")
                images.append(nil)
            }
        }

        // Meshes: one MeshData per glTF mesh, primitives become submeshes.
        var meshes: [MeshData] = []
        for (mi, mesh) in (doc.meshes ?? []).enumerated() {
            var out = MeshData(name: mesh.name ?? "Mesh\(mi)", positions: [], indices: [], submeshes: [])
            for (pi, prim) in mesh.primitives.enumerated() {
                let mode = prim.mode ?? 4
                guard mode == 4 else {
                    Log.warning("Assets", "\(name): mesh \(mi) primitive \(pi) uses mode \(mode); only triangles are supported, skipped")
                    continue
                }
                guard let posIndex = prim.attributes["POSITION"] else { throw ctx.fail("mesh \(mi) primitive \(pi) has no POSITION") }
                let (pos, pc) = try ctx.floats(posIndex)
                guard pc == 3 else { throw ctx.fail("POSITION must be VEC3") }
                let n = pos.count / 3
                let base = UInt32(out.positions.count)
                out.positions += (0..<n).map { Vec3(pos[$0 * 3], pos[$0 * 3 + 1], pos[$0 * 3 + 2]) }

                func vec3s(_ key: String) throws -> [Vec3]? {
                    guard let i = prim.attributes[key] else { return nil }
                    let (v, c) = try ctx.floats(i)
                    guard c == 3, v.count == n * 3 else { throw ctx.fail("\(key) must be VEC3 with \(n) elements") }
                    return (0..<n).map { Vec3(v[$0 * 3], v[$0 * 3 + 1], v[$0 * 3 + 2]) }
                }
                func vec2s(_ key: String) throws -> [Vec2]? {
                    guard let i = prim.attributes[key] else { return nil }
                    let (v, c) = try ctx.floats(i)
                    guard c == 2, v.count == n * 2 else { throw ctx.fail("\(key) must be VEC2 with \(n) elements") }
                    return (0..<n).map { Vec2(v[$0 * 2], v[$0 * 2 + 1]) }
                }
                func vec4s(_ key: String) throws -> [Vec4]? {
                    guard let i = prim.attributes[key] else { return nil }
                    let (v, c) = try ctx.floats(i)
                    guard (c == 4 || c == 3), v.count == n * c else { throw ctx.fail("\(key) has wrong layout") }
                    return (0..<n).map { c == 4 ? Vec4(v[$0 * 4], v[$0 * 4 + 1], v[$0 * 4 + 2], v[$0 * 4 + 3]) : Vec4(v[$0 * 3], v[$0 * 3 + 1], v[$0 * 3 + 2], 1) }
                }
                // Streams present in some primitives but not others are padded with defaults.
                func merge<T>(_ stream: inout [T], _ values: [T]?, _ fallback: T, _ previousCount: Int) {
                    if let values {
                        if stream.count < previousCount { stream += Array(repeating: fallback, count: previousCount - stream.count) }
                        stream += values
                    } else if !stream.isEmpty {
                        stream += Array(repeating: fallback, count: n)
                    }
                }
                let prev = Int(base)
                try merge(&out.normals, vec3s("NORMAL"), .up, prev)
                try merge(&out.tangents, vec4s("TANGENT"), Vec4(1, 0, 0, 1), prev)
                try merge(&out.uv0, vec2s("TEXCOORD_0"), .zero, prev)
                try merge(&out.uv1, vec2s("TEXCOORD_1"), .zero, prev)
                try merge(&out.colors, vec4s("COLOR_0"), Vec4(1, 1, 1, 1), prev)
                if let ji = prim.attributes["JOINTS_0"] {
                    let (v, c) = try ctx.floats(ji)
                    guard c == 4 else { throw ctx.fail("JOINTS_0 must be VEC4") }
                    let j = (0..<n).map { SIMD4<UInt16>(UInt16(v[$0 * 4]), UInt16(v[$0 * 4 + 1]), UInt16(v[$0 * 4 + 2]), UInt16(v[$0 * 4 + 3])) }
                    merge(&out.joints, j, SIMD4<UInt16>(0, 0, 0, 0), prev)
                }
                try merge(&out.weights, vec4s("WEIGHTS_0"), Vec4(1, 0, 0, 0), prev)

                let idx: [UInt32]
                if let ii = prim.indices {
                    idx = try ctx.indices(ii, vertexCount: n)
                } else {
                    idx = (0..<UInt32(n)).map { $0 }
                }
                let offset = out.indices.count
                out.indices += idx.map { $0 + base }
                out.submeshes.append(
                    MeshData.Submesh(indexOffset: offset, indexCount: idx.count, materialIndex: min(prim.material ?? 0, materials.count - 1)))
            }
            if out.normals.isEmpty && !out.positions.isEmpty { out.generateNormals() }
            if out.tangents.isEmpty && !out.uv0.isEmpty { out.generateTangents() }
            out.recomputeBounds()
            try out.validate()
            meshes.append(out)
        }

        // Lights (KHR_lights_punctual)
        var lights: [Light] = []
        if let defs = doc.extensions?["KHR_lights_punctual"]?["lights"]?.arrayValue {
            for d in defs {
                let type = LightType(rawValue: d["type"]?.stringValue ?? "point") ?? .point
                var l = Light(type: type)
                if let c = d["color"]?.arrayValue, c.count == 3 { l.color = Color(c[0].floatValue ?? 1, c[1].floatValue ?? 1, c[2].floatValue ?? 1) }
                l.intensity = d["intensity"]?.floatValue ?? 1
                l.range = d["range"]?.floatValue ?? 20
                l.innerConeAngle = d["spot"]?["innerConeAngle"]?.floatValue ?? 0
                l.outerConeAngle = d["spot"]?["outerConeAngle"]?.floatValue ?? .pi / 4
                lights.append(l)
            }
        }

        // Nodes
        let nodeDefs = doc.nodes ?? []
        var nodes: [ModelData.Node] = []
        for (i, n) in nodeDefs.enumerated() {
            var trs = TRS()
            if let m = n.matrix, m.count == 16 {
                let mat = Mat4(columns: Vec4(m[0], m[1], m[2], m[3]), Vec4(m[4], m[5], m[6], m[7]), Vec4(m[8], m[9], m[10], m[11]),
                               Vec4(m[12], m[13], m[14], m[15]))
                trs = TRS(matrix: mat)
            } else {
                if let t = n.translation, t.count == 3 { trs.position = Vec3(t[0], t[1], t[2]) }
                if let r = n.rotation, r.count == 4 { trs.rotation = Quat(x: r[0], y: r[1], z: r[2], w: r[3]).normalized }
                if let s = n.scale, s.count == 3 { trs.scale = Vec3(s[0], s[1], s[2]) }
            }
            for c in n.children ?? [] where !nodeDefs.indices.contains(c) { throw ctx.fail("node \(i) has invalid child \(c)") }
            if let m = n.mesh, !meshes.indices.contains(m) { throw ctx.fail("node \(i) references missing mesh \(m)") }
            var light: Light?
            if let li = n.extensions?["KHR_lights_punctual"]?["light"]?.intValue, lights.indices.contains(li) { light = lights[li] }
            var camera: Camera?
            if let ci = n.camera, let cd = doc.cameras?[safe: ci] {
                if let p = cd.perspective {
                    camera = Camera.perspective(fov: p.yfov.degrees, near: p.znear, far: p.zfar ?? 1000)
                } else if let o = cd.orthographic {
                    camera = Camera.orthographic(size: o.ymag, near: o.znear, far: o.zfar)
                }
            }
            nodes.append(ModelData.Node(name: n.name ?? "Node\(i)", transform: trs, children: n.children ?? [], mesh: n.mesh,
                                        skin: n.skin, light: light, camera: camera))
        }
        // Detect cycles / multiple parents.
        var parentOf = [Int](repeating: -1, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            for c in n.children {
                if parentOf[c] != -1 || c == i { throw ctx.fail("node \(c) has multiple parents or a cycle") }
                parentOf[c] = i
            }
        }
        let sceneIndex = doc.scene ?? 0
        var roots = doc.scenes?[safe: sceneIndex]?.nodes ?? nodes.indices.filter { parentOf[$0] == -1 }
        roots = roots.filter { nodes.indices.contains($0) }

        // Skins
        var skins: [ModelData.Skin] = []
        for (si, s) in (doc.skins ?? []).enumerated() {
            for j in s.joints where !nodes.indices.contains(j) { throw ctx.fail("skin \(si) references missing joint node \(j)") }
            var ibms = [Mat4](repeating: .identity, count: s.joints.count)
            if let ai = s.inverseBindMatrices {
                let (v, c) = try ctx.floats(ai)
                guard c == 16, v.count >= s.joints.count * 16 else { throw ctx.fail("skin \(si) inverseBindMatrices must be MAT4 × joints") }
                for k in 0..<s.joints.count {
                    let o = k * 16
                    ibms[k] = Mat4(columns: Vec4(v[o], v[o + 1], v[o + 2], v[o + 3]), Vec4(v[o + 4], v[o + 5], v[o + 6], v[o + 7]),
                                   Vec4(v[o + 8], v[o + 9], v[o + 10], v[o + 11]), Vec4(v[o + 12], v[o + 13], v[o + 14], v[o + 15]))
                }
            }
            // Order joints so parents precede children (required by Pose.modelMatrices).
            let jointSet = Set(s.joints)
            let parents: [Int] = s.joints.map { j in
                var p = parentOf[j]
                while p != -1 && !jointSet.contains(p) { p = parentOf[p] }
                return p == -1 ? -1 : (s.joints.firstIndex(of: p) ?? -1)
            }
            var order: [Int] = []
            var placed = Set<Int>()
            while order.count < s.joints.count {
                var progressed = false
                for k in s.joints.indices where !placed.contains(k) && (parents[k] == -1 || placed.contains(parents[k])) {
                    order.append(k)
                    placed.insert(k)
                    progressed = true
                }
                if !progressed { throw ctx.fail("skin \(si) joint hierarchy is cyclic") }
            }
            let remap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let skeleton = Skeleton(
                jointNames: order.map { nodes[s.joints[$0]].name },
                parents: order.map { parents[$0] == -1 ? -1 : remap[parents[$0]]! },
                inverseBindMatrices: order.map { ibms[$0] },
                restPose: order.map { nodes[s.joints[$0]].transform })
            skins.append(ModelData.Skin(name: s.name ?? "Skin\(si)", joints: order.map { s.joints[$0] }, skeleton: skeleton))
        }

        // Animations
        var clips: [AnimationClip] = []
        for (ai, anim) in (doc.animations ?? []).enumerated() {
            var channels: [AnimationChannel] = []
            for ch in anim.channels {
                guard let node = ch.target.node, nodes.indices.contains(node), let sampler = anim.samplers[safe: ch.sampler] else { continue }
                let (times, tc) = try ctx.floats(sampler.input)
                guard tc == 1 else { throw ctx.fail("animation \(ai) input must be SCALAR") }
                let (vals, vc) = try ctx.floats(sampler.output)
                let interp: CurveInterpolation
                switch sampler.interpolation ?? "LINEAR" {
                case "STEP": interp = .step
                case "CUBICSPLINE": interp = .cubic
                default: interp = .linear
                }
                let cubic = interp == .cubic
                let keyCount = times.count
                let path = nodePath(node, nodes: nodes, parentOf: parentOf)
                func element(_ k: Int, _ part: Int) -> Int { cubic ? (k * 3 + part) * vc : k * vc }
                guard vals.count >= keyCount * vc * (cubic ? 3 : 1) else { throw ctx.fail("animation \(ai) output too short") }
                switch ch.target.path {
                case "translation", "scale":
                    guard vc == 3 else { continue }
                    let keys: [AnimationCurve<Vec3>.Key] = (0..<keyCount).map { k in
                        let v = { (p: Int) in Vec3(vals[element(k, p)], vals[element(k, p) + 1], vals[element(k, p) + 2]) }
                        return cubic ? .init(times[k], v(1), inTangent: v(0), outTangent: v(2)) : .init(times[k], v(0))
                    }
                    let curve = AnimationCurve(keys: keys, interpolation: interp)
                    channels.append(ch.target.path == "translation" ? AnimationChannel(path: path, translation: curve) : AnimationChannel(path: path, scale: curve))
                case "rotation":
                    guard vc == 4 else { continue }
                    let keys: [AnimationCurve<Quat>.Key] = (0..<keyCount).map { k in
                        let q = { (p: Int) in Quat(x: vals[element(k, p)], y: vals[element(k, p) + 1], z: vals[element(k, p) + 2], w: vals[element(k, p) + 3]) }
                        return cubic ? .init(times[k], q(1).normalized, inTangent: q(0), outTangent: q(2)) : .init(times[k], q(0).normalized)
                    }
                    channels.append(AnimationChannel(path: path, rotation: AnimationCurve(keys: keys, interpolation: interp)))
                case "weights":
                    // One float curve per morph weight.
                    let targets = vc == 1 ? max(1, vals.count / max(keyCount * (cubic ? 3 : 1), 1)) : vc
                    for w in 0..<targets {
                        let keys: [AnimationCurve<Float>.Key] = (0..<keyCount).map { k in
                            let idx = cubic ? ((k * 3 + 1) * targets + w) : (k * targets + w)
                            return .init(times[k], vals[min(idx, vals.count - 1)])
                        }
                        channels.append(AnimationChannel(path: path, target: .morphWeight(w), float: AnimationCurve(keys: keys, interpolation: interp == .cubic ? .linear : interp)))
                    }
                default:
                    continue
                }
            }
            clips.append(AnimationClip(id: AssetID("\(name)#anim\(ai)"), name: anim.name ?? "Animation\(ai)", channels: channels, loops: true))
        }

        return ModelData(name: name, nodes: nodes, roots: roots, meshes: meshes, materials: materials, images: images,
                         imageIsColor: imageIsColor, textureImageIndex: textureImageIndex, skins: skins, animations: clips)
    }

    func nodePath(_ node: Int, nodes: [ModelData.Node], parentOf: [Int]) -> String {
        var parts: [String] = []
        var cursor = node
        var guardCount = 0
        while cursor != -1 && guardCount < 256 {
            parts.append(nodes[cursor].name)
            cursor = parentOf[cursor]
            guardCount += 1
        }
        return parts.reversed().joined(separator: "/")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
