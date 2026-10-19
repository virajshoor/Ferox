import FeroxMath

/// Layout of one `MTLDrawIndexedPrimitivesIndirectArguments` record.
///
/// The Metal struct is five `UInt32`s, but `drawIndexedPrimitives` requires a 16-byte-aligned
/// offset. A 20-byte stride leaves batches 1, 2, 3, 5, … misaligned when the buffer base is
/// aligned. Each record is therefore 32 bytes (8 uints). The first five words are the draw
/// arguments; the rest are padding the cull kernels skip.
public enum IndirectDrawLayout {
    public static let strideBytes = 32
    public static let words = 8
    public static let indexCount = 0
    public static let instanceCount = 1
    public static let indexStart = 2
    public static let baseVertex = 3
    public static let baseInstance = 4
    /// CPU flag read by `encodeCulledDraws`. Not part of the Metal draw-argument struct.
    public static let skinned = 5

    public static func byteOffset(ofBatch index: Int, base: Int = 0) -> Int {
        base + index * strideBytes
    }

    /// True when `offset` is legal for `drawIndexedPrimitives`'s indirect buffer.
    public static func isValidGPUOffset(_ offset: Int) -> Bool {
        offset & 15 == 0
    }
}

/// One instance referenced by one opaque batch. An instance with several submeshes has
/// one membership per submesh, so GPU culling can append it to every batch it draws.
public struct BatchMembership: Equatable, Sendable {
    public var instance: UInt32
    public var batch: UInt32
    public init(instance: UInt32, batch: UInt32) {
        self.instance = instance
        self.batch = batch
    }
}

/// CPU-side plan for the GPU cull: every opaque batch is cullable, and each
/// (instance, batch) pair is listed so a second kernel can build every submesh's
/// indirect arguments from one visibility result.
public struct CullingPlan: Equatable, Sendable {
    public var cullable: [Bool]
    public var memberships: [BatchMembership]
    /// `IndirectDrawLayout.words` uints per opaque batch. `instanceCount` starts at 0;
    /// `baseInstance` is the batch's slot in the instance-index buffer.
    public var drawArgs: [UInt32]

    public static func make(batches: [DrawBatch], instanceIndices: [UInt32]) -> CullingPlan {
        var cullable = [Bool](repeating: false, count: batches.count)
        var memberships: [BatchMembership] = []
        memberships.reserveCapacity(instanceIndices.count)
        var drawArgs: [UInt32] = []
        drawArgs.reserveCapacity(batches.count * IndirectDrawLayout.words)
        for (bi, b) in batches.enumerated() {
            let count = max(b.instanceCount, 0)
            cullable[bi] = count > 0
            var words = [UInt32](repeating: 0, count: IndirectDrawLayout.words)
            words[IndirectDrawLayout.baseInstance] = UInt32(b.firstInstance)
            drawArgs.append(contentsOf: words)
            let end = min(b.firstInstance + count, instanceIndices.count)
            guard b.firstInstance < end else { continue }
            for k in b.firstInstance..<end {
                memberships.append(BatchMembership(instance: instanceIndices[k], batch: UInt32(bi)))
            }
        }
        return CullingPlan(cullable: cullable, memberships: memberships, drawArgs: drawArgs)
    }
}

/// Bounding-sphere tests shared by local shadow selection and cascade skips.
public enum BatchCulling {
    /// Sphere enclosing every instance the batch draws. Nil when none are in range.
    public static func sphere(batch: DrawBatch, instanceIndices: [UInt32], instances: [InstanceData]) -> Vec4? {
        let end = min(batch.firstInstance + max(batch.instanceCount, 0), instanceIndices.count)
        guard batch.firstInstance < end else { return nil }
        var center = Vec3.zero
        var radius: Float = -1
        for k in batch.firstInstance..<end {
            let i = Int(instanceIndices[k])
            guard i < instances.count else { continue }
            let s = instances[i].bounds
            if radius < 0 {
                center = s.xyz
                radius = s.w
                continue
            }
            let delta = s.xyz - center
            let dist = delta.length
            if dist + s.w <= radius { continue }
            if dist + radius <= s.w {
                center = s.xyz
                radius = s.w
                continue
            }
            let newRadius = (radius + dist + s.w) * 0.5
            let t = dist > 1e-8 ? (newRadius - radius) / dist : 0
            center = center + delta * t
            radius = newRadius
        }
        guard radius >= 0 else { return nil }
        return Vec4(center, radius)
    }

    /// True when `sphere` can reach a light of the given range.
    public static func reaches(sphere: Vec4, lightPosition: Vec3, lightRange: Float) -> Bool {
        let reach = lightRange + sphere.w
        return (sphere.xyz - lightPosition).lengthSquared <= reach * reach
    }
}

/// How a texture's pixels get to the GPU. Discrete GPUs cannot rely on a managed
/// `replace` without a following synchronize; the renderer stages a blit into private
/// storage instead. Unified memory writes a shared texture directly.
public enum GPUTextureUpload: String, Sendable, Equatable {
    case sharedReplace
    case stagingBlitToPrivate

    public static func path(unifiedMemory: Bool) -> GPUTextureUpload {
        unifiedMemory ? .sharedReplace : .stagingBlitToPrivate
    }
}
