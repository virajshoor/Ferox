import FeroxCore
import Foundation

/// A component that can be saved in scenes and prefabs and edited in the inspector.
public protocol SerializableComponent: Component, Codable {
    /// Stable name used in scene files. Defaults to the type name; override when renaming
    /// a type to keep old scenes loading.
    static var serializedName: String { get }
}

extension SerializableComponent {
    public static var serializedName: String { String(describing: Self.self) }
}

/// Component payloads whose type is not registered (e.g. from a newer engine version or a
/// game module that is not loaded). Preserved verbatim so a load/save round trip is lossless.
public struct UnknownComponents: Component, Hashable, Sendable {
    public var payloads: [String: JSONValue] = [:]
}

/// Registry of serializable component types (by stable name).
///
/// Engine modules register their components at start-up (`registerBuiltins`), and games
/// register their own with `ComponentRegistry.shared.register(MyComponent.self)`.
public final class ComponentRegistry: @unchecked Sendable {
    public struct Entry {
        public let name: String
        public let type: any Component.Type
        let encode: (World, Entity, [CodingUserInfoKey: Any]) throws -> JSONValue?
        let decode: (JSONValue, World, Entity, [CodingUserInfoKey: Any]) throws -> Void
        let decodeValue: (JSONValue) throws -> any Component
        public let makeDefault: (() -> any Component)?
    }

    public static let shared: ComponentRegistry = {
        let r = ComponentRegistry()
        r.registerSceneBuiltins()
        return r
    }()

    private let lock = NSLock()
    private var byName: [String: Entry] = [:]
    private var byType: [ObjectIdentifier: Entry] = [:]

    public init() {}

    public func register<T: SerializableComponent>(_ type: T.Type, makeDefault: (() -> T)? = nil) {
        let name = T.serializedName
        let entry = Entry(
            name: name, type: T.self,
            encode: { world, e, info in
                guard let v = world.get(T.self, e) else { return nil }
                return try JSONValue.encode(v, userInfo: info)
            },
            decode: { json, world, e, info in
                let v = try json.decode(T.self, userInfo: info)
                world.add(v, to: e)
            },
            decodeValue: { json in try json.decode(T.self) },
            makeDefault: makeDefault.map { f in { () -> any Component in f() } })
        lock.locked {
            byName[name] = entry
            byType[ObjectIdentifier(T.self)] = entry
        }
    }

    public func entry(named name: String) -> Entry? { lock.locked { byName[name] } }
    public func entry(for type: any Component.Type) -> Entry? { lock.locked { byType[ObjectIdentifier(type)] } }
    public var entries: [Entry] { lock.locked { Array(byName.values) }.sorted { $0.name < $1.name } }

    /// Encodes one component value (for the inspector / undo snapshots).
    public func encode(_ value: any Component) throws -> JSONValue? {
        guard let enc = value as? any Encodable else { return nil }
        return try JSONValue.encode(AnyEncodable(enc))
    }

    /// Decodes a component value of a registered type.
    public func decode(_ json: JSONValue, as name: String) throws -> any Component {
        guard let e = entry(named: name) else { throw SceneError.unknownComponent(name) }
        return try e.decodeValue(json)
    }

    func registerSceneBuiltins() {
        register(Name.self) { Name("Entity") }
        register(Transform.self) { Transform() }
        register(Disabled.self) { Disabled() }
        register(Tags.self) { Tags() }
        register(Layer.self) { Layer() }
        register(Groups.self) { Groups() }
        register(PersistentID.self)
        register(PersistAcrossScenes.self) { PersistAcrossScenes() }
        register(Camera.self) { Camera() }
        register(Light.self) { Light() }
        register(MeshRenderer.self) { MeshRenderer(mesh: .none) }
        register(MaterialOverrides.self) { MaterialOverrides() }
        register(SkinnedMeshRenderer.self)
        register(LODGroup.self) { LODGroup(levels: []) }
        register(SpriteRenderer.self) { SpriteRenderer(texture: .none, size: Vec2(1, 1)) }
        register(ShapeRenderer.self) { ShapeRenderer(.rectangle(size: Vec2(1, 1), cornerRadius: 0)) }
        register(Parallax.self) { Parallax(Vec2(1, 1)) }
        register(Tilemap.self) { Tilemap(tileset: .none, columns: 1, rows: 1, width: 8, height: 8) }
        register(Environment.self) { Environment() }
        register(ReflectionProbe.self) { ReflectionProbe() }
        register(PrefabInstance.self)
    }
}

