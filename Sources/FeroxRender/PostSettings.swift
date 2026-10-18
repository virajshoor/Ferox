import FeroxCore
import FeroxScene
import Foundation

/// Full-screen debug visualisations (`Renderer.debugView`). Raw values match the
/// `misc.w` modes of `debugViewFragment` in Post.metal.
public enum RenderDebugView: Int, CaseIterable, Sendable {
    /// Normal output (no debug view).
    case none = -1
    /// Scene colour before tone mapping, clamped.
    case hdrColor = 0
    /// Linearised reverse-Z depth.
    case depth = 1
    /// World-space normals.
    case normals = 2
    /// Screen-space motion vectors (×20).
    case motion = 3
    /// Ambient occlusion (SSAO or ray traced).
    case ambientOcclusion = 4
}

/// Translates `PostProcessSettings` into the `PostUniforms` fields that stay constant for
/// a frame. Per-pass fields (`sizes`, `texel`, `misc.w`) are filled by the post processor.
/// Plain Swift so the mapping is unit-tested on every platform.
public enum PostUniformsBuilder {
    /// 35 mm full-frame sensor height, used to derive a physical focal length from the
    /// camera's vertical field of view for depth of field.
    public static let sensorHeight: Float = 0.024

    /// Focal length in metres for a vertical field of view (radians).
    public static func focalLength(fovY: Float) -> Float {
        sensorHeight / (2 * tan(min(max(fovY, 0.01), 3.1) * 0.5))
    }

    /// Number of bloom mips for a source size: halve until the smaller side drops below
    /// 8 pixels, at most 7 levels (the radius of the blur grows with each level).
    public static func bloomMipCount(width: Int, height: Int) -> Int {
        var s = min(width, height) / 2
        var n = 0
        while s >= 8 && n < 7 {
            n += 1
            s /= 2
        }
        return max(n, 1)
    }

    /// `ToneMapper` → operator index in `tonemapFragment`.
    public static func operatorIndex(_ t: ToneMapper) -> Float {
        switch t {
        case .none: return 0
        case .reinhard: return 1
        case .aces: return 2
        case .agx: return 3
        }
    }

    public static func make(_ s: PostProcessSettings, antiAliasing: AntiAliasingSettings, camera: Camera?,
                            frameIndex: UInt64, deltaTime: Float) -> PostUniforms {
        var p = PostUniforms()
        let g = s.colorGrading
        // Bloom knee at half the threshold gives a soft transition into the glow.
        p.bloom = Vec4(max(s.bloom.threshold, 0), max(s.bloom.threshold, 0) * 0.5,
                       s.bloom.enabled ? max(s.bloom.intensity, 0) : 0, max(s.bloom.radius, 0.1))
        p.tonemap = Vec4(operatorIndex(s.toneMapper), pow(2, g.exposure), max(g.contrast, 0), max(g.saturation, 0))
        p.whiteBalance = Vec4(RenderMath.whiteBalanceLMS(temperature: g.temperature, tint: g.tint),
                              min(max(g.vignette, 0), 1))
        p.lift = Vec4(g.lift.x, g.lift.y, g.lift.z, s.autoExposure ? 1 : 0)
        p.gamma = Vec4(g.gamma.x, g.gamma.y, g.gamma.z, 1)
        p.gain = Vec4(g.gain.x, g.gain.y, g.gain.z, 0)
        let fov = camera?.fieldOfView ?? (60 * .pi / 180)
        let dof = s.depthOfField
        p.dof = Vec4(max(dof.focusDistance, 0.01), max(dof.aperture, 0.1), focalLength(fovY: fov),
                     min(max(dof.maxBlurRadius, 0), 32))
        let mb = s.motionBlur
        p.motionBlur = Vec4(min(max(mb.shutter, 0), 1), Float(min(max(mb.samples, 2), 32)), 32, 0)
        p.taa = Vec4(min(max(antiAliasing.taaFeedback, 0.02), 1), 0, min(max(antiAliasing.sharpness, 0), 1), 0)
        p.sharpen = Vec4(min(max(antiAliasing.sharpness, 0), 1), 0, 0, 0)
        let ao = s.ambientOcclusion
        p.ssao = Vec4(max(ao.radius, 0.01), max(ao.intensity, 0), 0.025, Float(ao.sampleCount))
        p.misc = Vec4(Float(frameIndex % 1024), max(deltaTime, 0), 1.5, 0)
        return p
    }
}

/// Picks the render scale for dynamic resolution from measured GPU frame times.
///
/// The controller moves in quantised steps (so render targets are reallocated rarely),
/// lowers the scale quickly when frames are over budget and raises it slowly when there
/// is comfortable headroom, with a cool-down between changes to avoid oscillation.
public struct DynamicResolutionController: Sendable {
    public var settings: DynamicResolutionSettings
    /// Scale granularity.
    public var step: Float = 0.05
    /// Frames to wait after a change before the next one.
    public var cooldownFrames = 30
    public private(set) var scale: Float
    private var cooldown = 0
    private var smoothedMs: Double?

    public init(settings: DynamicResolutionSettings, initialScale: Float = 1) {
        self.settings = settings
        scale = min(max(initialScale, settings.minScale), settings.maxScale)
    }

    /// Feeds one GPU frame time and returns the (possibly changed) scale.
    /// `budgetMs` is used when `settings.targetGPUMilliseconds` is nil (derived from the
    /// display refresh rate or target FPS by the caller).
    @discardableResult
    public mutating func update(gpuMilliseconds ms: Double, budgetMs: Double) -> Float {
        guard settings.enabled, ms.isFinite, ms > 0 else { return scale }
        let target = settings.targetGPUMilliseconds ?? budgetMs
        smoothedMs = smoothedMs.map { $0 * 0.9 + ms * 0.1 } ?? ms
        if cooldown > 0 {
            cooldown -= 1
            return scale
        }
        let lo = min(settings.minScale, settings.maxScale), hi = max(settings.minScale, settings.maxScale)
        var next = scale
        if let t = smoothedMs, t > target * 1.05 {
            // GPU cost scales roughly with pixel count (scale²): jump towards the estimate.
            let ideal = scale * Float((target / t).squareRoot())
            next = max(lo, min(scale - step, (ideal / step).rounded(.down) * step))
        } else if let t = smoothedMs, t < target * 0.8 {
            next = min(hi, scale + step)
        }
        next = min(max(next, lo), hi)
        if abs(next - scale) > 1e-4 {
            scale = next
            cooldown = cooldownFrames
        }
        return scale
    }
}
