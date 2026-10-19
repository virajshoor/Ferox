/// Which transient textures may share heap memory. Lifetimes come from the frame graph:
/// ambient occlusion is consumed before bloom and depth-of-field, so those scratches can
/// alias it. The two LDR targets are a ping-pong and must stay distinct. Multisampled
/// colour and depth stay stored: the prepass and the main pass are separate encoders,
/// so a memoryless attachment would be discarded before the second pass reads it.
public enum TransientResource: String, Sendable, CaseIterable {
    case hdr
    case depth
    case normal
    case motion
    case ambientOcclusion
    case bloom
    case depthOfField
    case ldrA
    case ldrB
}

public struct HeapAliasGroup: Equatable, Sendable {
    public var name: String
    public var members: [TransientResource]
    public init(name: String, members: [TransientResource]) {
        self.name = name
        self.members = members
    }
}

public enum TransientHeapPlan {
    /// MSAA colour and depth cannot be `.memoryless` while prepass and shading are separate.
    public static let msaaAttachmentsAreMemoryless = false

    public static func aliasGroups(ambientOcclusion: Bool, bloom: Bool, depthOfField: Bool) -> [HeapAliasGroup] {
        var scratch: [TransientResource] = []
        if ambientOcclusion { scratch.append(.ambientOcclusion) }
        if bloom { scratch.append(.bloom) }
        if depthOfField { scratch.append(.depthOfField) }
        var groups = [
            HeapAliasGroup(name: "ldrA", members: [.ldrA]),
            HeapAliasGroup(name: "ldrB", members: [.ldrB]),
        ]
        if scratch.count > 1 {
            groups.append(HeapAliasGroup(name: "postScratch", members: scratch))
        }
        return groups
    }

    /// Resources that appear together in one group may be placed at the same heap offset.
    public static func mayAlias(_ a: TransientResource, _ b: TransientResource, groups: [HeapAliasGroup]) -> Bool {
        guard a != b else { return false }
        return groups.contains { $0.members.contains(a) && $0.members.contains(b) }
    }
}
