import FeroxMath

/// Motion-vector scale and jitter offset passed to `MTLFXTemporalScaler`.
///
/// Ferox motion vectors are current − previous in UV units, so the scale is (−width, −height).
/// Jitter is stored in NDC (two pixels per unit of clip space) and MetalFX wants input pixels,
/// with Y flipped to match the motion-vector convention.
public struct MetalFXTemporalMapping: Equatable, Sendable {
    public var motionScaleX: Float
    public var motionScaleY: Float
    public var jitterOffsetX: Float
    public var jitterOffsetY: Float

    public init(motionScaleX: Float, motionScaleY: Float, jitterOffsetX: Float, jitterOffsetY: Float) {
        self.motionScaleX = motionScaleX
        self.motionScaleY = motionScaleY
        self.jitterOffsetX = jitterOffsetX
        self.jitterOffsetY = jitterOffsetY
    }

    public static func make(renderWidth: Int, renderHeight: Int, jitterNDC: Vec2) -> MetalFXTemporalMapping {
        let width = Float(max(renderWidth, 1))
        let height = Float(max(renderHeight, 1))
        return MetalFXTemporalMapping(
            motionScaleX: -width, motionScaleY: -height,
            jitterOffsetX: jitterNDC.x * 0.5 * width, jitterOffsetY: -jitterNDC.y * 0.5 * height)
    }
}

/// Result of asking MetalFX whether it can build a temporal scaler for Ferox's target formats.
/// `depthFormat` is the pixel-format name that was requested (`depth32Float_stencil8`).
public struct MetalFXProbeResult: Equatable, Sendable {
    public var attempted: Bool
    public var scalerCreated: Bool
    public var depthFormatAccepted: Bool
    public var depthFormat: String
    public var unavailableReason: String?
    public var mapping: MetalFXTemporalMapping

    public static func notAttempted(
        reason: String,
        mapping: MetalFXTemporalMapping = .make(
            renderWidth: 1, renderHeight: 1, jitterNDC: .zero)
    ) -> MetalFXProbeResult {
        MetalFXProbeResult(
            attempted: false, scalerCreated: false, depthFormatAccepted: false,
            depthFormat: "depth32Float_stencil8", unavailableReason: reason, mapping: mapping)
    }
}
