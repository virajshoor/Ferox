/// GPU and OS capabilities relevant to Ferox's feature selection.
///
/// On macOS the renderer populates this from `MTLDevice` queries (`supportsFamily`,
/// `supportsRaytracing`, `MTLFXTemporalScalerDescriptor.supportsDevice`, …) at start-up;
/// see `FeroxRender.CapabilityProbe`. Nothing in Ferox assumes a particular M-series chip:
/// every optional feature is gated on a field here.
public struct DeviceCapabilities: Codable, Sendable, Hashable {
    public var deviceName: String
    /// Highest supported `MTLGPUFamily.appleN` (7 = M1/A14, 8 = M2/A15–A16, 9 = M3/M4/A17+), or 0.
    public var appleFamily: Int
    /// `MTLGPUFamily.mac2` support (all Apple Silicon and recent AMD/Intel Macs).
    public var supportsMac2Family: Bool
    /// `MTLGPUFamily.metal3`.
    public var supportsMetal3: Bool
    public var hasUnifiedMemory: Bool
    public var isAppleSilicon: Bool
    public var isLowPower: Bool
    public var isHeadless: Bool
    public var recommendedMaxWorkingSetSize: UInt64
    public var maxThreadgroupMemoryLength: Int
    public var maxBufferLength: UInt64
    /// MSAA sample counts accepted by `supportsTextureSampleCount`.
    public var supportedSampleCounts: [Int]
    public var supportsRaytracing: Bool
    /// Ray queries callable from render (fragment) functions.
    public var supportsRaytracingFromRender: Bool
    /// `MTLFXSpatialScalerDescriptor.supportsDevice(_:)`.
    public var supportsMetalFXSpatial: Bool
    /// `MTLFXTemporalScalerDescriptor.supportsDevice(_:)`.
    public var supportsMetalFXTemporal: Bool
    /// Counter sampling at render/compute stage boundaries (GPU pass timestamps).
    public var supportsStageBoundaryCounters: Bool
    public var supportsMeshShaders: Bool
    public var argumentBuffersTier: Int
    public var supportsBCTextureCompression: Bool
    public var supportsDepthResolveMinMax: Bool
    public var supports32BitFloatFiltering: Bool
    /// Operating system version (major, minor).
    public var osMajor: Int
    public var osMinor: Int

    public init(
        deviceName: String = "Unknown", appleFamily: Int = 0, supportsMac2Family: Bool = false,
        supportsMetal3: Bool = false, hasUnifiedMemory: Bool = false, isAppleSilicon: Bool = false,
        isLowPower: Bool = false, isHeadless: Bool = false, recommendedMaxWorkingSetSize: UInt64 = 0,
        maxThreadgroupMemoryLength: Int = 16384, maxBufferLength: UInt64 = 256 << 20,
        supportedSampleCounts: [Int] = [1], supportsRaytracing: Bool = false,
        supportsRaytracingFromRender: Bool = false, supportsMetalFXSpatial: Bool = false,
        supportsMetalFXTemporal: Bool = false, supportsStageBoundaryCounters: Bool = false,
        supportsMeshShaders: Bool = false, argumentBuffersTier: Int = 1, supportsBCTextureCompression: Bool = false,
        supportsDepthResolveMinMax: Bool = false, supports32BitFloatFiltering: Bool = false, osMajor: Int = 14,
        osMinor: Int = 0
    ) {
        self.deviceName = deviceName
        self.appleFamily = appleFamily
        self.supportsMac2Family = supportsMac2Family
        self.supportsMetal3 = supportsMetal3
        self.hasUnifiedMemory = hasUnifiedMemory
        self.isAppleSilicon = isAppleSilicon
        self.isLowPower = isLowPower
        self.isHeadless = isHeadless
        self.recommendedMaxWorkingSetSize = recommendedMaxWorkingSetSize
        self.maxThreadgroupMemoryLength = maxThreadgroupMemoryLength
        self.maxBufferLength = maxBufferLength
        self.supportedSampleCounts = supportedSampleCounts
        self.supportsRaytracing = supportsRaytracing
        self.supportsRaytracingFromRender = supportsRaytracingFromRender
        self.supportsMetalFXSpatial = supportsMetalFXSpatial
        self.supportsMetalFXTemporal = supportsMetalFXTemporal
        self.supportsStageBoundaryCounters = supportsStageBoundaryCounters
        self.supportsMeshShaders = supportsMeshShaders
        self.argumentBuffersTier = argumentBuffersTier
        self.supportsBCTextureCompression = supportsBCTextureCompression
        self.supportsDepthResolveMinMax = supportsDepthResolveMinMax
        self.supports32BitFloatFiltering = supports32BitFloatFiltering
        self.osMajor = osMajor
        self.osMinor = osMinor
    }

