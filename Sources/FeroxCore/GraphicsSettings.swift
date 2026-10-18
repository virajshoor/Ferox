/// User-facing graphics configuration. These settings express *intent*; the renderer
/// resolves them against `DeviceCapabilities` with `GraphicsFeatureResolver`, which
/// produces the effective configuration plus a list of human-readable fallbacks.
///
/// Everything here is plain data (Codable, Sendable) and platform-independent so the
/// resolution rules can be unit-tested without a GPU.
public struct GraphicsSettings: Codable, Sendable, Hashable {
    public var renderPath: RenderPath = .clusteredForward
    public var antiAliasing: AntiAliasingSettings = .init()
    public var upscaling: UpscalingSettings = .init()
    public var dynamicResolution: DynamicResolutionSettings = .init()
    public var rayTracing: RayTracingSettings = .init()
    public var shadows: ShadowSettings = .init()
    public var post: PostProcessSettings = .init()
    public var frame: FramePacingSettings = .init()
    public var textureQuality: TextureQuality = .high
    /// Anisotropic filtering level (1, 2, 4, 8 or 16).
    public var anisotropy: Int = 8
    /// Enables GPU-driven culling (compute frustum + Hi-Z occlusion culling into indirect draws).
    public var gpuDrivenCulling: Bool = true
    /// Enables occlusion culling against the previous frame's hierarchical depth buffer.
    public var occlusionCulling: Bool = true
    /// Multiplier on LOD switching distances (> 1 keeps higher detail further away).
    public var lodBias: Float = 1

    public init() {}

    /// Builds settings from a quality preset.
    public init(preset: QualityPreset) {
        self.init()
        apply(preset)
    }

    public mutating func apply(_ preset: QualityPreset) {
        switch preset {
        case .low:
            antiAliasing.mode = .fxaa
            upscaling = UpscalingSettings(mode: .automaticSpatial, quality: .performance)
            shadows = ShadowSettings(enabled: true, resolution: 1024, cascades: 2, softness: .hard)
            post.bloom.enabled = false
            post.ambientOcclusion.enabled = false
            post.depthOfField.enabled = false
            post.motionBlur.enabled = false
            rayTracing = RayTracingSettings(preset: .off)
            textureQuality = .low
            anisotropy = 2
            lodBias = 0.75
        case .medium:
            antiAliasing.mode = .taa
            upscaling = UpscalingSettings(mode: .automaticTemporal, quality: .balanced)
            shadows = ShadowSettings(enabled: true, resolution: 2048, cascades: 3, softness: .pcf)
            post.bloom.enabled = true
            post.ambientOcclusion.enabled = true
            post.ambientOcclusion.quality = .low
            rayTracing = RayTracingSettings(preset: .off)
            textureQuality = .medium
            anisotropy = 4
            lodBias = 1
        case .high:
            antiAliasing.mode = .taa
            upscaling = UpscalingSettings(mode: .automaticTemporal, quality: .quality)
            shadows = ShadowSettings(enabled: true, resolution: 2048, cascades: 4, softness: .pcf)
            post.bloom.enabled = true
            post.ambientOcclusion.enabled = true
            post.ambientOcclusion.quality = .medium
            rayTracing = RayTracingSettings(preset: .performance)
            textureQuality = .high
            anisotropy = 8
            lodBias = 1.25
        case .ultra:
            antiAliasing.mode = .taa
            upscaling = UpscalingSettings(mode: .native, quality: .native)
            shadows = ShadowSettings(enabled: true, resolution: 4096, cascades: 4, softness: .pcss)
            post.bloom.enabled = true
            post.ambientOcclusion.enabled = true
            post.ambientOcclusion.quality = .high
            rayTracing = RayTracingSettings(preset: .quality)
            textureQuality = .ultra
            anisotropy = 16
            lodBias = 1.5
        }
    }
}

public enum QualityPreset: String, Codable, Sendable, CaseIterable { case low, medium, high, ultra }

/// Rendering architecture for 3D scenes. See Docs/08-Rendering-3D.md for the trade-offs.
public enum RenderPath: String, Codable, Sendable, CaseIterable {
    /// Forward+ with a view-space cluster grid for light culling. Supports MSAA, transparency
    /// and arbitrary materials; the default.
    case clusteredForward
    /// Plain forward shading iterating all lights per pixel. Lowest overhead for scenes
    /// with only a handful of lights.
    case forward
}

// MARK: Anti-aliasing

