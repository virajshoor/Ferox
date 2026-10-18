import FeroxAnimation
import FeroxCore
import FeroxScene
import Foundation

/// Loading state of an asset handle.
public enum AssetState: Sendable, Equatable {
    case unloaded, loading, loaded, failed(String)
}

/// Reference-counted handle to a loaded asset. Holding a handle keeps the asset resident;
/// when only the manager references it, it becomes eligible for eviction under memory
/// pressure. Callbacks run on the main thread during `AssetManager.update()`.
public final class AssetHandle<T>: @unchecked Sendable {
    public let id: AssetID
    public internal(set) var state: AssetState = .unloaded
    public internal(set) var value: T?
    /// Incremented on every (re)load so render caches can detect hot reloads.
    public internal(set) var revision: UInt64 = 0
    var callbacks: [(AssetHandle<T>) -> Void] = []
    var lastUsedFrame: UInt64 = 0
    var byteCount = 0

    init(id: AssetID) { self.id = id }

    public var isLoaded: Bool { state == .loaded }

    /// Calls `body` when loaded (immediately if already loaded).
    public func whenLoaded(_ body: @escaping (AssetHandle<T>) -> Void) {
        if state == .loaded { body(self) } else { callbacks.append(body) }
    }
}

/// CPU-side model with cached textures resolved.
public struct LoadedModel: Sendable {
    public var data: ModelData
    /// Image index → texture asset id used by materials.
    public var textureIDs: [Int: AssetID]
}

private struct ModelCacheHeader: Codable {
    var name: String
    var nodes: [CodableNode]
    var roots: [Int]
    var materials: [MaterialData]
    var imageIsColor: [Bool]
    var textureImageIndex: [String: Int]
    var skins: [CodableSkin]
    var animations: [AnimationClip]
    var imagePresent: [Bool]

    struct CodableNode: Codable {
        var name: String
        var transform: TRS
        var children: [Int]
        var mesh: Int?
        var skin: Int?
        var light: Light?
        var camera: Camera?
    }
    struct CodableSkin: Codable {
        var name: String
        var joints: [Int]
        var skeleton: Skeleton
    }
}

/// Runtime asset loader and cache.
///
/// - Loads asynchronously on a background queue; completion is delivered on the main
///   thread in `update()`, never mid-frame.
/// - Missing or corrupt assets resolve to placeholders (checkerboard texture, unit cube,
///   default material) and log an error naming the file, so a broken asset never crashes a game.
/// - Processed models are cached in `.ferox-cache/` keyed by source hash (incremental rebuilds).
/// - With `hotReload` enabled, the project is re-scanned periodically and changed assets
///   (plus dependents) are reloaded; `onReload` notifies the renderer and other systems.
/// - Texture memory is tracked against `budget`; unreferenced textures are evicted LRU.
public final class AssetManager: @unchecked Sendable {
    public let database: AssetDatabase?
    public var budget: MemoryBudget
    public var textureQuality: TextureQuality = .high
    public var limits = DecodeLimits.default
    public var hotReload = false
    public var hotReloadInterval: Double = 0.75

    /// Called on the main thread with the IDs of assets that were reloaded.
    public var onReload: (([AssetID]) -> Void)?

    private let worker = BackgroundWorker(label: "dev.ferox.assets", qos: .userInitiated, concurrent: true)
    private let completions = ThreadSafeQueue<() -> Void>()
    private var textures: [AssetID: AssetHandle<ImageData>] = [:]
    private var models: [AssetID: AssetHandle<LoadedModel>] = [:]
    private var materials: [AssetID: AssetHandle<MaterialData>] = [:]
    private var atlases: [AssetID: AssetHandle<SpriteAtlas>] = [:]
    private var raw: [AssetID: AssetHandle<Data>] = [:]
    private var meshes: [AssetID: AssetHandle<MeshData>] = [:]
    private var frame: UInt64 = 0
    private var lastScan: Double = 0
    private var scanInFlight = false
    public private(set) var loadCount = 0
    public private(set) var totalLoadSeconds: Double = 0