    /// A minimal device with no optional features (used for tests and as a safe fallback).
    public static let baseline = DeviceCapabilities()

    /// A representative fully featured Apple Silicon profile, for tests only. Real values
    /// always come from runtime probing.
    public static let testAppleSiliconFull = DeviceCapabilities(
        deviceName: "Test Apple GPU", appleFamily: 9, supportsMac2Family: true, supportsMetal3: true,
        hasUnifiedMemory: true, isAppleSilicon: true, recommendedMaxWorkingSetSize: 16 << 30,
        maxThreadgroupMemoryLength: 32768, maxBufferLength: 8 << 30, supportedSampleCounts: [1, 2, 4, 8],
        supportsRaytracing: true, supportsRaytracingFromRender: true, supportsMetalFXSpatial: true,
        supportsMetalFXTemporal: true, supportsStageBoundaryCounters: true, supportsMeshShaders: true,
        argumentBuffersTier: 2, supportsBCTextureCompression: true, supportsDepthResolveMinMax: true,
        supports32BitFloatFiltering: true, osMajor: 15, osMinor: 0)

    /// Ray tracing on Apple family 9 (M3 and later) runs on dedicated hardware; earlier
    /// families execute Metal's intersection API on the shader cores. Both are correct,
    /// the latter is markedly slower, so presets are scaled down accordingly.
    public var hasHardwareRayTracing: Bool { supportsRaytracing && appleFamily >= 9 }
}

/// A feature that was requested but changed during resolution, with a reason.
public struct GraphicsFallback: Sendable, Hashable, CustomStringConvertible {
    public enum Feature: String, Sendable, Hashable {
        case msaa, antiAliasing, upscaling, rayTracing, rayTracedShadows, rayTracedReflections, rayTracedAO,
            shadows, gpuCulling, dynamicResolution, anisotropy, framePacing
    }
    public var feature: Feature
    public var requested: String
    public var effective: String
    public var reason: String
    public var description: String { "\(feature.rawValue): \(requested) → \(effective) (\(reason))" }
}

/// Concrete upscaler chosen after resolution.
public enum ResolvedUpscaler: String, Sendable, Hashable, Codable {
    case none, feroxSpatial, feroxTemporal, metalFXSpatial, metalFXTemporal
    public var isTemporal: Bool { self == .feroxTemporal || self == .metalFXTemporal }
}

/// Fully resolved, device-valid configuration consumed by the renderer.
public struct ResolvedGraphics: Sendable, Hashable {
    public var settings: GraphicsSettings
    public var antiAliasing: AntiAliasingMode
    public var msaaSamples: Int
    public var upscaler: ResolvedUpscaler
    public var renderScale: Float
    /// Whether the projection must be jittered (TAA or a temporal upscaler).
    public var jitter: Bool { antiAliasing == .taa || upscaler.isTemporal }
    /// Whether motion vectors must be produced.
    public var needsMotionVectors: Bool { jitter || settings.post.motionBlur.enabled }
    public var rayTracedShadows: Bool
    public var rayTracedReflections: Bool
    public var rayTracedAO: Bool
    public var screenSpaceAO: Bool
    public var fallbacks: [GraphicsFallback]

    public var usesRayTracing: Bool { rayTracedShadows || rayTracedReflections || rayTracedAO }

    /// Internal render size for a given output (drawable) size.
    public func renderSize(forOutput w: Int, _ h: Int) -> (width: Int, height: Int) {
        let s = upscaler == .none ? 1 : renderScale
        return (max(1, Int((Float(w) * s).rounded())), max(1, Int((Float(h) * s).rounded())))
    }
}

