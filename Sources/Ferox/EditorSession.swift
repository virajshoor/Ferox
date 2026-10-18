import Foundation

/// The platform-independent core of the Ferox editor: selection, Play/Pause/Step/Stop,
/// snapshot-based undo and redo, entity creation/duplication/deletion, and scene files.
///
/// It drives an `Engine` in edit mode and has no UI of its own, so it can be unit tested
/// headlessly; `FeroxEditor` builds its windows and panels on top of it.
///
/// **Play mode.** `play()` serialises the scene, then leaves edit mode so game hooks and
/// all systems run. `stop()` destroys everything the simulation produced and restores
/// the snapshot, so no play-mode change leaks into the edited scene.
///
/// **Undo.** Every recorded edit stores the whole scene document from before the change.
/// That is O(scene) per edit, but it is simple, exact and works for every operation
/// (including deleting a subtree). Consecutive edits with the same coalescing key — a
/// slider drag — share one undo step. History is capped at `maxUndoSteps`.
///
/// **Editor-owned entities** (the editor camera) are listed in `editorEntities`. They are
/// never saved, snapshotted, selected by `selectAll`-style operations or destroyed by a
/// restore.
///
/// Not thread safe: use it from the thread that drives the engine.
public final class EditorSession {
    public enum PlayState: Equatable, Sendable { case editing, playing, paused }

    public enum EditorError: Error, CustomStringConvertible {
        case notEditing
        case fileTooLarge(Int)
        public var description: String {
            switch self {
            case .notEditing: return "The scene can only be saved or loaded while editing (press Stop first)"
            case .fileTooLarge(let n): return "Scene file is too large (\(n) bytes)"
            }
        }
    }

    public let engine: Engine
    public private(set) var state: PlayState = .editing
    public private(set) var selection: Entity?
    /// Name written into saved documents.
    public var sceneName = "Untitled"
    /// The file the scene was last saved to or loaded from.
    public private(set) var fileURL: URL?
    /// True when the scene changed since the last save or load.
    public private(set) var isDirty = false
    /// Entities owned by the editor itself; excluded from saving, snapshots and restores.
    public var editorEntities: Set<Entity> = []
    public var maxUndoSteps = 64
    public var serializer = SceneSerializer()
    /// Called after any change to the scene structure or selection (panels refresh).
    public var onChange: (() -> Void)?

    private struct Snapshot {
        var document: SceneDocument
        /// Index of the selected entity in document order, to reselect after a restore.
        var selectionIndex: Int?
        var label: String
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastCoalesceKey: AnyHashable?
    private var playSnapshot: Snapshot?

    public init(engine: Engine) {
        self.engine = engine
        engine.isEditMode = true
    }

    public var canUndo: Bool { state == .editing && !undoStack.isEmpty }
    public var canRedo: Bool { state == .editing && !redoStack.isEmpty }
    /// Label of the edit `undo()` would revert, for the menu ("Undo Move").
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    // MARK: Scene contents

    /// Root entities of the edited scene (editor entities excluded), in index order.
    public var sceneRoots: [Entity] {
        engine.world.entities.filter { engine.world.parent(of: $0) == nil && !editorEntities.contains($0) }
    }

    /// Every scene entity in depth-first document order — the order `SceneSerializer`
    /// writes, so an index into it survives a save/restore round-trip.
    public var sceneEntities: [Entity] {
        var out: [Entity] = []
        for r in sceneRoots { engine.world.visitSubtree(r) { e, _ in out.append(e) } }
        return out
    }

    /// Display name of `e`: its `Name` component or "Entity <index>".
    public func displayName(of e: Entity) -> String {
        engine.world.get(Name.self, e)?.value ?? "Entity \(e.index)"
    }

    // MARK: Selection

    public func select(_ e: Entity?) {
        let valid = e.flatMap { engine.world.isAlive($0) && !editorEntities.contains($0) ? $0 : nil }
        guard valid != selection else { return }
        selection = valid
        lastCoalesceKey = nil
        onChange?()
    }

    // MARK: Editing

    /// Records an undo step before a change. Calls with the same non-nil `coalesce` key in
    /// a row (a drag) share the first call's step.
    public func recordUndo(_ label: String, coalesce: AnyHashable? = nil) {
        guard state == .editing else { return }
        if let coalesce, coalesce == lastCoalesceKey { return }
        lastCoalesceKey = coalesce
        guard let snap = try? snapshot(label: label) else { return }
        undoStack.append(snap)
        if undoStack.count > maxUndoSteps { undoStack.removeFirst(undoStack.count - maxUndoSteps) }
        redoStack.removeAll()
        isDirty = true
    }

    /// Replaces `e`'s local transform as one undoable edit (coalesced per entity).
    public func setTransform(_ t: Transform, of e: Entity) {
        guard engine.world.isAlive(e) else { return }
        recordUndo("Transform", coalesce: AnyHashable(["transform", "\(e.index):\(e.generation)"]))
        engine.world.add(t, to: e)
        TransformSystem.update(engine.world)
    }

    /// Renames `e` as an undoable edit.
    public func rename(_ e: Entity, to name: String) {
        guard engine.world.isAlive(e) else { return }
        recordUndo("Rename")
        engine.world.add(Name(String(name.prefix(256))), to: e)
        onChange?()
    }

    /// Creates an empty entity (under `parent`, if any) and selects it.
    @discardableResult
    public func createEntity(named name: String = "Entity", parent: Entity = .null) -> Entity {
        recordUndo("Create \(name)")
        let e = engine.world.createEntity(named: name, parent: parent)
        TransformSystem.update(engine.world)
        select(e)
        onChange?()
        return e
    }