    public init(database: AssetDatabase?, budget: MemoryBudget = MemoryBudget(textureBytes: 1 << 30, meshBytes: 256 << 20, audioBytes: 128 << 20)) {
        self.database = database
        self.budget = budget
    }

    // MARK: Frame update

    /// Delivers completions, runs hot reload checks and enforces the memory budget.
    /// Call once per frame on the main thread.
    public func update() {
        frame &+= 1
        for c in completions.drain() { c() }
        if hotReload, let db = database, !scanInFlight, MonotonicClock.now() - lastScan > hotReloadInterval {
            lastScan = MonotonicClock.now()
            scanInFlight = true
            worker.submit { [weak self] in
                let changes = db.refresh()
                self?.completions.push { [weak self] in
                    self?.scanInFlight = false
                    if !changes.invalidated.isEmpty { self?.reload(changes.invalidated) }
                }
            }
        }
        enforceBudget()
    }

    /// Blocks until all pending loads finish (tools, tests, loading screens on a worker).
    public func waitForPendingLoads() {
        worker.waitUntilIdle()
        for c in completions.drain() { c() }
    }

    private func reload(_ ids: [AssetID]) {
        var reloaded: [AssetID] = []
        for id in ids {
            if let h = textures[id] { startTextureLoad(h, srgbHint: nil); reloaded.append(id) }
            if let h = models[id] { startModelLoad(h); reloaded.append(id) }
            if let h = materials[id] { startMaterialLoad(h); reloaded.append(id) }
            if let h = atlases[id] { startAtlasLoad(h); reloaded.append(id) }
            if let h = raw[id] { startRawLoad(h); reloaded.append(id) }
        }
        if !reloaded.isEmpty {
            Log.info("Assets", "Hot-reloaded \(reloaded.count) asset(s)")
            onReload?(reloaded)
        }
    }

    // MARK: Generic helpers

    private func finish<T>(_ h: AssetHandle<T>, _ result: Result<T, any Error>, bytes: Int, started: Double, fallback: T) {
        completions.push { [weak self] in
            switch result {
            case .success(let v):
                h.value = v
                h.state = .loaded
                h.byteCount = bytes
            case .failure(let e):
                Log.error("Assets", "\(h.id): \(e)")
                h.value = fallback
                h.state = .failed(String(describing: e))
            }
            h.revision &+= 1
            self?.loadCount += 1
            self?.totalLoadSeconds += MonotonicClock.now() - started
            Profiler.shared.count("assets.loaded")
            let cbs = h.callbacks
            h.callbacks.removeAll()
            for c in cbs { c(h) }
        }
    }

    private func sourceData(_ id: AssetID) throws -> (Data, URL) {
        guard let db = database, let url = db.url(for: id) else { throw AssetError.notFound(id.rawValue) }
        let d: Data
        do { d = try limits.readFile(at: url) } catch let e as DecodeLimitError {
            throw AssetError.limitExceeded(url.lastPathComponent, reason: e.description)
        } catch { throw AssetError.notFound(url.path) }
        return (d, url)
    }

    // MARK: Textures

    /// Loads a texture by asset id. `srgbHint` overrides colour-space inference.
    public func texture(_ id: AssetID, srgb srgbHint: Bool? = nil) -> AssetHandle<ImageData> {
        if let h = textures[id] {
            h.lastUsedFrame = frame
            return h
        }
        let h = AssetHandle<ImageData>(id: id)
        textures[id] = h
        startTextureLoad(h, srgbHint: srgbHint)
        return h
    }

    /// Registers an in-memory texture (procedural, embedded in a model, built-in).
    @discardableResult
    public func registerTexture(_ image: ImageData, id: AssetID) -> AssetHandle<ImageData> {
        let h = textures[id] ?? AssetHandle<ImageData>(id: id)
        h.value = image
        h.state = .loaded
        h.byteCount = image.byteCount
        h.revision &+= 1
        textures[id] = h
        return h
    }

