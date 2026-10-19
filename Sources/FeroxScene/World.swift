import FeroxCore
import Foundation

/// Container of entities and their components.
///
/// ## Ownership and threading
/// A `World` is owned by the engine (or by a test) and must only be mutated from one
/// thread at a time — normally the main thread. Systems may parallelise *within* a dense
/// component array using `withDenseStorage`, which hands out raw buffers for the duration
/// of a closure; structural changes are not allowed while those buffers are borrowed.
///
/// ## Structural changes during iteration
/// Creating/destroying entities and adding/removing components while a `forEach` query
/// is running would invalidate the dense arrays being iterated. The world therefore
/// *defers* such operations until the outermost query returns. Deferred additions are
/// not visible inside the query that issued them.
public final class World {
    // Slot table
    private var generations: [UInt32] = []
    private var alive: [Bool] = []
    private var freeIndices: [UInt32] = []
    public private(set) var entityCount = 0

    private var storages: [ObjectIdentifier: any AnyComponentStorage] = [:]
    private var iterationDepth = 0
    private var deferred: [() -> Void] = []

    /// Observers notified of entity lifecycle events.
    public var onEntityCreated: ((Entity) -> Void)?
    public var onEntityDestroyed: ((Entity) -> Void)?

    /// Monotonic counter incremented on every structural change (used by editor views
    /// and caches to detect modifications cheaply).
    public private(set) var structureVersion: UInt64 = 0

    /// Per-world resources (singletons) keyed by type: physics world, input state, etc.
    private var resources: [ObjectIdentifier: Any] = [:]

    public init() {}

    // MARK: Entities

    @discardableResult
    public func createEntity() -> Entity {
        let e: Entity
        if let idx = freeIndices.popLast() {
            alive[Int(idx)] = true
            e = Entity(index: idx, generation: generations[Int(idx)])
        } else {
            generations.append(1)
            alive.append(true)
            e = Entity(index: UInt32(generations.count - 1), generation: 1)
        }
        entityCount += 1
        structureVersion &+= 1
        onEntityCreated?(e)
        return e
    }

    /// Creates an entity with a `Name` and `Transform`.
    @discardableResult
    public func createEntity(named name: String, transform: Transform = Transform(), parent: Entity = .null) -> Entity {
        let e = createEntity()
        add(Name(name), to: e)
        add(transform, to: e)
        if !parent.isNull { setParent(e, parent) }
        return e
    }

    public func isAlive(_ e: Entity) -> Bool {
        let i = Int(e.index)
        return !e.isNull && i < generations.count && alive[i] && generations[i] == e.generation
    }

    /// Destroys an entity, its components and (recursively) its children.
    /// Deferred if called during iteration.
    public func destroy(_ e: Entity) {
        if iterationDepth > 0 {
            deferred.append { [unowned self] in self.destroy(e) }
            return
        }
        guard isAlive(e) else { return }
        // Children first (copy: destroying mutates the hierarchy).
        for child in children(of: e) { destroy(child) }
        detachFromParent(e)
        onEntityDestroyed?(e)
        for s in storages.values { s.remove(e) }
        let i = Int(e.index)
        alive[i] = false
        generations[i] &+= 1
        if generations[i] == 0 { generations[i] = 1 }
        freeIndices.append(e.index)
        entityCount -= 1
        structureVersion &+= 1
    }

    /// Every live entity, in index order.
    public var entities: [Entity] {
        var out: [Entity] = []
        out.reserveCapacity(entityCount)
        for i in alive.indices where alive[i] { out.append(Entity(index: UInt32(i), generation: generations[i])) }
        return out
    }

    /// Destroys all entities and components (resources are kept).
    public func clear() {
        for s in storages.values { s.removeAll() }
        for i in alive.indices where alive[i] {
            alive[i] = false
            generations[i] &+= 1
            freeIndices.append(UInt32(i))
        }
        entityCount = 0
        structureVersion &+= 1
    }

    // MARK: Components

    @inline(__always)
    func storage<T: Component>(_ type: T.Type) -> ComponentStorage<T>? {
        guard let s = storages[ObjectIdentifier(type)] else { return nil }
        return unsafeDowncast(s as AnyObject, to: ComponentStorage<T>.self)
    }

