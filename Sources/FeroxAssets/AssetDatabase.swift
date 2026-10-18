import FeroxCore
import Foundation

// MARK: - Import settings & metadata

public enum TextureWrap: String, Codable, Sendable { case repeatWrap, clamp, mirror }

public struct TextureImportSettings: Codable, Sendable, Hashable {
    /// Treat as colour (sRGB) data; nil infers from usage (materials mark normal/ORM maps linear).
    public var srgb: Bool?
    public var generateMips = true
    public var filter: TextureFilterSetting = .linear
    public var wrap: TextureWrap = .repeatWrap
    /// Downscale on import if larger (0 = unlimited).
    public var maxSize = 0
    /// Treat as a cubemap from a horizontal/vertical cross or 6×1 strip.
    public var isCubemap = false
    public init() {}
}

public enum TextureFilterSetting: String, Codable, Sendable { case nearest, linear, trilinear }

public struct ModelImportSettings: Codable, Sendable, Hashable {
    public var scale: Float = 1
    public var generateTangents = true
    public var importAnimations = true
    public var importLights = true
    public var importCameras = false
    public init() {}
}

public struct AudioImportSettings: Codable, Sendable, Hashable {
    /// Stream from disk instead of decoding into memory (music, long ambience).
    public var stream = false
    public var loop = false
    public init() {}
}

public struct ImportSettings: Codable, Sendable, Hashable {
    public var texture = TextureImportSettings()
    public var model = ModelImportSettings()
    public var audio = AudioImportSettings()
    public init() {}
}

/// Sidecar metadata stored next to each source file as `<file>.meta` (JSON). Commit these:
/// they hold the stable `AssetID` that scenes reference.
public struct AssetMeta: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    public var version = AssetMeta.currentVersion
    public var id: AssetID
    public var kind: AssetKind
    public var settings: ImportSettings
    /// Project-relative paths this asset depends on (textures of a model, atlas image, …).
    public var dependencies: [String] = []
    /// FNV-1a 64 hash of the source bytes at last import (change detection).
    public var sourceHash: String = ""
    public var labels: [String] = []
    public init(id: AssetID = AssetID(), kind: AssetKind, settings: ImportSettings = ImportSettings()) {
        self.id = id
        self.kind = kind
        self.settings = settings
    }
}