    private func startTextureLoad(_ h: AssetHandle<ImageData>, srgbHint: Bool?) {
        h.state = .loading
        let id = h.id
        let quality = textureQuality
        let limits = self.limits
        let settings = database?.entry(id)?.meta.settings.texture ?? TextureImportSettings()
        let started = MonotonicClock.now()
        worker.submit { [weak self] in
            guard let self else { return }
            let result: Result<ImageData, any Error> = Result {
                let (data, url) = try self.sourceData(id)
                var img = try ImageDecoder.decode(data, url.lastPathComponent, limits: limits)
                let srgb = srgbHint ?? settings.srgb ?? true
                if img.format == .rgba8UnormSRGB && !srgb { img.format = .rgba8Unorm }
                if settings.generateMips { img.generateMips() }
                // Apply texture quality / max size by dropping top mip levels.
                var drop = quality.mipBias
                if settings.maxSize > 0 {
                    var w = img.width
                    while w > settings.maxSize { w /= 2; drop += 1 }
                }
                img = AssetManager.dropMips(img, count: drop)
                return img
            }
            let bytes = (try? result.get().byteCount) ?? 0
            self.finish(h, result, bytes: bytes, started: started, fallback: ImageData.checkerboard())
        }
    }

    /// Removes `count` top mip levels (promoting the next level to base).
    static func dropMips(_ img: ImageData, count: Int) -> ImageData {
        guard count > 0, !img.mips.isEmpty else { return img }
        let n = min(count, img.mips.count)
        var out = img
        out.pixels = img.mips[n - 1]
        out.mips = Array(img.mips.dropFirst(n))
        out.width = max(1, img.width >> n)
        out.height = max(1, img.height >> n)
        return out
    }

    // MARK: Models

    public func model(_ id: AssetID) -> AssetHandle<LoadedModel> {
        if let h = models[id] { return h }
        let h = AssetHandle<LoadedModel>(id: id)
        models[id] = h
        startModelLoad(h)
        return h
    }

    private func startModelLoad(_ h: AssetHandle<LoadedModel>) {
        h.state = .loading
        let id = h.id
        let started = MonotonicClock.now()
        let limits = self.limits
        worker.submit { [weak self] in
            guard let self, let db = self.database else { return }
            let result: Result<LoadedModel, any Error> = Result {
                var model: ModelData
                if let cached = db.cachedData(for: id, suffix: "model"), let m = try? AssetManager.decodeModelCache(cached, name: id.rawValue) {
                    model = m
                    Profiler.shared.count("assets.cacheHits")
                } else {
                    guard let url = db.url(for: id) else { throw AssetError.notFound(id.rawValue) }
                    let importer = GLTFImporter(limits: limits)
                    model = try importer.load(url: url, root: db.safePath)
                    let settings = db.entry(id)?.meta.settings.model ?? ModelImportSettings()
                    if settings.scale != 1 {
                        for i in model.nodes.indices where model.roots.contains(i) { model.nodes[i].transform.scale *= settings.scale }
                    }
                    if !settings.importAnimations { model.animations = [] }
                    if !settings.importLights { for i in model.nodes.indices { model.nodes[i].light = nil } }
                    if !settings.importCameras { for i in model.nodes.indices { model.nodes[i].camera = nil } }
                    db.writeCache(AssetManager.encodeModelCache(model), for: id, suffix: "model")
                }
                var texIDs: [Int: AssetID] = [:]
                for (tid, idx) in model.textureImageIndex { texIDs[idx] = tid }
                return LoadedModel(data: model, textureIDs: texIDs)
            }
            let bytes = (try? result.get().data.meshes.reduce(0) { $0 + $1.vertexCount * 64 + $1.indices.count * 4 }) ?? 0
            self.finish(h, result, bytes: bytes, started: started, fallback: AssetManager.fallbackModel(id))
            // Register embedded images as textures once delivered.
            self.completions.push { [weak self] in
                guard let self, let m = h.value else { return }
                for (idx, tid) in m.textureIDs {
                    let img = idx < m.data.images.count ? m.data.images[idx] : nil
                    self.registerTexture(img ?? .checkerboard(), id: tid)
                }
            }
        }
    }