    /// Deletes the selected entity and its children.
    public func deleteSelection() {
        guard let e = selection, engine.world.isAlive(e) else { return }
        recordUndo("Delete \(displayName(of: e))")
        selection = nil
        engine.world.destroy(e)
        onChange?()
    }

    /// Duplicates the selected subtree next to the original and selects the copy.
    @discardableResult
    public func duplicateSelection() -> Entity? {
        guard let e = selection, engine.world.isAlive(e) else { return nil }
        recordUndo("Duplicate \(displayName(of: e))")
        do {
            let doc = try serializer.encode(world: engine.world, name: "copy", roots: [e])
            let parent = engine.world.parent(of: e) ?? .null
            let created = try serializer.decode(doc, into: engine.world, parent: parent)
            TransformSystem.update(engine.world)
            select(created.first)
            onChange?()
            return created.first
        } catch {
            Log.error("Editor", "Duplicate failed: \(error)")
            return nil
        }
    }

    public func undo() {
        guard canUndo, let snap = undoStack.popLast(), let current = try? snapshot(label: snap.label) else { return }
        redoStack.append(current)
        restore(snap)
        isDirty = true
    }

    public func redo() {
        guard canRedo, let snap = redoStack.popLast(), let current = try? snapshot(label: snap.label) else { return }
        undoStack.append(current)
        restore(snap)
        isDirty = true
    }

    // MARK: Play mode

    /// Snapshots the scene and starts simulating it.
    public func play() {
        guard state == .editing else { return }
        do {
            playSnapshot = try snapshot(label: "Play")
        } catch {
            Log.error("Editor", "Cannot enter play mode, the scene failed to serialise: \(error)")
            return
        }
        lastCoalesceKey = nil
        engine.clock.reset()
        engine.clock.isPaused = false
        engine.isEditMode = false
        state = .playing
        onChange?()
    }

    /// Pauses or resumes play mode.
    public func togglePause() {
        switch state {
        case .playing:
            engine.clock.isPaused = true
            state = .paused
        case .paused:
            engine.clock.isPaused = false
            state = .playing
        case .editing:
            return
        }
        onChange?()
    }

    /// While paused, advances exactly one fixed step. Has no effect otherwise.
    public func step() {
        guard state == .paused else { return }
        engine.clock.isPaused = false
        engine.tick(delta: engine.clock.fixed.step)
        engine.clock.isPaused = true
    }

    /// Ends play mode and restores the scene as it was when Play was pressed.
    public func stop() {
        guard state != .editing else { return }
        engine.isEditMode = true
        engine.clock.isPaused = false
        state = .editing
        if let snap = playSnapshot { restore(snap) }
        playSnapshot = nil
        onChange?()
    }

    // MARK: Files

    /// Clears the scene (editor entities are kept) as an undoable edit.
    public func newScene(named name: String = "Untitled") throws {
        guard state == .editing else { throw EditorError.notEditing }
        recordUndo("New Scene")
        for r in sceneRoots { engine.world.destroy(r) }
        selection = nil
        sceneName = name
        fileURL = nil
        isDirty = false
        onChange?()
    }

    /// Writes the scene as JSON (`.fxscene`), atomically.
    public func save(to url: URL) throws {
        guard state == .editing else { throw EditorError.notEditing }
        let doc = try serializer.encode(world: engine.world, name: sceneName, roots: sceneRoots)
        try doc.jsonData().write(to: url, options: .atomic)
        fileURL = url
        isDirty = false
        Log.info("Editor", "Saved \(url.lastPathComponent) (\(doc.entities.count) entities)")
    }

    /// Replaces the scene with a validated document read from `url`.
    ///
    /// The file is size-checked before it is read, then parsed with
    /// `SceneDocument.load(from:)`, which rejects unsupported versions, duplicate or cyclic
    /// ids and pathological nesting. Nothing in a scene file is executed.
    public func load(from url: URL, limits: DecodeLimits = .default) throws {
        guard state == .editing else { throw EditorError.notEditing }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= limits.maxFileBytes else { throw EditorError.fileTooLarge(size) }
        let doc = try SceneDocument.load(from: Data(contentsOf: url), limits: limits)
        recordUndo("Open \(url.lastPathComponent)")
        restore(Snapshot(document: doc, selectionIndex: nil, label: "Open"))
        sceneName = doc.name
        fileURL = url
        isDirty = false
    }

    // MARK: Snapshots

    private func snapshot(label: String) throws -> Snapshot {
        let ordered = sceneEntities
        let doc = try serializer.encode(world: engine.world, name: sceneName, roots: sceneRoots)
        return Snapshot(document: doc, selectionIndex: selection.flatMap { ordered.firstIndex(of: $0) }, label: label)
    }

    /// Replaces every scene entity with the snapshot's contents and reselects by index.
    private func restore(_ snap: Snapshot) {
        let world = engine.world
        for r in sceneRoots { world.destroy(r) }
        world.flushDeferred()
        var created: [Entity] = []
        do {
            created = try serializer.decode(snap.document, into: world)
        } catch {
            // Snapshots are produced by `encode`, so this means a component failed to
            // decode its own output — a bug worth surfacing, not a user error.
            Log.error("Editor", "Restoring the scene failed: \(error)")
        }
        TransformSystem.update(world)
        selection = snap.selectionIndex.flatMap { $0 < created.count ? created[$0] : nil }
        lastCoalesceKey = nil
        onChange?()
    }
}
