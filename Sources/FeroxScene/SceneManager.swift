import FeroxCore
import Foundation

/// Marks the root of an instantiated prefab.
public struct PrefabInstance: SerializableComponent, Hashable, Sendable {
    public var prefab: AssetID
    public init(prefab: AssetID) { self.prefab = prefab }
}

/// A reusable entity template (Unity prefab equivalent): a serialized subtree.
public struct Prefab: Hashable, Sendable {
    public var id: AssetID
    public var document: SceneDocument

    public init(id: AssetID = AssetID(), document: SceneDocument) {
        self.id = id
        self.document = document
    }

    /// Captures `root` and its descendants as a prefab.
    public static func capture(_ root: Entity, in world: World, id: AssetID = AssetID(), name: String? = nil) throws
        -> Prefab
    {
        let n = name ?? world.get(Name.self, root)?.value ?? "Prefab"
        let doc = try SceneSerializer().encode(world: world, name: n, roots: [root])
        return Prefab(id: id, document: doc)
    }

    /// Instantiates the prefab, returning the new root entity.
    @discardableResult
    public func instantiate(
        into world: World, parent: Entity = .null, position: Vec3? = nil, rotation: Quat? = nil
    ) throws -> Entity {
        let created = try SceneSerializer().decode(document, into: world, parent: parent)
        guard let root = created.first else { throw SceneError.malformed("empty prefab") }
        world.add(PrefabInstance(prefab: id), to: root)
        world.modify(Transform.self, root) { t in
            if let position { t.position = position }
            if let rotation { t.rotation = rotation }
        }
        return root
    }
}

/// Identifies a loaded scene.
public struct SceneHandle: Hashable, Sendable, Codable, CustomStringConvertible {
    public let id: UInt32
    public var description: String { "Scene#\(id)" }
}

/// Visual transition between scenes. The renderer draws `color` with alpha `fadeAlpha`.
public struct SceneTransition: Sendable, Hashable {
    public var duration: Double
    public var color: Color
    public init(duration: Double = 0.4, color: Color = .black) {
        self.duration = duration
        self.color = color
    }
    public static let none = SceneTransition(duration: 0)
}

public enum SceneLoadMode: Sendable { case single, additive }

/// Loads and unloads scenes into a shared `World`.
///
/// All loaded scenes share one world (so physics, rendering and queries see every loaded
/// scene); each entity created by a load is tagged with `SceneMember`. Unloading destroys
/// the members except those marked `PersistAcrossScenes`.
public final class SceneManager {
    public struct LoadedScene: Sendable {
        public let handle: SceneHandle
        public var name: String
        public var source: URL?
        public var loadTime: Double
    }

    public let world: World
    public private(set) var loaded: [LoadedScene] = []
    public private(set) var activeScene: SceneHandle?
    private var nextID: UInt32 = 1
    private var providers: [String: () throws -> SceneDocument] = [:]

    // Transition state
    public private(set) var fadeAlpha: Float = 0
    public private(set) var fadeColor: Color = .black
    private var pending:
        (name: String, mode: SceneLoadMode, transition: SceneTransition, elapsed: Double, swapped: Bool)?

    /// Called after a scene finishes loading.
    public var onSceneLoaded: ((SceneHandle) -> Void)?
    public var onSceneUnloaded: ((SceneHandle) -> Void)?

    public init(world: World) { self.world = world }

    /// Registers a named scene source (built-in scenes, procedural levels).
    public func register(_ name: String, provider: @escaping () throws -> SceneDocument) { providers[name] = provider }

    /// Registers a scene file.
    public func register(_ name: String, file: URL) {
        providers[name] = { try SceneDocument.load(from: DecodeLimits.default.readFile(at: file)) }
    }

    public var registeredScenes: [String] { providers.keys.sorted() }

    /// Loads a scene immediately.
    @discardableResult
    public func load(_ name: String, mode: SceneLoadMode = .single) throws -> SceneHandle {
        guard let provider = providers[name] else { throw SceneError.malformed("no scene registered as '\(name)'") }
        return try load(document: provider(), mode: mode)
    }