/// Wraps an existential `Encodable` so it can be passed to generic encoders.
public struct AnyEncodable: Encodable {
    let value: any Encodable
    public init(_ v: any Encodable) { value = v }
    public func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

public enum SceneError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)
    case unknownComponent(String)
    case invalidParent(entity: Int, parent: Int)
    case duplicateID(Int)
    case tooManyEntities(Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): return "Scene format version \(v) is not supported (max \(SceneDocument.currentVersion))"
        case .unknownComponent(let n): return "Unknown component type '\(n)'"
        case .invalidParent(let e, let p): return "Entity \(e) references missing parent \(p)"
        case .duplicateID(let i): return "Duplicate entity id \(i) in scene document"
        case .tooManyEntities(let n): return "Scene has too many entities (\(n))"
        case .malformed(let m): return "Malformed scene: \(m)"
        }
    }
}

/// On-disk representation of a scene or prefab (`.fxscene` / `.fxprefab`, JSON).
public struct SceneDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maxEntities = 1_000_000

    public struct EntityRecord: Codable, Hashable, Sendable {
        /// Document-local identifier (referenced by `parent` and by entity fields in components).
        public var id: Int
        public var parent: Int?
        /// Component payloads keyed by `serializedName`.
        public var components: [String: JSONValue]
        public init(id: Int, parent: Int? = nil, components: [String: JSONValue] = [:]) {
            self.id = id
            self.parent = parent
            self.components = components
        }
    }

    public var formatVersion: Int = SceneDocument.currentVersion
    public var name: String
    public var entities: [EntityRecord]
    /// Free-form metadata (author tool, environment settings references, …).
    public var metadata: [String: JSONValue] = [:]

    public init(name: String, entities: [EntityRecord] = []) {
        self.name = name
        self.entities = entities
    }

    public func jsonData(pretty: Bool = true) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try enc.encode(self)
    }

    /// Parses and validates a document. Validation rejects unsupported versions, duplicate
    /// ids, dangling or cyclic parents, oversized documents and pathological nesting.
    public static func load(from data: Data, limits: DecodeLimits = .default) throws -> SceneDocument {
        guard data.count <= limits.maxFileBytes else { throw SceneError.malformed("file exceeds \(limits.maxFileBytes) bytes") }
        let doc: SceneDocument
        do {
            doc = try JSONDecoder().decode(SceneDocument.self, from: data)
        } catch let e as DecodingError {
            throw SceneError.malformed(String(describing: e))
        }
        try doc.validate(limits: limits)
        return doc
    }

    public func validate(limits: DecodeLimits = .default) throws {
        guard formatVersion >= 1 && formatVersion <= SceneDocument.currentVersion else {
            throw SceneError.unsupportedVersion(formatVersion)
        }
        guard entities.count <= SceneDocument.maxEntities else { throw SceneError.tooManyEntities(entities.count) }
        var ids = Set<Int>()
        for r in entities {
            guard ids.insert(r.id).inserted else { throw SceneError.duplicateID(r.id) }
            for (_, v) in r.components where v.depth > limits.maxNestingDepth {
                throw SceneError.malformed("component nesting too deep in entity \(r.id)")
            }
        }
        let parentOf = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.parent) })
        for r in entities {
            if let p = r.parent, !ids.contains(p) { throw SceneError.invalidParent(entity: r.id, parent: p) }
            // Cycle detection.
            var seen = Set<Int>()
            var cursor = r.parent
            while let c = cursor {
                if c == r.id || !seen.insert(c).inserted { throw SceneError.malformed("parent cycle at entity \(r.id)") }
                cursor = parentOf[c] ?? nil
            }
        }
    }
}

/// Converts between worlds and `SceneDocument`s.
public struct SceneSerializer {
    public var registry: ComponentRegistry
    /// When true, unregistered component payloads abort loading instead of being preserved.
    public var strict = false