/// Resolves `GraphicsSettings` against `DeviceCapabilities`.
///
/// Rules (documented in Docs/10-Post-Processing-and-Anti-Aliasing.md and Docs/12-Upscaling-and-Dynamic-Resolution.md):
/// 1. MSAA sample counts are clamped to the highest supported count ≤ the request.
/// 2. A temporal upscaler performs anti-aliasing itself, so TAA is folded into it and
///    MSAA is disabled (multisampled input is not accepted by temporal reconstruction).
/// 3. `automatic*` upscaling prefers MetalFX when the device supports it, else Ferox's own.
///    An explicit MetalFX request on an unsupported device falls back to Ferox's equivalent.
/// 4. A spatial upscaler expects anti-aliased input; if AA is `none`, FXAA is enabled.
/// 5. Native upscaling quality (scale 1) with a spatial upscaler collapses to no upscaler;
///    with a temporal upscaler it becomes native-resolution TAA ("DLAA-style").
/// 6. Ray-traced effects require `supportsRaytracing`; otherwise shadows fall back to
///    shadow maps, AO to SSAO, and reflections to probes/IBL. On non-hardware RT devices the
///    ray budget is reduced (rays per pixel = 1, resolution ≤ 0.5, bounces = 1).
public enum GraphicsFeatureResolver {
    public static func resolve(_ requested: GraphicsSettings, capabilities caps: DeviceCapabilities) -> ResolvedGraphics {
        var s = requested
        var fallbacks: [GraphicsFallback] = []
        func note(_ f: GraphicsFallback.Feature, _ req: String, _ eff: String, _ why: String) {
            fallbacks.append(GraphicsFallback(feature: f, requested: req, effective: eff, reason: why))
        }

        // --- Upscaler selection
        var upscaler: ResolvedUpscaler
        switch s.upscaling.mode {
        case .native: upscaler = .none
        case .feroxSpatial: upscaler = .feroxSpatial
        case .feroxTemporal: upscaler = .feroxTemporal
        case .metalFXSpatial:
            upscaler = caps.supportsMetalFXSpatial ? .metalFXSpatial : .feroxSpatial
            if !caps.supportsMetalFXSpatial {
                note(.upscaling, "metalFXSpatial", "feroxSpatial", "MetalFX spatial scaler not supported on this device")
            }
        case .metalFXTemporal:
            upscaler = caps.supportsMetalFXTemporal ? .metalFXTemporal : .feroxTemporal
            if !caps.supportsMetalFXTemporal {
                note(.upscaling, "metalFXTemporal", "feroxTemporal", "MetalFX temporal scaler not supported on this device")
            }
        case .automaticSpatial: upscaler = caps.supportsMetalFXSpatial ? .metalFXSpatial : .feroxSpatial
        case .automaticTemporal: upscaler = caps.supportsMetalFXTemporal ? .metalFXTemporal : .feroxTemporal
        }
        var scale = s.upscaling.renderScale
        if scale >= 0.999 {
            if upscaler == .feroxSpatial || upscaler == .metalFXSpatial {
                upscaler = .none
            }
            scale = 1
        }
        // MetalFX temporal has a device-specific minimum input scale (typically 0.5 per axis).
        if upscaler == .metalFXTemporal && scale < 0.5 {
            note(.upscaling, "scale \(scale)", "scale 0.5", "MetalFX temporal scaler minimum input scale")
            scale = 0.5
        }

        // --- Anti-aliasing
        var aa = s.antiAliasing.mode
        var samples = 1
        if upscaler.isTemporal {
            if aa != .taa && aa != .none {
                note(.antiAliasing, aa.rawValue, "temporal upscaler", "temporal upscaling performs anti-aliasing")
            }
            aa = .taa
        }
        if aa == .msaa {
            let req = max(1, s.antiAliasing.msaaSamples)
            let best = caps.supportedSampleCounts.filter { $0 <= req }.max() ?? 1
            if best != req { note(.msaa, "\(req)x", "\(best)x", "sample count not supported") }
            samples = best
            if best <= 1 {
                aa = .fxaa
                note(.antiAliasing, "msaa", "fxaa", "multisampling unavailable")
            }
        }
        if aa == .none && (upscaler == .feroxSpatial || upscaler == .metalFXSpatial) {
            aa = .fxaa
            note(.antiAliasing, "none", "fxaa", "spatial upscalers require anti-aliased input")
        }

        // --- Ray tracing
        var rtShadows = false, rtReflections = false, rtAO = false
        if s.rayTracing.enabled {
            if caps.supportsRaytracing {
                rtShadows = s.rayTracing.shadows
                rtReflections = s.rayTracing.reflections
                rtAO = s.rayTracing.ambientOcclusion
                if !caps.hasHardwareRayTracing {
                    if s.rayTracing.raysPerPixel > 1 || s.rayTracing.resolutionScale > 0.5 || s.rayTracing.maxBounces > 1 {
                        note(.rayTracing, "rpp \(s.rayTracing.raysPerPixel), scale \(s.rayTracing.resolutionScale)",
                             "rpp 1, scale 0.5, 1 bounce", "no dedicated ray-tracing hardware; budget reduced")
                    }
                    s.rayTracing.raysPerPixel = 1
                    s.rayTracing.resolutionScale = min(s.rayTracing.resolutionScale, 0.5)
                    s.rayTracing.maxBounces = 1
                }
            } else {
                note(.rayTracing, "enabled", "disabled", "Metal ray tracing is not supported on this device")
                if s.rayTracing.shadows { note(.rayTracedShadows, "ray traced", "shadow maps", "fallback") }
                if s.rayTracing.reflections { note(.rayTracedReflections, "ray traced", "reflection probes + IBL", "fallback") }
                if s.rayTracing.ambientOcclusion { note(.rayTracedAO, "ray traced", "SSAO", "fallback") }
                s.rayTracing.enabled = false
            }
        }
        s.rayTracing.raysPerPixel = min(max(s.rayTracing.raysPerPixel, 1), 8)
        s.rayTracing.maxBounces = min(max(s.rayTracing.maxBounces, 1), 4)
        s.rayTracing.resolutionScale = min(max(s.rayTracing.resolutionScale, 0.25), 1)
        let ssao = s.post.ambientOcclusion.enabled && !rtAO

        // --- Shadows
        if s.shadows.enabled {
            let clamped = min(max(s.shadows.cascades, 1), 4)
            if clamped != s.shadows.cascades { note(.shadows, "\(s.shadows.cascades) cascades", "\(clamped)", "range 1–4") }
            s.shadows.cascades = clamped
            let res = min(max(s.shadows.resolution, 256), 8192)
            if res != s.shadows.resolution { note(.shadows, "\(s.shadows.resolution)px", "\(res)px", "range 256–8192") }
            s.shadows.resolution = res
        }

        // --- Misc
        let validAniso = [1, 2, 4, 8, 16]
        if !validAniso.contains(s.anisotropy) {
            let a = validAniso.filter { $0 <= s.anisotropy }.max() ?? 1
            note(.anisotropy, "\(s.anisotropy)", "\(a)", "must be a power of two ≤ 16")
            s.anisotropy = a
        }
        let mfi = min(max(s.frame.maxFramesInFlight, 1), 3)
        if mfi != s.frame.maxFramesInFlight { note(.framePacing, "\(s.frame.maxFramesInFlight) frames in flight", "\(mfi)", "range 1–3") }
        s.frame.maxFramesInFlight = mfi
        if s.dynamicResolution.enabled {
            s.dynamicResolution.minScale = min(max(s.dynamicResolution.minScale, 0.25), 1)
            s.dynamicResolution.maxScale = min(max(s.dynamicResolution.maxScale, s.dynamicResolution.minScale), 1)
            if upscaler == .none {
                // Dynamic resolution needs an upscaler to reconstruct the output.
                upscaler = caps.supportsMetalFXSpatial ? .metalFXSpatial : .feroxSpatial
                note(.dynamicResolution, "no upscaler", upscaler.rawValue, "dynamic resolution requires an upscaler")
            }
        }

        return ResolvedGraphics(
            settings: s, antiAliasing: aa, msaaSamples: aa == .msaa ? samples : 1, upscaler: upscaler,
            renderScale: scale, rayTracedShadows: rtShadows, rayTracedReflections: rtReflections, rayTracedAO: rtAO,
            screenSpaceAO: ssao, fallbacks: fallbacks)
    }
}
