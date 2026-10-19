import FeroxMath

/// Which passes a frame actually needs. A sprite-only scene does not need a G-buffer,
/// and a scene with no tone map or post effect can draw those sprites straight into LDR.
public enum FramePath {
    /// Depth, normal and motion are required when opaque geometry is drawn or when a
    /// later pass samples the G-buffer (SSAO, TAA, motion blur, ray tracing).
    public static func needsGeometryPrepass(
        opaqueCount: Int, screenSpaceAO: Bool, temporal: Bool, motionBlur: Bool, rayTracing: Bool
    ) -> Bool {
        opaqueCount > 0 || screenSpaceAO || temporal || motionBlur || rayTracing
    }

    /// True when sprites can be drawn into an LDR target and the HDR scene pass skipped.
    /// Stencil masks still need the HDR depth attachment, so callers must keep the HDR
    /// path when any sprite batch writes a mask.
    public static func spritesUseLDR(
        opaqueCount: Int, transparentCount: Int, screenSpaceAO: Bool, temporal: Bool,
        motionBlur: Bool, rayTracing: Bool, bloom: Bool, depthOfField: Bool, toneMap: Bool,
        spriteMask: Bool, debugGeometry: Bool
    ) -> Bool {
        opaqueCount == 0 && transparentCount == 0 && !screenSpaceAO && !temporal && !motionBlur
            && !rayTracing && !bloom && !depthOfField && !toneMap && !spriteMask && !debugGeometry
    }
}
