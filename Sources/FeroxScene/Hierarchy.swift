import FeroxCore
import Foundation

extension World {
    public func parent(of e: Entity) -> Entity? {
        guard let p = get(Parent.self, e)?.entity, isAlive(p) else { return nil }
        return p
    }

    public func children(of e: Entity) -> [Entity] { get(Children.self, e)?.entities ?? [] }

    /// Re-parents `child` under `parent` (or makes it a root when `parent` is `.null`).
    ///
    /// - Parameter keepWorldTransform: when true the child's local transform is recomputed
    ///   so it does not move in world space (editor drag-and-drop behaviour).
    /// - Returns: false if the operation would create a cycle or an entity is dead.
    @discardableResult
    public func setParent(_ child: Entity, _ parent: Entity, keepWorldTransform: Bool = false) -> Bool {
        guard isAlive(child), parent.isNull || isAlive(parent), child != parent else { return false }
        // Reject cycles: parent must not be a descendant of child.
        var cursor: Entity? = parent.isNull ? nil : parent
        while let c = cursor {
            if c == child { return false }
            cursor = self.parent(of: c)
        }
        let world = keepWorldTransform ? worldMatrix(of: child) : nil
        detachFromParent(child)
        if !parent.isNull {
            add(Parent(entity: parent), to: child)
            if modify(Children.self, parent, { $0.entities.append(child) }) == nil {
                add(Children(entities: [child]), to: parent)
            }
        }
        if let world {
            let parentWorld = parent.isNull ? Mat4.identity : worldMatrix(of: parent)
            let local = parentWorld.inverse * world
            modify(Transform.self, child) { $0.trs = TRS(matrix: local) }
        }
        modify(Transform.self, child) { $0.isDirty = true }
        return true
    }

    func detachFromParent(_ child: Entity) {
        guard let p = get(Parent.self, child)?.entity else { return }
        modify(Children.self, p) { $0.entities.removeAll { $0 == child } }
        if let c = get(Children.self, p), c.entities.isEmpty { remove(Children.self, from: p) }
        remove(Parent.self, from: child)
    }

    /// Root entities (those with a `Transform` and no parent), in entity index order.
    public var rootEntities: [Entity] {
        entities(with: Transform.self).filter { parent(of: $0) == nil }.sorted()
    }

    /// Depth-first traversal of `e` and its descendants.
    public func visitSubtree(_ e: Entity, depth: Int = 0, _ visit: (Entity, Int) -> Void) {
        visit(e, depth)
        for c in children(of: e) { visitSubtree(c, depth: depth + 1, visit) }
    }

    /// World matrix computed on demand from local `Transform`s by walking up the hierarchy
    /// (at most 1024 ancestors). Prefer `WorldTransform` in systems: it is cached per frame.
    public func worldMatrix(of e: Entity) -> Mat4 {
        // Component stores are fetched once, outside the ancestor loop.
        let transforms = storage(Transform.self)
        let parents = storage(Parent.self)
        var m = transforms?.get(e)?.localMatrix ?? .identity
        var cursor = parentLink(of: e, in: parents)
        var guardCount = 0
        while let p = cursor, guardCount < 1024 {
            m = (transforms?.get(p)?.localMatrix ?? .identity) * m
            cursor = parentLink(of: p, in: parents)
            guardCount += 1
        }
        return m
    }

    /// Same result as `parent(of:)`, using an already-fetched `Parent` store.
    private func parentLink(of e: Entity, in parents: ComponentStorage<Parent>?) -> Entity? {
        guard let p = parents?.get(e)?.entity, isAlive(p) else { return nil }
        return p
    }

    /// Sets an entity's world position, adjusting its local transform for the parent.
    public func setWorldPosition(_ e: Entity, _ p: Vec3) {
        let local = parent(of: e).map { worldMatrix(of: $0).inverse.transformPoint(p) } ?? p
        modify(Transform.self, e) { $0.position = local }
    }

    /// Whether `e` or any ancestor is `Disabled`.
    public func isActiveInHierarchy(_ e: Entity) -> Bool {
        // Disabled and Parent stores are fetched once, outside the ancestor loop.
        let disabled = storage(Disabled.self)
        let parents = storage(Parent.self)
        var cursor: Entity? = e
        while let c = cursor {
            if disabled?.contains(c) == true { return false }
            cursor = parentLink(of: c, in: parents)
        }
        return true
    }

    /// Finds the first entity with the given name (linear; cache the result).
    public func find(named name: String) -> Entity? {
        var found: Entity?
        read(Name.self) { e, n in if found == nil && n.value == name { found = e } }
        return found
    }

    /// Entities carrying `tag`.
    public func entities(tagged tag: String) -> [Entity] {
        var out: [Entity] = []
        read(Tags.self) { e, t in if t.values.contains(tag) { out.append(e) } }
        return out
    }

    /// Entities in `group`.
    public func entities(inGroup group: String) -> [Entity] {
        var out: [Entity] = []
        read(Groups.self) { e, g in if g.names.contains(group) { out.append(e) } }
        return out
    }
}