/// FNV-1a 64-bit hash (fast, non-cryptographic; used only for change detection).
public func fnv1a64(_ data: Data) -> String {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    data.withUnsafeBytes { raw in
        for b in raw.bindMemory(to: UInt8.self) {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
    }
    return String(h, radix: 16)
}

/// Project asset database: discovers source files, maintains `.meta` sidecars with stable
/// IDs, tracks dependencies, and reports which assets changed since the last refresh.
///
/// Change detection is two-stage: file size + modification date first (cheap), then a
/// content hash to confirm, so touching a file without editing it does not re-import.
public final class AssetDatabase: @unchecked Sendable {
    public struct Entry: Sendable, Hashable {
        public var id: AssetID
        public var path: String
        public var kind: AssetKind
        public var meta: AssetMeta
        public var size: Int
        public var modified: Date
    }

    public let root: URL
    public let safePath: SafePath
    public var cacheDirectory: URL { root.appendingPathComponent(".ferox-cache", isDirectory: true) }
    /// Write missing `.meta` files to disk (disable for read-only shipped builds).
    public var writesMetaFiles = true

    private let lock = NSLock()
    private var entries: [AssetID: Entry] = [:]
    private var byPath: [String: AssetID] = [:]

    public init(root: URL) {
        self.root = root.standardizedFileURL
        safePath = SafePath(root: root)
    }

    public var all: [Entry] { lock.locked { Array(entries.values) }.sorted { $0.path < $1.path } }
    public func entry(_ id: AssetID) -> Entry? { lock.locked { entries[id] } }
    public func id(forPath p: String) -> AssetID? { lock.locked { byPath[p] } }
    public func url(for id: AssetID) -> URL? { entry(id).map { root.appendingPathComponent($0.path) } }
    public func entries(ofKind k: AssetKind) -> [Entry] { all.filter { $0.kind == k } }

    /// Assets that list `id`'s path as a dependency (transitively).
    public func dependents(of id: AssetID) -> [AssetID] {
        guard let path = entry(id)?.path else { return [] }
        var result: [AssetID] = []
        var frontier = [path]
        var seen = Set<String>()
        let snapshot = all
        while let p = frontier.popLast() {
            guard seen.insert(p).inserted else { continue }
            for e in snapshot where e.meta.dependencies.contains(p) {
                result.append(e.id)
                frontier.append(e.path)
            }
        }
        return result
    }

    /// Changes found by `refresh()`.
    public struct Changes: Sendable {
        public var added: [AssetID] = []
        public var modified: [AssetID] = []
        public var removed: [AssetID] = []
        public var isEmpty: Bool { added.isEmpty && modified.isEmpty && removed.isEmpty }
        /// Modified assets plus everything depending on them.
        public var invalidated: [AssetID] = []
    }

    /// Scans the project directory. Safe to call from a background thread.
    @discardableResult
    public func refresh() -> Changes {
        var changes = Changes()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return changes }
        var seen = Set<String>()
        for case let url as URL in enumerator {
            let rel = safePath.relativePath(for: url) ?? url.lastPathComponent
            if rel.hasPrefix(".ferox-cache") || rel.hasPrefix(".build") { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                values.isRegularFile == true
            else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "meta" { continue }
            let kind = AssetKind.infer(fromExtension: ext)
            if kind == .unknown { continue }
            seen.insert(rel)
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate ?? .distantPast
            let existing: Entry? = lock.locked { byPath[rel].flatMap { entries[$0] } }
            if let e = existing, e.size == size, e.modified == modified { continue }

            let metaURL = url.appendingPathExtension("meta")
            var meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(AssetMeta.self, from: $0) }
                ?? existing?.meta ?? AssetMeta(kind: kind)
            meta.kind = kind
            let hash = (try? Data(contentsOf: url, options: .mappedIfSafe)).map(fnv1a64) ?? ""
            let contentChanged = hash != meta.sourceHash
            meta.sourceHash = hash
            meta.dependencies = discoverDependencies(url: url, kind: kind, relative: rel)
            if writesMetaFiles && (contentChanged || !fm.fileExists(atPath: metaURL.path)) {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let d = try? enc.encode(meta) { try? d.write(to: metaURL, options: .atomic) }
            }
            let entry = Entry(id: meta.id, path: rel, kind: kind, meta: meta, size: size, modified: modified)
            lock.locked {
                if let old = byPath[rel], old != meta.id { entries[old] = nil }
                entries[meta.id] = entry
                byPath[rel] = meta.id
            }
            if existing == nil { changes.added.append(meta.id) } else if contentChanged { changes.modified.append(meta.id) }
        }
        lock.locked {
            for (path, id) in byPath where !seen.contains(path) {
                byPath[path] = nil
                entries[id] = nil
                changes.removed.append(id)
            }
        }
        var inval = Set(changes.modified)
        for id in changes.modified { inval.formUnion(dependents(of: id)) }
        changes.invalidated = Array(inval)
        return changes
    }

    /// Updates import settings and rewrites the `.meta` file.
    public func updateSettings(_ id: AssetID, _ settings: ImportSettings) throws {
        guard var e = entry(id) else { throw AssetError.notFound(id.rawValue) }
        e.meta.settings = settings
        let url = root.appendingPathComponent(e.path).appendingPathExtension("meta")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(e.meta).write(to: url, options: .atomic)
        let updated = e
        lock.locked { entries[id] = updated }
    }

    /// Finds referenced files for dependency tracking (glTF URIs, atlas images, Tiled tilesets).
    func discoverDependencies(url: URL, kind: AssetKind, relative: String) -> [String] {
        let dir = (relative as NSString).deletingLastPathComponent
        func rel(_ p: String) -> String? {
            guard !p.hasPrefix("data:"), let decoded = p.removingPercentEncoding else { return nil }
            let joined = dir.isEmpty ? decoded : dir + "/" + decoded
            return (try? safePath.resolve(joined)).flatMap { safePath.relativePath(for: $0) }
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        switch kind {
        case .model where url.pathExtension.lowercased() == "gltf":
            guard let j = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
            let uris = (j["buffers"]?.arrayValue ?? []).compactMap { $0["uri"]?.stringValue }
                + (j["images"]?.arrayValue ?? []).compactMap { $0["uri"]?.stringValue }
            return uris.compactMap(rel)
        case .spriteAtlas:
            guard let j = try? JSONDecoder().decode(JSONValue.self, from: data),
                let img = j["meta"]?["image"]?.stringValue ?? j["texture"]?.stringValue
            else { return [] }
            return [img].compactMap(rel)
        case .tilemap:
            guard let j = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
            return (j["tilesets"]?.arrayValue ?? []).compactMap { $0["image"]?.stringValue }.compactMap(rel)
        case .material:
            guard let m = try? JSONDecoder().decode(MaterialData.self, from: data) else { return [] }
            return [m.baseColorTexture, m.normalTexture, m.metallicRoughnessTexture, m.occlusionTexture, m.emissiveTexture]
                .compactMap { $0 }.compactMap { id in lock.locked { entries[id]?.path } }
        default:
            return []
        }
    }

    // MARK: Cache

    public func cacheURL(for id: AssetID, suffix: String) -> URL {
        cacheDirectory.appendingPathComponent("\(id.rawValue.replacingOccurrences(of: "/", with: "_")).\(suffix)")
    }

    /// Reads a cached product if it was produced from the current source hash.
    public func cachedData(for id: AssetID, suffix: String) -> Data? {
        guard let e = entry(id), let d = try? Data(contentsOf: cacheURL(for: id, suffix: suffix)), d.count > 64 else { return nil }
        let header = String(decoding: d.prefix(64), as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        guard header == "FXCACHE1 \(e.meta.sourceHash)" else { return nil }
        return d.dropFirst(64)
    }

    public func writeCache(_ data: Data, for id: AssetID, suffix: String) {
        guard let e = entry(id) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var header = Data("FXCACHE1 \(e.meta.sourceHash)".utf8)
        header.append(Data(repeating: 0x20, count: max(0, 64 - header.count)))
        try? (header.prefix(64) + data).write(to: cacheURL(for: id, suffix: suffix), options: .atomic)
    }
}
