/// Decides which resident GPU meshes to drop. Idle meshes go first. If the real buffer
/// bytes (`GPUMesh.byteCount`, not a vertex-count estimate) still exceed the asset budget,
/// the least-recently-used meshes that were not drawn this frame are dropped until it fits.
public struct ResidentMesh: Equatable, Sendable {
    public var key: String
    public var byteCount: Int
    public var lastUsedFrame: UInt64
    public init(key: String, byteCount: Int, lastUsedFrame: UInt64) {
        self.key = key
        self.byteCount = byteCount
        self.lastUsedFrame = lastUsedFrame
    }
}

public enum MeshResidencyPlanner {
    public static func victims(
        residents: [ResidentMesh], frame: UInt64, maxIdleFrames: UInt64, budgetBytes: Int
    ) -> [String] {
        var doomed: [String] = []
        var kept: [ResidentMesh] = []
        kept.reserveCapacity(residents.count)
        var bytes = 0
        for mesh in residents {
            if frame > mesh.lastUsedFrame &+ maxIdleFrames {
                doomed.append(mesh.key)
            } else {
                kept.append(mesh)
                bytes += mesh.byteCount
            }
        }
        guard budgetBytes >= 0, bytes > budgetBytes else { return doomed }
        let lru = kept.sorted { lhs, rhs in
            if lhs.lastUsedFrame != rhs.lastUsedFrame { return lhs.lastUsedFrame < rhs.lastUsedFrame }
            return lhs.key < rhs.key
        }
        for mesh in lru where bytes > budgetBytes && mesh.lastUsedFrame != frame {
            doomed.append(mesh.key)
            bytes -= mesh.byteCount
        }
        return doomed
    }
}
