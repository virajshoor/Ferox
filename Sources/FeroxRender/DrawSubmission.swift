/// How one opaque pass submits its draws. Tier-2 devices bind materials from an argument
/// buffer. Metal 3 devices encode an indirect command buffer when every draw's index
/// count is known on the CPU. GPU-culled batches stay immediate: `MTLIndirectRenderCommand`
/// on the macOS 15 SDK has no indirect-argument draw, and the culled counts live in the
/// draw-args buffer. Immediate draws skip rebinding a vertex buffer that did not change.
public enum DrawSubmission: Equatable, Sendable {
    case immediate
    case indirectCommandBuffer
}

public enum DrawPolicy {
    public static func useMaterialArgumentBuffers(argumentBuffersTier: Int) -> Bool {
        argumentBuffersTier >= 2
    }

    /// `gpuIndirectDraws` is true when any batch in the pass will read GPU-written
    /// indirect arguments. Those batches cannot be encoded into an indirect command buffer.
    public static func submission(indirectCommandBuffers: Bool, gpuIndirectDraws: Bool = false) -> DrawSubmission {
        indirectCommandBuffers && !gpuIndirectDraws ? .indirectCommandBuffer : .immediate
    }

    /// The vertex buffer is rebound only when the `MTLBuffer` identity changes.
    public static func shouldBindVertexBuffer(previous: ObjectIdentifier?, next: ObjectIdentifier) -> Bool {
        previous != next
    }
}

/// Material slot for every entry of the instance-index buffer. A batch fills its range
/// with one slot, which stays valid after GPU compaction because compaction writes back
/// into that same range.
public struct MaterialTablePlan: Equatable, Sendable {
    public var slots: [UInt32]
    /// Stable keys in slot order. An empty key is the default material.
    public var keys: [String]

    public static func make(batches: [(key: String, first: Int, count: Int)], indexCount: Int) -> MaterialTablePlan {
        var slots = [UInt32](repeating: 0, count: max(indexCount, 0))
        var indexByKey: [String: UInt32] = [:]
        var keys: [String] = []
        for batch in batches {
            let end = min(batch.first + max(batch.count, 0), slots.count)
            guard batch.first >= 0, batch.first < end else { continue }
            let slot: UInt32
            if let existing = indexByKey[batch.key] {
                slot = existing
            } else {
                slot = UInt32(keys.count)
                indexByKey[batch.key] = slot
                keys.append(batch.key)
            }
            for i in batch.first..<end { slots[i] = slot }
        }
        if keys.isEmpty { keys = [""] }
        return MaterialTablePlan(slots: slots, keys: keys)
    }
}