    static func fallbackModel(_ id: AssetID) -> LoadedModel {
        let cube = MeshData.cube()
        let node = ModelData.Node(name: "Missing", transform: TRS(), children: [], mesh: 0, skin: nil, light: nil, camera: nil)
        let data = ModelData(name: "Missing(\(id))", nodes: [node], roots: [0], meshes: [cube], materials: [.default], images: [],
                             imageIsColor: [], textureImageIndex: [:], skins: [], animations: [])
        return LoadedModel(data: data, textureIDs: [:])
    }

    static func encodeModelCache(_ m: ModelData) -> Data {
        let header = ModelCacheHeader(
            name: m.name,
            nodes: m.nodes.map { .init(name: $0.name, transform: $0.transform, children: $0.children, mesh: $0.mesh, skin: $0.skin, light: $0.light, camera: $0.camera) },
            roots: m.roots, materials: m.materials, imageIsColor: m.imageIsColor,
            textureImageIndex: Dictionary(uniqueKeysWithValues: m.textureImageIndex.map { ($0.key.rawValue, $0.value) }),
            skins: m.skins.map { .init(name: $0.name, joints: $0.joints, skeleton: $0.skeleton) }, animations: m.animations,
            imagePresent: m.images.map { $0 != nil })
        var w = BinaryWriter()
        w.write(UInt32(1))  // version
        w.write((try? JSONEncoder().encode(header)) ?? Data())
        w.write(UInt32(m.meshes.count))
        for mesh in m.meshes { mesh.encodeBinary(into: &w) }
        for img in m.images { if let img { img.encodeBinary(into: &w) } }
        return w.data
    }

    static func decodeModelCache(_ d: Data, name: String) throws -> ModelData {
        var r = BinaryReader(d, name: name)
        guard try r.read(UInt32.self) == 1 else { throw AssetError.corrupt(name, reason: "cache version") }
        let header = try JSONDecoder().decode(ModelCacheHeader.self, from: try r.readData())
        let meshCount = Int(try r.read(UInt32.self))
        guard meshCount <= 100_000 else { throw AssetError.corrupt(name, reason: "mesh count") }
        var meshes: [MeshData] = []
        for _ in 0..<meshCount { meshes.append(try MeshData.decodeBinary(&r)) }
        var images: [ImageData?] = []
        for present in header.imagePresent { images.append(present ? try ImageData.decodeBinary(&r) : nil) }
        return ModelData(
            name: header.name,
            nodes: header.nodes.map { .init(name: $0.name, transform: $0.transform, children: $0.children, mesh: $0.mesh, skin: $0.skin, light: $0.light, camera: $0.camera) },
            roots: header.roots, meshes: meshes, materials: header.materials, images: images, imageIsColor: header.imageIsColor,
            textureImageIndex: Dictionary(uniqueKeysWithValues: header.textureImageIndex.map { (AssetID($0.key), $0.value) }),
            skins: header.skins.map { .init(name: $0.name, joints: $0.joints, skeleton: $0.skeleton) }, animations: header.animations)
    }

    // MARK: Meshes

    /// Registers an in-memory mesh (built-ins, model sub-meshes, procedural geometry).
    @discardableResult
    public func registerMesh(_ mesh: MeshData, id: AssetID) -> AssetHandle<MeshData> {
        let h = meshes[id] ?? AssetHandle<MeshData>(id: id)
        h.value = mesh
        h.state = .loaded
        h.byteCount = mesh.vertexCount * 64 + mesh.indices.count * 4
        h.revision &+= 1
        meshes[id] = h
        return h
    }

    /// Mesh by id. Model sub-meshes become available once their model has loaded and been
    /// registered (`ModelInstantiator.register`).
    public func mesh(_ id: AssetID) -> AssetHandle<MeshData>? { meshes[id] }

    /// Material by id if already registered or loaded (does not start a load).
    public func loadedMaterial(_ id: AssetID) -> MaterialData? { materials[id]?.value }

    /// Texture handle if already registered or loading (does not start a load).
    public func existingTexture(_ id: AssetID) -> AssetHandle<ImageData>? { textures[id] }

    // MARK: Materials, atlases, raw files

    public func material(_ id: AssetID) -> AssetHandle<MaterialData> {
        if let h = materials[id] { return h }
        let h = AssetHandle<MaterialData>(id: id)
        materials[id] = h
        startMaterialLoad(h)
        return h
    }

