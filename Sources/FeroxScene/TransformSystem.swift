import FeroxCore
import Foundation

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
        // Membership is resolved on this thread. Workers receive only the index pairs and
        // the dense buffers, and each worker writes a disjoint range of those buffers.
        let parentStore = world.storage(Parent.self)
        let childrenStore = world.storage(Children.self)
        let worldStore = world.storage(WorldTransform.self)
        _ = world.withDenseStorage(Transform.self) { ents, transforms in
            _ = world.withDenseStorage(WorldTransform.self) { _, worlds in
                let pairs = FlatRootPlan.pairs(
                    entityCount: ents.count,
                    isFlatRoot: { i in
                        let e = ents[i]
                        return parentStore?.denseIndex(e) == nil && childrenStore?.denseIndex(e) == nil
                    },
                    worldIndex: { worldStore?.denseIndex(ents[$0]) })
                guard !pairs.isEmpty, let transformBase = transforms.baseAddress, let worldBase = worlds.baseAddress
                else { return }
                pairs.withUnsafeBufferPointer { pairBuf in
                    guard let pairBase = pairBuf.baseAddress else { return }
                    let sharedPairs = SharedReadBuffer(base: pairBase, count: pairBuf.count)
                    let sharedTransforms = SharedBuffer(base: transformBase, count: transforms.count)
                    let sharedWorlds = SharedBuffer(base: worldBase, count: worlds.count)
                    Jobs.parallelFor(count: sharedPairs.count, minChunk: 2048) { range in
                        for i in range {
                            let pair = sharedPairs[i]
                            var transform = sharedTransforms[pair.transform]
                            var world = sharedWorlds[pair.world]
                            FlatRootPlan.write(transform: &transform, world: &world)
                            sharedTransforms[pair.transform] = transform
                            sharedWorlds[pair.world] = world
                        }
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
            for c in world.children(of: e) {
                updateSubtree(world, c, parentMatrix: parentMatrix, parentChanged: parentChanged)
            }
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

/// One flat root: an index into the transform dense array and one into the world-transform array.
struct FlatRootPair: Equatable, Sendable {
    var transform: Int
    var world: Int
}

/// Builds the flat-root list on the calling thread and applies one root's matrix update.
enum FlatRootPlan {
    static func pairs(entityCount: Int, isFlatRoot: (Int) -> Bool, worldIndex: (Int) -> Int?) -> [FlatRootPair] {
        var out: [FlatRootPair] = []
        out.reserveCapacity(entityCount)
        for i in 0..<max(entityCount, 0) {
            guard isFlatRoot(i), let world = worldIndex(i) else { continue }
            out.append(FlatRootPair(transform: i, world: world))
        }
        return out
    }

    static func write(transform: inout Transform, world: inout WorldTransform) {
        if world.resetHistory {
            world.matrix = transform.localMatrix
            world.previous = world.matrix
            world.resetHistory = false
            transform.isDirty = false
        } else {
            world.previous = world.matrix
            if transform.isDirty {
                world.matrix = transform.localMatrix
                transform.isDirty = false
            }
        }
    }
}

/// Pointers shared with `Jobs.parallelFor`. The caller keeps the buffers alive for the
/// call and gives each worker a disjoint index range. The type is unchecked because a
/// raw pointer is not `Sendable`.
private struct SharedBuffer<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
    let count: Int
    subscript(index: Int) -> T {
        get { base[index] }
        nonmutating set { base[index] = newValue }
    }
}

private struct SharedReadBuffer<T>: @unchecked Sendable {
    let base: UnsafePointer<T>
    let count: Int
    subscript(index: Int) -> T { base[index] }
}