public enum AntiAliasingMode: String, Codable, Sendable, CaseIterable {
    case none
    /// Hardware multisampling of the main colour pass.
    case msaa
    /// Fast approximate AA (post-process, luma edge detection), Ferox implementation.
    case fxaa
    /// Subpixel morphological AA (edge detection + blend weights + neighbourhood blending),
    /// Ferox's simplified single-pass-per-stage implementation (no area/search textures).
    case smaa
    /// Temporal AA: jittered projection, motion vectors, history reprojection with
    /// neighbourhood clamping. Ferox implementation.
    case taa
}

public struct AntiAliasingSettings: Codable, Sendable, Hashable {
    public var mode: AntiAliasingMode = .taa
    /// MSAA sample count (2, 4 or 8) when `mode == .msaa`.
    public var msaaSamples: Int = 4
    /// TAA history blend weight for the current frame (lower = smoother, more ghosting).
    public var taaFeedback: Float = 0.1
    /// Number of jitter positions in the Halton sequence cycle.
    public var taaJitterPhases: Int = 8
    /// Post-AA sharpening strength in [0, 1] (contrast-adaptive).
    public var sharpness: Float = 0.25
    public init(mode: AntiAliasingMode = .taa, msaaSamples: Int = 4) {
        self.mode = mode
        self.msaaSamples = msaaSamples
    }
}

// MARK: Upscaling

public enum UpscalingMode: String, Codable, Sendable, CaseIterable {
    /// Render at output resolution.
    case native
    /// Ferox spatial upscaler: edge-aware Lanczos-style filter with sharpening.
    case feroxSpatial
    /// Ferox temporal upscaler (TAAU): TAA resolve into an output-resolution history.
    case feroxTemporal
    /// Apple MetalFX spatial scaler (`MTLFXSpatialScaler`, macOS 13+).
    case metalFXSpatial
    /// Apple MetalFX temporal scaler (`MTLFXTemporalScaler`, macOS 13+).
    case metalFXTemporal
    /// Best available spatial technique (MetalFX if supported, otherwise Ferox).
    case automaticSpatial
    /// Best available temporal technique (MetalFX if supported, otherwise Ferox).
    case automaticTemporal

    public var isTemporal: Bool { self == .feroxTemporal || self == .metalFXTemporal || self == .automaticTemporal }
    public var isMetalFX: Bool { self == .metalFXSpatial || self == .metalFXTemporal }
}

/// Render-resolution presets. Scale factors are per axis.
public enum UpscalingQuality: String, Codable, Sendable, CaseIterable {
    case performance, balanced, quality, native

    public var renderScale: Float {
        switch self {
        case .performance: return 0.5
        case .balanced: return 0.58
        case .quality: return 0.67
        case .native: return 1
        }
    }
}

public struct UpscalingSettings: Codable, Sendable, Hashable {
    public var mode: UpscalingMode = .automaticTemporal
    public var quality: UpscalingQuality = .quality
    /// Overrides the preset's scale when set (clamped to [0.25, 1]).
    public var customRenderScale: Float?
    public init(mode: UpscalingMode = .automaticTemporal, quality: UpscalingQuality = .quality) {
        self.mode = mode
        self.quality = quality
    }
    public var renderScale: Float { min(max(customRenderScale ?? quality.renderScale, 0.25), 1) }
}

public struct DynamicResolutionSettings: Codable, Sendable, Hashable {
    public var enabled: Bool = false
    public var minScale: Float = 0.5
    public var maxScale: Float = 1
    /// GPU frame time to target, in milliseconds. `nil` derives it from the target frame rate
    /// with 10 % headroom.
    public var targetGPUMilliseconds: Double?
    public init() {}
}

// MARK: Ray tracing

public enum RayTracingPreset: String, Codable, Sendable, CaseIterable { case off, performance, balanced, quality }

public struct RayTracingSettings: Codable, Sendable, Hashable {
    public var enabled: Bool = false
    public var shadows: Bool = true
    public var reflections: Bool = true
    public var ambientOcclusion: Bool = true
    /// Rays per pixel for each effect.
    public var raysPerPixel: Int = 1
    /// Maximum reflection bounces (1 = mirror-like single bounce).
    public var maxBounces: Int = 1
    /// Ray-tracing resolution relative to the internal render resolution.
    public var resolutionScale: Float = 0.5
    /// Spatio-temporal denoiser (Ferox's à-trous + temporal accumulation).
    public var denoise: Bool = true
    /// Maximum ray distance for AO in world units.
    public var aoRadius: Float = 1.5
    /// Surfaces rougher than this use the prefiltered environment instead of traced reflections.
    public var maxReflectionRoughness: Float = 0.6

