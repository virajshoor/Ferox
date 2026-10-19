/// Passes that read or write a transient target, in encode order. A resource's lifetime is
/// the closed interval from its first use to its last use. History and Hi-Z stay out of this
/// set: both are read on a later frame.
public enum FrameStage: Int, Sendable, Comparable, CaseIterable {
    case prepass = 0
    case rayTrace = 1
    case ssao = 2
    case forward = 3
    case temporal = 4
    case depthOfField = 5
    case motionBlur = 6
    case bloom = 7
    case tonemap = 8
    case postAA = 9
    case present = 10

    public static func < (lhs: FrameStage, rhs: FrameStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which transient textures may share heap memory. Lifetimes come from the frame graph.
/// Two resources alias only when their intervals do not overlap. `ldrA` and `ldrB` are a
/// ping-pong and always overlap. Multisampled colour and depth stay stored: the prepass
/// and the main pass are separate encoders, so a memoryless attachment would be discarded
/// before the second pass reads it. Their memory can still alias with post scratches that
/// start after the forward pass.
public enum TransientResource: String, Sendable, CaseIterable {
    case hdr
    case depth
    case normal
    case motion
    case depthMSAA
    case hdrMSAA
    case normalMSAA
    case motionMSAA
    case ambientOcclusion
    case ssaoRaw
    case bloom
    case depthOfField
    case motionBlur
    case smaaEdges
    case smaaWeights
    case ldrA
    case ldrB
}

public struct HeapFeatures: Equatable, Sendable {
    public var geometryPrepass = true
    public var ambientOcclusion = false
    public var rayTracing = false
    public var temporal = false
    public var depthOfField = false
    public var motionBlur = false
    public var bloom = false
    public var smaa = false
    public var msaa = false
    public init() {}
}

public struct ResourceLifetime: Equatable, Sendable {
    public var resource: TransientResource
    public var first: FrameStage
    public var last: FrameStage
    public init(resource: TransientResource, first: FrameStage, last: FrameStage) {
        self.resource = resource
        self.first = first
        self.last = last
    }
}

public struct TransientFootprint: Equatable, Sendable {
    public var resource: TransientResource
    public var byteSize: Int
    public var alignment: Int
    public init(resource: TransientResource, byteSize: Int, alignment: Int = 256) {
        self.resource = resource
        self.byteSize = byteSize
        self.alignment = max(alignment, 1)
    }
}

public struct HeapPlacement: Equatable, Sendable {
    public var resource: TransientResource
    public var offset: Int
    public var size: Int
    public init(resource: TransientResource, offset: Int, size: Int) {
        self.resource = resource
        self.offset = offset
        self.size = size
    }
}

/// `source` finishes before `destination` reuses the same bytes. The encoder that ends
/// `source` signals a fence; the encoder that starts `destination` waits.
public struct AliasBarrier: Equatable, Sendable {
    public var source: TransientResource
    public var destination: TransientResource
    public init(source: TransientResource, destination: TransientResource) {
        self.source = source
        self.destination = destination
    }
}

public struct HeapLayout: Equatable, Sendable {
    public var placements: [HeapPlacement]
    public var barriers: [AliasBarrier]
    public var byteSize: Int
    public init(placements: [HeapPlacement], barriers: [AliasBarrier], byteSize: Int) {
        self.placements = placements
        self.barriers = barriers
        self.byteSize = byteSize
    }

    public func placement(of resource: TransientResource) -> HeapPlacement? {
        placements.first { $0.resource == resource }
    }
}

public struct TransientRequest: Equatable, Sendable {
    public var resource: TransientResource
    public var width: Int
    public var height: Int
    public var mipLevels: Int
    public var sampleCount: Int
    public init(resource: TransientResource, width: Int, height: Int, mipLevels: Int = 1, sampleCount: Int = 1) {
        self.resource = resource
        self.width = width
        self.height = height
        self.mipLevels = mipLevels
        self.sampleCount = sampleCount
    }
}

public enum TransientHeapPlan {
    /// MSAA colour and depth cannot be `.memoryless` while prepass and shading are separate.
    public static let msaaAttachmentsAreMemoryless = false

    /// Label used by `PostProcessor` for a scratch that was placed on the heap.
    public static func label(_ resource: TransientResource) -> String? {
        switch resource {
        case .ssaoRaw: return "Ferox.SSAORaw"
        case .depthOfField: return "Ferox.DOF"
        case .motionBlur: return "Ferox.MotionBlur"
        case .bloom: return "Ferox.Bloom"
        case .smaaEdges: return "Ferox.SMAAEdges"
        case .smaaWeights: return "Ferox.SMAAWeights"
        default: return nil
        }
    }

    public static func resource(forLabel label: String) -> TransientResource? {
        switch label {
        case "Ferox.SSAORaw": return .ssaoRaw
        case "Ferox.DOF": return .depthOfField
        case "Ferox.MotionBlur": return .motionBlur
        case "Ferox.Bloom": return .bloom
        case "Ferox.SMAAEdges": return .smaaEdges
        case "Ferox.SMAAWeights": return .smaaWeights
        default: return nil
        }
    }

    /// Sizes of every transient the frame will allocate. Bloom is half the working resolution
    /// (output resolution once a temporal upscale has run).
    public static func requests(
        renderWidth: Int, renderHeight: Int, outputWidth: Int, outputHeight: Int, features: HeapFeatures,
        msaaSamples: Int
    ) -> [TransientRequest] {
        let rw = max(renderWidth, 1)
        let rh = max(renderHeight, 1)
        let ow = max(outputWidth, 1)
        let oh = max(outputHeight, 1)
        let working = features.temporal ? (ow, oh) : (rw, rh)
        let samples = features.msaa ? max(msaaSamples, 2) : 1
        var out: [TransientRequest] = [
            TransientRequest(resource: .hdr, width: rw, height: rh),
            TransientRequest(resource: .depth, width: rw, height: rh),
            TransientRequest(resource: .ldrA, width: ow, height: oh),
            TransientRequest(resource: .ldrB, width: ow, height: oh),
        ]
        if features.geometryPrepass {
            out.append(TransientRequest(resource: .normal, width: rw, height: rh))
            out.append(TransientRequest(resource: .motion, width: rw, height: rh))
        }
        if features.msaa {
            out.append(TransientRequest(resource: .depthMSAA, width: rw, height: rh, sampleCount: samples))
            out.append(TransientRequest(resource: .hdrMSAA, width: rw, height: rh, sampleCount: samples))
            if features.geometryPrepass {
                out.append(TransientRequest(resource: .normalMSAA, width: rw, height: rh, sampleCount: samples))
                out.append(TransientRequest(resource: .motionMSAA, width: rw, height: rh, sampleCount: samples))
            }
        }
        if features.ambientOcclusion {
            out.append(TransientRequest(resource: .ambientOcclusion, width: rw, height: rh))
            out.append(TransientRequest(resource: .ssaoRaw, width: rw, height: rh))
        }
        if features.depthOfField {
            out.append(TransientRequest(resource: .depthOfField, width: working.0, height: working.1))
        }
        if features.motionBlur {
            out.append(TransientRequest(resource: .motionBlur, width: working.0, height: working.1))
        }
        if features.bloom {
            let mips = PostUniformsBuilder.bloomMipCount(width: working.0, height: working.1)
            out.append(
                TransientRequest(
                    resource: .bloom, width: max(working.0 / 2, 1), height: max(working.1 / 2, 1), mipLevels: mips))
        }
        if features.smaa {
            out.append(TransientRequest(resource: .smaaEdges, width: working.0, height: working.1))
            out.append(TransientRequest(resource: .smaaWeights, width: working.0, height: working.1))
        }
        return out
    }

    public static func lifetimes(_ features: HeapFeatures) -> [ResourceLifetime] {
        var lives: [ResourceLifetime] = [
            ResourceLifetime(resource: .hdr, first: .forward, last: hdrLast(features)),
            ResourceLifetime(resource: .depth, first: .prepass, last: .present),
            ResourceLifetime(resource: .ldrA, first: .tonemap, last: .present),
            ResourceLifetime(resource: .ldrB, first: .tonemap, last: .present),
        ]
        if features.geometryPrepass {
            let normalLast: FrameStage = (features.ambientOcclusion || features.rayTracing) ? .rayTrace : .prepass
            lives.append(ResourceLifetime(resource: .normal, first: .prepass, last: normalLast))
            let motionLast = max(
                features.temporal ? FrameStage.temporal : .prepass, features.motionBlur ? .motionBlur : .prepass)
            lives.append(ResourceLifetime(resource: .motion, first: .prepass, last: motionLast))
        }
        if features.msaa {
            lives.append(ResourceLifetime(resource: .depthMSAA, first: .prepass, last: .forward))
            lives.append(ResourceLifetime(resource: .hdrMSAA, first: .forward, last: .forward))
            if features.geometryPrepass {
                lives.append(ResourceLifetime(resource: .normalMSAA, first: .prepass, last: .prepass))
                lives.append(ResourceLifetime(resource: .motionMSAA, first: .prepass, last: .prepass))
            }
        }
        if features.ambientOcclusion {
            lives.append(ResourceLifetime(resource: .ambientOcclusion, first: .ssao, last: .forward))
            lives.append(ResourceLifetime(resource: .ssaoRaw, first: .ssao, last: .ssao))
        }
        if features.depthOfField {
            lives.append(
                ResourceLifetime(resource: .depthOfField, first: .depthOfField, last: afterDepthOfField(features)))
        }
        if features.motionBlur {
            lives.append(ResourceLifetime(resource: .motionBlur, first: .motionBlur, last: afterMotionBlur(features)))
        }
        if features.bloom {
            lives.append(ResourceLifetime(resource: .bloom, first: .bloom, last: .tonemap))
        }
        if features.smaa {
            lives.append(ResourceLifetime(resource: .smaaEdges, first: .postAA, last: .postAA))
            lives.append(ResourceLifetime(resource: .smaaWeights, first: .postAA, last: .postAA))
        }
        return lives
    }

    /// First-fit pack. Overlapping lifetimes cannot share bytes. Non-overlapping ones can,
    /// and each such pair becomes a barrier.
    public static func layout(footprints: [TransientFootprint], features: HeapFeatures) -> HeapLayout {
        let live = Dictionary(uniqueKeysWithValues: lifetimes(features).map { ($0.resource, $0) })
        var items: [(TransientFootprint, ResourceLifetime)] = []
        for footprint in footprints {
            guard footprint.byteSize > 0, let life = live[footprint.resource] else { continue }
            items.append((footprint, life))
        }
        items.sort { lhs, rhs in
            if lhs.1.first != rhs.1.first { return lhs.1.first < rhs.1.first }
            return lhs.0.byteSize > rhs.0.byteSize
        }
        var placed: [(HeapPlacement, ResourceLifetime)] = []
        for (footprint, life) in items {
            let alignment = footprint.alignment
            var offset = 0
            var settled = false
            var guardSteps = items.count * items.count + 4
            while !settled && guardSteps > 0 {
                guardSteps -= 1
                let aligned = (offset + alignment - 1) / alignment * alignment
                let end = aligned + footprint.byteSize
                if let blocker = placed.first(where: { other in
                    let overlapsTime = !(life.last < other.1.first || other.1.last < life.first)
                    let otherEnd = other.0.offset + other.0.size
                    let overlapsMemory = !(end <= other.0.offset || otherEnd <= aligned)
                    return overlapsTime && overlapsMemory
                }) {
                    offset = blocker.0.offset + blocker.0.size
                    continue
                }
                offset = aligned
                settled = true
            }
            placed.append((HeapPlacement(resource: footprint.resource, offset: offset, size: footprint.byteSize), life))
        }
        var barriers: [AliasBarrier] = []
        for i in placed.indices {
            for j in placed.indices where i != j {
                let a = placed[i]
                let b = placed[j]
                guard a.1.last < b.1.first else { continue }
                let aEnd = a.0.offset + a.0.size
                let bEnd = b.0.offset + b.0.size
                let overlaps = !(aEnd <= b.0.offset || bEnd <= a.0.offset)
                if overlaps {
                    barriers.append(AliasBarrier(source: a.0.resource, destination: b.0.resource))
                }
            }
        }
        let byteSize = placed.map { $0.0.offset + $0.0.size }.max() ?? 0
        return HeapLayout(placements: placed.map(\.0), barriers: barriers, byteSize: byteSize)
    }

    public static func overlaps(_ a: ResourceLifetime, _ b: ResourceLifetime) -> Bool {
        !(a.last < b.first || b.last < a.first)
    }

    private static func hdrLast(_ features: HeapFeatures) -> FrameStage {
        if features.temporal { return .temporal }
        if features.depthOfField { return .depthOfField }
        if features.motionBlur { return .motionBlur }
        return .tonemap
    }

    private static func afterDepthOfField(_ features: HeapFeatures) -> FrameStage {
        if features.motionBlur { return .motionBlur }
        if features.bloom { return .bloom }
        return .tonemap
    }

    private static func afterMotionBlur(_ features: HeapFeatures) -> FrameStage {
        features.bloom ? .bloom : .tonemap
    }
}
