import Foundation
import FeroxCore

/// Computes `WorldTransform` for every entity with a `Transform`.
///
/// Performance characteristics:
/// - Root entities without children (the common case for sprites, particles-as-entities
///   and physics bodies) are processed in parallel straight from the dense arrays.
/// - Hierarchies are walked depth-first from each dirty root; clean subtrees are skipped
///   unless an ancestor changed.
/// - `previous` is rolled forward once per frame so motion vectors are exact.
public enum TransformSystem {
    /// Updates world transforms. Call once per rendered frame (after gameplay and physics).
    public static func update(_ world: World) {
        // Ensure every Transform has a WorldTransform. The store is looked up once here,
        // not per entity; a nil store means no entity has the component yet.
        var missing: [Entity] = []
        let presentWorld = world.storage(WorldTransform.self)
        world.read(Transform.self) { e, _ in if presentWorld?.denseIndex(e) == nil { missing.append(e) } }
        for e in missing { world.add(WorldTransform(), to: e) }

        // Pass 1 — flat roots (no Parent, no Children), in parallel.
        // Component stores are fetched once before the parallel loop (not per entity), so
        // the loop only performs dense-index reads on them. Fetched after the step above,
        // which may have created the WorldTransform store.
        let parentStore = world.storage(Parent.self)
        let childrenStore = world.storage(Children.self)
        let worldStore = world.storage(WorldTransform.self)
        _ = world.withDenseStorage(Transform.self) { ents, transforms in
            _ = world.withDenseStorage(WorldTransform.self) { _, worlds in
                Jobs.parallelFor(count: ents.count, minChunk: 2048) { range in
                    for i in range {
                        let e = ents[i]
                        guard parentStore?.denseIndex(e) == nil,
                            childrenStore?.denseIndex(e) == nil,
                            let wi = worldStore?.denseIndex(e)
                        else { continue }
                        var w = worlds[wi]
                        if w.resetHistory {
                            w.matrix = transforms[i].localMatrix
                            w.previous = w.matrix
                            w.resetHistory = false
                            transforms[i].isDirty = false
                        } else {
                            w.previous = w.matrix
                            if transforms[i].isDirty {
                                w.matrix = transforms[i].localMatrix
                                transforms[i].isDirty = false
                            }
                        }
                        worlds[wi] = w
                    }
                }
            }
        }

        // Pass 2 — hierarchy roots (no Parent but has Children), recursively.
        for root in world.entities(with: Children.self) where world.get(Parent.self, root) == nil {
            updateSubtree(world, root, parentMatrix: .identity, parentChanged: false)
        }
    }

    private static func updateSubtree(_ world: World, _ e: Entity, parentMatrix: Mat4, parentChanged: Bool) {
        guard var t = world.get(Transform.self, e) else {
            // Entities without a Transform still propagate their parent's matrix.
            for c in world.children(of: e) { updateSubtree(world, c, parentMatrix: parentMatrix, parentChanged: parentChanged) }
            return
        }
        var w = world.get(WorldTransform.self, e) ?? WorldTransform()
        let changed = parentChanged || t.isDirty || w.resetHistory
        w.previous = w.matrix
        if changed {
            w.matrix = parentMatrix * t.localMatrix
            t.isDirty = false
            world.set(t, for: e)
        }
        if w.resetHistory {
            w.previous = w.matrix
            w.resetHistory = false
        }
        world.set(w, for: e)
        for c in world.children(of: e) { updateSubtree(world, c, parentMatrix: w.matrix, parentChanged: changed) }
    }

    /// Marks an entity as teleported: next frame's motion vectors will be zero.
    public static func resetHistory(_ world: World, _ e: Entity) {
        world.modify(WorldTransform.self, e) { $0.resetHistory = true }
    }
}