    func storageCreating<T: Component>(_ type: T.Type) -> ComponentStorage<T> {
        if let s = storage(type) { return s }
        let s = ComponentStorage<T>()
        storages[ObjectIdentifier(type)] = s
        return s
    }

    /// Adds or replaces a component. Deferred if called during iteration.
    public func add<T: Component>(_ component: T, to e: Entity) {
        if iterationDepth > 0 {
            deferred.append { [unowned self] in self.add(component, to: e) }
            return
        }
        guard isAlive(e) else {
            Log.warning("ECS", "add(\(T.self)) on dead entity \(e)")
            return
        }
        let s = storageCreating(T.self)
        let isNew = !s.contains(e)
        s.insert(component, for: e)
        if isNew { structureVersion &+= 1 }
    }

    /// Removes a component. Deferred if called during iteration.
    public func remove<T: Component>(_ type: T.Type, from e: Entity) {
        if iterationDepth > 0 {
            deferred.append { [unowned self] in self.remove(type, from: e) }
            return
        }
        guard let s = storage(type), s.contains(e) else { return }
        s.remove(e)
        structureVersion &+= 1
    }

    public func has<T: Component>(_ type: T.Type, _ e: Entity) -> Bool { storage(type)?.contains(e) ?? false }

    public func get<T: Component>(_ type: T.Type, _ e: Entity) -> T? { storage(type)?.get(e) }

    /// Replaces an existing component value in place (no structural change, allowed during
    /// iteration). Returns false if the entity lacks the component.
    @discardableResult
    public func set<T: Component>(_ value: T, for e: Entity) -> Bool {
        guard let s = storage(T.self), let d = s.denseIndex(e) else { return false }
        s.dense[d] = value
        return true
    }

    /// Mutates a component in place. Returns `nil` if absent.
    @discardableResult
    public func modify<T: Component, R>(_ type: T.Type, _ e: Entity, _ body: (inout T) throws -> R) rethrows -> R? {
        guard let s = storage(type), let d = s.denseIndex(e) else { return nil }
        var v = s.dense[d]
        let r = try body(&v)
        // The body may have caused a swap-remove; re-resolve before writing back.
        if let d2 = s.denseIndex(e) { s.dense[d2] = v }
        return r
    }

    public subscript<T: Component>(_ type: T.Type, _ e: Entity) -> T? {
        get { get(type, e) }
        set {
            if let v = newValue { add(v, to: e) } else { remove(type, from: e) }
        }
    }

    public func count<T: Component>(of type: T.Type) -> Int { storage(type)?.count ?? 0 }

    /// All component values on an entity (type-erased), for inspectors and serialization.
    public func components(of e: Entity) -> [any Component] {
        storages.values.compactMap { $0.anyValue(for: e) }
    }

    /// Sets a type-erased component value on an entity (used by the editor and deserializer).
    public func addAny(_ value: any Component, to e: Entity) {
        func addOpened<T: Component>(_ v: T) { add(v, to: e) }
        addOpened(value)
    }

    public func removeAny(_ type: any Component.Type, from e: Entity) {
        func removeOpened<T: Component>(_ t: T.Type) { remove(t, from: e) }
        removeOpened(type)
    }

    // MARK: Queries

    private func beginIteration() { iterationDepth += 1 }
    private func endIteration() {
        iterationDepth -= 1
        if iterationDepth == 0 && !deferred.isEmpty {
            let ops = deferred
            deferred.removeAll()
            for op in ops { op() }
        }
    }

    /// Whether a query is currently running (structural operations are being deferred).
    public var isIterating: Bool { iterationDepth > 0 }

    /// Entities that have a component of `type`.
    public func entities<T: Component>(with type: T.Type) -> [Entity] { storage(type)?.entityList() ?? [] }

    /// Iterates every entity with component `A`, providing mutable access.
    public func forEach<A: Component>(_ a: A.Type, _ body: (Entity, inout A) throws -> Void) rethrows {
        guard let sa = storage(a) else { return }
        beginIteration()
        defer { endIteration() }
        var i = 0
        while i < sa.dense.count {
            let e = sa.entities[i]
            var va = sa.dense[i]
            try body(e, &va)
            sa.dense[i] = va
            i += 1
        }
    }