    @discardableResult
    public func load(document: SceneDocument, mode: SceneLoadMode = .single, source: URL? = nil) throws -> SceneHandle {
        let t0 = MonotonicClock.now()
        if mode == .single { unloadAll() }
        let handle = SceneHandle(id: nextID)
        nextID += 1
        let created = try SceneSerializer().decode(document, into: world)
        for e in created { world.add(SceneMember(scene: handle), to: e) }
        let dt = MonotonicClock.now() - t0
        loaded.append(LoadedScene(handle: handle, name: document.name, source: source, loadTime: dt))
        if activeScene == nil || mode == .single { activeScene = handle }
        Profiler.shared.count("scene.loadMs", dt * 1000)
        Log.info(
            "Scene", "Loaded '\(document.name)' (\(created.count) entities) in \(String(format: "%.2f", dt * 1000)) ms")
        onSceneLoaded?(handle)
        return handle
    }

    /// Creates an empty scene (for the editor's "New Scene").
    @discardableResult
    public func createEmpty(name: String) -> SceneHandle {
        unloadAll()
        let handle = SceneHandle(id: nextID)
        nextID += 1
        loaded.append(LoadedScene(handle: handle, name: name, source: nil, loadTime: 0))
        activeScene = handle
        return handle
    }

    public func unload(_ handle: SceneHandle) {
        var doomed: [Entity] = []
        world.read(SceneMember.self) { e, m in
            if m.scene == handle && !world.has(PersistAcrossScenes.self, e) { doomed.append(e) }
        }
        // Persistent entities nested under doomed ones are detached first (destroy is recursive).
        world.read(PersistAcrossScenes.self) { e, _ in
            if world.get(SceneMember.self, e)?.scene == handle, world.parent(of: e) != nil {
                world.deferStructural { [world] in world.setParent(e, .null, keepWorldTransform: true) }
            }
        }
        world.flushDeferred()
        // Only destroy subtree roots among the doomed set (destroy is recursive).
        let doomedSet = Set(doomed)
        for e in doomed where world.parent(of: e).map({ !doomedSet.contains($0) }) ?? true { world.destroy(e) }
        loaded.removeAll { $0.handle == handle }
        if activeScene == handle { activeScene = loaded.last?.handle }
        onSceneUnloaded?(handle)
    }

    public func unloadAll() {
        for s in loaded { unload(s.handle) }
    }

    public func setActive(_ handle: SceneHandle) {
        if loaded.contains(where: { $0.handle == handle }) { activeScene = handle }
    }

    /// Adds an entity to the active scene (newly spawned gameplay objects).
    public func adopt(_ e: Entity) {
        guard let s = activeScene else { return }
        world.add(SceneMember(scene: s), to: e)
    }

    /// Serializes the entities belonging to a scene.
    public func save(_ handle: SceneHandle) throws -> SceneDocument {
        var roots: [Entity] = []
        world.read(SceneMember.self) { e, m in
            if m.scene == handle && world.parent(of: e) == nil { roots.append(e) }
        }
        let name = loaded.first { $0.handle == handle }?.name ?? "Scene"
        return try SceneSerializer().encode(world: world, name: name, roots: roots.sorted())
    }

    /// Starts a faded transition to `name`; the swap happens at the midpoint.
    public func transition(
        to name: String, mode: SceneLoadMode = .single, transition: SceneTransition = SceneTransition()
    ) {
        guard transition.duration > 0 else {
            do { try load(name, mode: mode) } catch { Log.error("Scene", "Failed to load '\(name)': \(error)") }
            return
        }
        fadeColor = transition.color
        pending = (name, mode, transition, 0, false)
    }

    public var isTransitioning: Bool { pending != nil }

    /// Advances transitions; called by the engine every frame.
    public func update(dt: Double) {
        guard var p = pending else { return }
        p.elapsed += dt
        let half = p.transition.duration / 2
        if !p.swapped && p.elapsed >= half {
            do { try load(p.name, mode: p.mode) } catch { Log.error("Scene", "Failed to load '\(p.name)': \(error)") }
            p.swapped = true
        }
        let t = p.elapsed / p.transition.duration
        fadeAlpha = Float(t < 0.5 ? t * 2 : max(0, 2 - t * 2))
        if p.elapsed >= p.transition.duration {
            pending = nil
            fadeAlpha = 0
        } else {
            pending = p
        }
    }
}