    @discardableResult
    public func registerMaterial(_ m: MaterialData) -> AssetHandle<MaterialData> {
        let h = materials[m.id] ?? AssetHandle<MaterialData>(id: m.id)
        h.value = m
        h.state = .loaded
        h.revision &+= 1
        materials[m.id] = h
        return h
    }

    private func startMaterialLoad(_ h: AssetHandle<MaterialData>) {
        h.state = .loading
        let id = h.id
        let started = MonotonicClock.now()
        worker.submit { [weak self] in
            guard let self else { return }
            let result: Result<MaterialData, any Error> = Result {
                let (data, url) = try self.sourceData(id)
                do {
                    var m = try JSONDecoder().decode(MaterialData.self, from: data)
                    m.id = id
                    return m
                } catch {
                    throw AssetError.corrupt(url.lastPathComponent, reason: "invalid material JSON: \(error)")
                }
            }
            self.finish(h, result, bytes: 0, started: started, fallback: .default)
        }
    }

    public func atlas(_ id: AssetID) -> AssetHandle<SpriteAtlas> {
        if let h = atlases[id] { return h }
        let h = AssetHandle<SpriteAtlas>(id: id)
        atlases[id] = h
        startAtlasLoad(h)
        return h
    }

    private func startAtlasLoad(_ h: AssetHandle<SpriteAtlas>) {
        h.state = .loading
        let id = h.id
        let started = MonotonicClock.now()
        let db = database
        worker.submit { [weak self] in
            guard let self else { return }
            let result: Result<SpriteAtlas, any Error> = Result {
                let (data, url) = try self.sourceData(id)
                let dir = db.flatMap { $0.entry(id) }.map { ($0.path as NSString).deletingLastPathComponent } ?? ""
                return try SpriteAtlas.parse(data, path: url.lastPathComponent) { image in
                    let p = dir.isEmpty ? image : dir + "/" + image
                    return db?.id(forPath: p) ?? AssetID.derived(fromPath: p)
                }
            }
            self.finish(h, result, bytes: 0, started: started,
                        fallback: SpriteAtlas(texture: .none, texturePath: "", size: Vec2(1, 1), frames: []))
        }
    }

    /// Raw bytes of any asset (audio, fonts, shaders, scenes) for subsystem-specific loaders.
    public func data(_ id: AssetID) -> AssetHandle<Data> {
        if let h = raw[id] { return h }
        let h = AssetHandle<Data>(id: id)
        raw[id] = h
        startRawLoad(h)
        return h
    }

    private func startRawLoad(_ h: AssetHandle<Data>) {
        h.state = .loading
        let id = h.id
        let started = MonotonicClock.now()
        worker.submit { [weak self] in
            guard let self else { return }
            let result: Result<Data, any Error> = Result { try self.sourceData(id).0 }
            let n = (try? result.get().count) ?? 0
            self.finish(h, result, bytes: n, started: started, fallback: Data())
        }
    }

    // MARK: Budget

    /// Total CPU-side texture bytes currently resident.
    public var residentTextureBytes: Int { textures.values.reduce(0) { $0 + $1.byteCount } }

    private func enforceBudget() {
        var total = residentTextureBytes
        guard total > budget.textureBytes else { return }
        // Evict least-recently-used textures that nobody else references.
        let candidates = textures.keys.sorted { (textures[$0]?.lastUsedFrame ?? 0) < (textures[$1]?.lastUsedFrame ?? 0) }
        for id in candidates where total > budget.textureBytes {
            guard textures[id]?.state == .loaded, var h = textures.removeValue(forKey: id) else { continue }
            // With the dictionary entry removed, a unique reference means no game code holds it.
            if isKnownUniquelyReferenced(&h) {
                total -= h.byteCount
                Profiler.shared.count("assets.evicted")
            } else {
                textures[id] = h
            }
        }
        if total > budget.textureBytes {
            Log.warning("Assets", "Texture memory \(total >> 20) MB exceeds budget \(budget.textureBytes >> 20) MB (all textures in use)")
        }
    }

    public var loadedTextureCount: Int { textures.count }
}