    /// Iterates entities with both `A` and `B`. Iteration is driven by the smaller store.
    public func forEach<A: Component, B: Component>(
        _ a: A.Type, _ b: B.Type, _ body: (Entity, inout A, inout B) throws -> Void
    ) rethrows {
        precondition(A.self != B.self, "forEach requires distinct component types")
        guard let sa = storage(a), let sb = storage(b) else { return }
        beginIteration()
        defer { endIteration() }
        let driverEntities = sa.count <= sb.count ? sa.entities : sb.entities
        for e in driverEntities {
            guard let ia = sa.denseIndex(e), let ib = sb.denseIndex(e) else { continue }
            var va = sa.dense[ia]
            var vb = sb.dense[ib]
            try body(e, &va, &vb)
            sa.dense[ia] = va
            sb.dense[ib] = vb
        }
    }

    /// Iterates entities with `A`, `B` and `C`.
    public func forEach<A: Component, B: Component, C: Component>(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ body: (Entity, inout A, inout B, inout C) throws -> Void
    ) rethrows {
        precondition(A.self != B.self && B.self != C.self && A.self != C.self, "forEach requires distinct types")
        guard let sa = storage(a), let sb = storage(b), let sc = storage(c) else { return }
        beginIteration()
        defer { endIteration() }
        let smallest = [sa.count, sb.count, sc.count].min() ?? 0
        let driver: ContiguousArray<Entity> =
            sa.count == smallest ? sa.entities : (sb.count == smallest ? sb.entities : sc.entities)
        for e in driver {
            guard let ia = sa.denseIndex(e), let ib = sb.denseIndex(e), let ic = sc.denseIndex(e) else { continue }
            var va = sa.dense[ia]
            var vb = sb.dense[ib]
            var vc = sc.dense[ic]
            try body(e, &va, &vb, &vc)
            sa.dense[ia] = va
            sb.dense[ib] = vb
            sc.dense[ic] = vc
        }
    }

    /// Read-only iteration over `A`, skipping the write-back (faster for large stores).
    public func read<A: Component>(_ a: A.Type, _ body: (Entity, A) throws -> Void) rethrows {
        guard let sa = storage(a) else { return }
        beginIteration()
        defer { endIteration() }
        for i in sa.dense.indices { try body(sa.entities[i], sa.dense[i]) }
    }

    /// Borrows the raw dense arrays of `A` for high-performance or parallel processing
    /// (e.g. with `Jobs.parallelFor`). Element `i` of `components` belongs to `entities[i]`.
    /// Structural changes requested during `body` are deferred until it returns.
    public func withDenseStorage<A: Component, R>(
        _ a: A.Type, _ body: (UnsafeBufferPointer<Entity>, UnsafeMutableBufferPointer<A>) throws -> R
    ) rethrows -> R? {
        guard let sa = storage(a) else { return nil }
        beginIteration()
        defer { endIteration() }
        return try sa.entities.withUnsafeBufferPointer { ents in
            try sa.dense.withUnsafeMutableBufferPointer { comps in try body(ents, comps) }
        }
    }

    /// Dense index of `e` within the store of `A`, for use with `withDenseStorage`.
    public func denseIndex<A: Component>(of e: Entity, in a: A.Type) -> Int? { storage(a)?.denseIndex(e) }

    /// Runs deferred structural operations that were queued outside of any iteration
    /// (normally this happens automatically).
    public func flushDeferred() {
        guard iterationDepth == 0 else { return }
        let ops = deferred
        deferred.removeAll()
        for op in ops { op() }
    }

    /// Queues an arbitrary structural operation to run after the current iteration.
    public func deferStructural(_ op: @escaping () -> Void) {
        if iterationDepth > 0 { deferred.append(op) } else { op() }
    }

    // MARK: Resources

    public func setResource<R>(_ value: R) { resources[ObjectIdentifier(R.self)] = value }
    public func resource<R>(_ type: R.Type) -> R? { resources[ObjectIdentifier(type)] as? R }
    public func removeResource<R>(_ type: R.Type) { resources[ObjectIdentifier(type)] = nil }

    /// Registered component types present in this world.
    public var componentTypes: [any Component.Type] { storages.values.map(\.componentType) }
}