    public init() {}
    public init(preset: RayTracingPreset) {
        switch preset {
        case .off:
            enabled = false
        case .performance:
            enabled = true; reflections = false; raysPerPixel = 1; maxBounces = 1; resolutionScale = 0.5
        case .balanced:
            enabled = true; raysPerPixel = 1; maxBounces = 1; resolutionScale = 0.5
        case .quality:
            enabled = true; raysPerPixel = 2; maxBounces = 2; resolutionScale = 1
        }
    }
}

// MARK: Shadows and post

public enum ShadowSoftness: String, Codable, Sendable, CaseIterable { case hard, pcf, pcss }

public struct ShadowSettings: Codable, Sendable, Hashable {
    public var enabled = true
    public var resolution = 2048
    public var cascades = 4
    public var softness: ShadowSoftness = .pcf
    public var maxDistance: Float = 120
    public var depthBias: Float = 0.0015
    public var normalBias: Float = 0.02
    public init(enabled: Bool = true, resolution: Int = 2048, cascades: Int = 4, softness: ShadowSoftness = .pcf) {
        self.enabled = enabled
        self.resolution = resolution
        self.cascades = cascades
        self.softness = softness
    }
}

public enum ToneMapper: String, Codable, Sendable, CaseIterable { case none, reinhard, aces, agx }

public struct PostProcessSettings: Codable, Sendable, Hashable {
    public struct Bloom: Codable, Sendable, Hashable {
        public var enabled = true
        public var threshold: Float = 1.0
        public var intensity: Float = 0.6
        public var radius: Float = 1.0
        public init() {}
    }
    public struct AmbientOcclusion: Codable, Sendable, Hashable {
        public enum Quality: String, Codable, Sendable, CaseIterable { case low, medium, high }
        public var enabled = true
        public var quality: Quality = .medium
        public var radius: Float = 0.6
        public var intensity: Float = 1.0
        public init() {}
        public var sampleCount: Int {
            switch quality {
            case .low: return 8
            case .medium: return 16
            case .high: return 32
            }
        }
    }
    public struct DepthOfField: Codable, Sendable, Hashable {
        public var enabled = false
        public var focusDistance: Float = 10
        public var aperture: Float = 2.8
        public var maxBlurRadius: Float = 8
        public init() {}
    }
    public struct MotionBlur: Codable, Sendable, Hashable {
        public var enabled = false
        /// Fraction of the frame interval the virtual shutter is open.
        public var shutter: Float = 0.5
        public var samples = 8
        public init() {}
    }
    public struct ColorGrading: Codable, Sendable, Hashable {
        public var exposure: Float = 0
        public var contrast: Float = 1
        public var saturation: Float = 1
        public var temperature: Float = 0
        public var tint: Float = 0
        public var lift = Vec3Codable(0, 0, 0)
        public var gamma = Vec3Codable(1, 1, 1)
        public var gain = Vec3Codable(1, 1, 1)
        public var vignette: Float = 0.15
        public init() {}
    }

    public var toneMapper: ToneMapper = .agx
    public var autoExposure = false
    public var bloom = Bloom()
    public var ambientOcclusion = AmbientOcclusion()
    public var depthOfField = DepthOfField()
    public var motionBlur = MotionBlur()
    public var colorGrading = ColorGrading()
    public init() {}
}

/// Small Codable triple so FeroxCore settings don't depend on SIMD Codable layout details.
public struct Vec3Codable: Codable, Sendable, Hashable {
    public var x: Float, y: Float, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
}

public struct FramePacingSettings: Codable, Sendable, Hashable {
    /// Target frames per second. `nil` uses the display's maximum refresh rate.
    public var targetFPS: Int?
    /// Synchronise presentation with the display (recommended; avoids tearing).
    public var vsync = true
    /// Number of frames the CPU may run ahead of the GPU (1–3). Lower reduces latency;
    /// higher absorbs CPU spikes. Ferox defaults to 3 (triple buffering).
    public var maxFramesInFlight = 3
    /// Fixed simulation frequency in Hz.
    public var fixedUpdateHz: Double = 60
    public init() {}
}

public enum TextureQuality: String, Codable, Sendable, CaseIterable {
    case low, medium, high, ultra
    /// Number of top mip levels skipped when uploading textures.
    public var mipBias: Int {
        switch self {
        case .low: return 2
        case .medium: return 1
        case .high, .ultra: return 0
        }
    }
}