    public init(registry: ComponentRegistry = .shared) { self.registry = registry }

    /// Serializes `roots` and all their descendants (or every entity when `roots` is nil).
    /// Entities that are `SceneMember`s of other scenes can be excluded by passing explicit roots.
    public func encode(world: World, name: String, roots: [Entity]? = nil) throws -> SceneDocument {
        var ordered: [Entity] = []
        let rootList = roots ?? world.entities.filter { world.parent(of: $0) == nil }
        for r in rootList where world.isAlive(r) { world.visitSubtree(r) { e, _ in ordered.append(e) } }

        let table = EntityRemapTable()
        for (i, e) in ordered.enumerated() { table.register(e, local: i) }
        let info: [CodingUserInfoKey: Any] = [.feroxEntityRemap: table]

        var records: [SceneDocument.EntityRecord] = []
        records.reserveCapacity(ordered.count)
        for (i, e) in ordered.enumerated() {
            var comps: [String: JSONValue] = [:]
            for c in world.components(of: e) {
                guard let entry = registry.entry(for: type(of: c)) else { continue }
                if let json = try entry.encode(world, e, info) { comps[entry.name] = json }
            }
            if let unknown = world.get(UnknownComponents.self, e) {
                for (k, v) in unknown.payloads where comps[k] == nil { comps[k] = v }
            }
            let parent = world.parent(of: e).flatMap { table.toLocal[$0] }
            records.append(SceneDocument.EntityRecord(id: i, parent: parent, components: comps))
        }
        return SceneDocument(name: name, entities: records)
    }

    /// Instantiates a document into `world`. Returns created entities in document order.
    @discardableResult
    public func decode(_ doc: SceneDocument, into world: World, parent: Entity = .null) throws -> [Entity] {
        try doc.validate()
        let table = EntityRemapTable()
        var created: [Entity] = []
        created.reserveCapacity(doc.entities.count)
        for r in doc.entities {
            let e = world.createEntity()
            table.register(e, local: r.id)
            created.append(e)
        }
        let info: [CodingUserInfoKey: Any] = [.feroxEntityRemap: table]
        do {
            for (r, e) in zip(doc.entities, created) {
                var unknown = UnknownComponents()
                for (name, json) in r.components.sorted(by: { $0.key < $1.key }) {
                    if let entry = registry.entry(named: name) {
                        try entry.decode(json, world, e, info)
                    } else if strict {
                        throw SceneError.unknownComponent(name)
                    } else {
                        unknown.payloads[name] = json
                        Log.warning("Scene", "Preserving unknown component '\(name)' on entity \(r.id)")
                    }
                }
                if !unknown.payloads.isEmpty { world.add(unknown, to: e) }
            }
            for (r, e) in zip(doc.entities, created) {
                if let p = r.parent, let pe = table.fromLocal[p] {
                    world.setParent(e, pe)
                } else if !parent.isNull {
                    world.setParent(e, parent)
                }
            }
        } catch {
            // Roll back partially created entities so a failed load leaves no garbage.
            for e in created { world.destroy(e) }
            throw error
        }
        return created
    }
}

// MARK: - Built-in conformances

extension Name: SerializableComponent {}
extension Transform: SerializableComponent {}
extension Disabled: SerializableComponent {}
extension Tags: SerializableComponent {}
extension Layer: SerializableComponent {}
extension Groups: SerializableComponent {}
extension PersistentID: SerializableComponent {}
extension PersistAcrossScenes: SerializableComponent {}
extension Camera: SerializableComponent {}
extension Light: SerializableComponent {}
extension MeshRenderer: SerializableComponent {}
extension MaterialOverrides: SerializableComponent {}
extension SkinnedMeshRenderer: SerializableComponent {}
extension LODGroup: SerializableComponent {}
extension SpriteRenderer: SerializableComponent {}
extension ShapeRenderer: SerializableComponent {}
extension Parallax: SerializableComponent {}
extension Tilemap: SerializableComponent {}
extension Environment: SerializableComponent {}
extension ReflectionProbe: SerializableComponent {}
