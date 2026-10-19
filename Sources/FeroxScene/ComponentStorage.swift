import FeroxCore
import Foundation

/// A component is plain data attached to an entity. Components should be value types
/// (structs or enums); behaviour lives in systems.
public protocol Component {}

/// Type-erased view of a component store, used by the world for structural operations.
public protocol AnyComponentStorage: AnyObject {
    var componentType: any Component.Type { get }
    var count: Int { get }
    func contains(_ e: Entity) -> Bool
    func remove(_ e: Entity)
    func entityList() -> [Entity]
    func anyValue(for e: Entity) -> (any Component)?
    func setAny(_ value: any Component, for e: Entity) -> Bool
    func removeAll()
}

/// Sparse-set storage for one component type.
///
/// - `dense` holds component values contiguously (cache-friendly iteration).
/// - `entities[i]` is the owner of `dense[i]`.
/// - `sparse[entity.index]` maps back to the dense slot (or -1).
///
/// Insertion, removal (swap-with-last) and lookup are O(1). Iteration order is dense
/// order, which changes on removal; never rely on it being stable.
public final class ComponentStorage<T: Component>: AnyComponentStorage {
    var dense: ContiguousArray<T> = []
    var entities: ContiguousArray<Entity> = []
    var sparse: ContiguousArray<Int32> = []

    public init() {}

    public var componentType: any Component.Type { T.self }
    public var count: Int { dense.count }

    func denseIndex(_ e: Entity) -> Int? {
        let i = Int(e.index)
        guard i < sparse.count else { return nil }
        let d = Int(sparse[i])
        guard d >= 0, entities[d] == e else { return nil }
        return d
    }

    public func contains(_ e: Entity) -> Bool { denseIndex(e) != nil }

    func insert(_ value: T, for e: Entity) {
        if let d = denseIndex(e) {
            dense[d] = value
            return
        }
        let i = Int(e.index)
        if i >= sparse.count {
            let newCount = Swift.max(i + 1, sparse.count * 2, 64)
            sparse.append(contentsOf: repeatElement(-1, count: newCount - sparse.count))
        }
        sparse[i] = Int32(dense.count)
        dense.append(value)
        entities.append(e)
    }

    public func remove(_ e: Entity) {
        guard let d = denseIndex(e) else { return }
        let last = dense.count - 1
        if d != last {
            dense.swapAt(d, last)
            entities.swapAt(d, last)
            sparse[Int(entities[d].index)] = Int32(d)
        }
        dense.removeLast()
        entities.removeLast()
        sparse[Int(e.index)] = -1
    }

    func get(_ e: Entity) -> T? {
        guard let d = denseIndex(e) else { return nil }
        return dense[d]
    }

    public func entityList() -> [Entity] { Array(entities) }
    public func anyValue(for e: Entity) -> (any Component)? { get(e) }
    public func setAny(_ value: any Component, for e: Entity) -> Bool {
        guard let v = value as? T else { return false }
        insert(v, for: e)
        return true
    }
    public func removeAll() {
        dense.removeAll()
        entities.removeAll()
        sparse.removeAll()
    }
}
