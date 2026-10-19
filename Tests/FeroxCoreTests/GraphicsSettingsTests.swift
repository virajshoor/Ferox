/// Tests for the platform-independent graphics configuration in FeroxCore: quality presets,
/// Codable round trips, and `GraphicsFeatureResolver` (fallback reporting, MSAA clamping,
/// ray-tracing gating, and clamping of out-of-range values) against `DeviceCapabilities`.
import Foundation
import XCTest

@testable import FeroxCore

final class GraphicsSettingsTests: XCTestCase {
    // The low preset trades quality for speed: FXAA, no ray tracing, and reduced texture quality.
    func testLowPresetFavoursPerformance() {
        let s = GraphicsSettings(preset: .low)
        XCTAssertEqual(s.antiAliasing.mode, .fxaa)
        XCTAssertEqual(s.upscaling.mode, .automaticSpatial)
        XCTAssertFalse(s.rayTracing.enabled)
        XCTAssertFalse(s.post.bloom.enabled)
        XCTAssertEqual(s.textureQuality, .low)
        XCTAssertEqual(s.anisotropy, 2)
    }

    // The ultra preset enables hardware-quality ray tracing, 16x anisotropy and PCSS shadows.
    func testUltraPresetEnablesHighestQualityFeatures() {
        let s = GraphicsSettings(preset: .ultra)
        XCTAssertTrue(s.rayTracing.enabled)
        XCTAssertEqual(s.rayTracing.raysPerPixel, 2)
        XCTAssertEqual(s.anisotropy, 16)
        XCTAssertEqual(s.shadows.resolution, 4096)
        XCTAssertEqual(s.shadows.softness, .pcss)
    }

    // Every preset survives a JSON encode and decode unchanged.
    func testGraphicsSettingsCodableRoundTrip() throws {
        for preset in QualityPreset.allCases {
            let original = GraphicsSettings(preset: preset)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(GraphicsSettings.self, from: data)
            XCTAssertEqual(decoded, original, "round trip failed for \(preset)")
        }
    }

    // Device capabilities survive a JSON round trip, including the sample count list.
    func testDeviceCapabilitiesCodableRoundTrip() throws {
        let caps = DeviceCapabilities.testAppleSiliconFull
        let data = try JSONEncoder().encode(caps)
        XCTAssertEqual(try JSONDecoder().decode(DeviceCapabilities.self, from: data), caps)
    }

    // A custom render scale is clamped to the [0.25, 1] range.
    func testCustomRenderScaleIsClamped() {
        var upscaling = UpscalingSettings(mode: .feroxTemporal, quality: .performance)
        upscaling.customRenderScale = 0.1
        XCTAssertEqual(upscaling.renderScale, 0.25, accuracy: 1e-6)
        upscaling.customRenderScale = 2
        XCTAssertEqual(upscaling.renderScale, 1, accuracy: 1e-6)
    }
}

final class GraphicsFeatureResolverTests: XCTestCase {
    // Default settings on the baseline device pick Ferox's temporal upscaler at quality scale with no fallbacks.
    func testDefaultSettingsOnBaselineDeviceHaveNoFallbacks() {
        let r = GraphicsFeatureResolver.resolve(GraphicsSettings(), capabilities: .baseline)
        XCTAssertEqual(r.upscaler, .feroxTemporal)
        XCTAssertTrue(r.upscaler.isTemporal)
        XCTAssertEqual(r.antiAliasing, .taa)
        XCTAssertEqual(r.renderScale, 0.67, accuracy: 1e-6)
        XCTAssertTrue(r.jitter)
        XCTAssertTrue(r.screenSpaceAO)
        XCTAssertFalse(r.usesRayTracing)
        XCTAssertTrue(r.fallbacks.isEmpty)
    }

    // An MSAA request above the supported sample counts is clamped to the highest supported count.
    func testMSAASampleCountIsClampedToSupported() {
        var s = GraphicsSettings()
        s.antiAliasing = AntiAliasingSettings(mode: .msaa, msaaSamples: 8)
        s.upscaling = UpscalingSettings(mode: .native, quality: .native)
        let caps = DeviceCapabilities(supportedSampleCounts: [1, 2, 4])
        let r = GraphicsFeatureResolver.resolve(s, capabilities: caps)
        XCTAssertEqual(r.antiAliasing, .msaa)
        XCTAssertEqual(r.msaaSamples, 4)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .msaa })
    }

    // When multisampling is unavailable, MSAA degrades to FXAA and reports both changes.
    func testMSAAUnavailableFallsBackToFXAA() {
        var s = GraphicsSettings()
        s.antiAliasing = AntiAliasingSettings(mode: .msaa, msaaSamples: 4)
        s.upscaling = UpscalingSettings(mode: .native, quality: .native)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.antiAliasing, .fxaa)
        XCTAssertEqual(r.msaaSamples, 1)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .antiAliasing })
    }

    // A temporal upscaler performs anti-aliasing itself, so an MSAA request is folded into TAA.
    func testTemporalUpscalingReplacesMSAAWithTAA() {
        var s = GraphicsSettings()
        s.antiAliasing = AntiAliasingSettings(mode: .msaa, msaaSamples: 4)
        s.upscaling = UpscalingSettings(mode: .feroxTemporal, quality: .quality)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.antiAliasing, .taa)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .antiAliasing })
    }

    // A spatial upscaler needs anti-aliased input, so disabled AA is replaced by FXAA.
    func testSpatialUpscalerEnablesFXAAWhenAANone() {
        var s = GraphicsSettings()
        s.antiAliasing = AntiAliasingSettings(mode: .none)
        s.upscaling = UpscalingSettings(mode: .feroxSpatial, quality: .quality)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.upscaler, .feroxSpatial)
        XCTAssertEqual(r.antiAliasing, .fxaa)
    }

    // Native quality with a spatial upscaler collapses to no upscaler, so the render size is the output size.
    func testNativeSpatialUpscalingIsNoUpscaler() {
        var s = GraphicsSettings()
        s.upscaling = UpscalingSettings(mode: .feroxSpatial, quality: .native)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.upscaler, .none)
        let size = r.renderSize(forOutput: 1920, 1080)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    // With an upscaler active, the internal render size is the output size scaled by the preset factor.
    func testRenderSizeUsesPresetScale() {
        var s = GraphicsSettings()
        s.upscaling = UpscalingSettings(mode: .automaticTemporal, quality: .performance)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        let size = r.renderSize(forOutput: 1920, 1080)
        XCTAssertEqual(size.width, 960)
        XCTAssertEqual(size.height, 540)
    }

    // Ray tracing is disabled on devices without support, and each dependent effect reports its fallback.
    func testRayTracingDisabledWithoutSupport() {
        var s = GraphicsSettings()
        s.rayTracing = RayTracingSettings(preset: .quality)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertFalse(r.usesRayTracing)
        XCTAssertFalse(r.settings.rayTracing.enabled)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .rayTracing })
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .rayTracedShadows })
    }

    // Without dedicated ray-tracing hardware the ray budget is reduced to one ray, one bounce and half resolution.
    func testRayBudgetReducedWithoutHardwareRayTracing() {
        var s = GraphicsSettings()
        s.rayTracing = RayTracingSettings(preset: .quality)
        let caps = DeviceCapabilities(appleFamily: 8, supportsRaytracing: true)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: caps)
        XCTAssertTrue(r.usesRayTracing)
        XCTAssertEqual(r.settings.rayTracing.raysPerPixel, 1)
        XCTAssertEqual(r.settings.rayTracing.maxBounces, 1)
        XCTAssertEqual(r.settings.rayTracing.resolutionScale, 0.5, accuracy: 1e-6)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .rayTracing })
    }

    // With hardware ray tracing the requested budget is kept, and ambient occlusion comes from ray tracing rather than SSAO.
    func testHardwareRayTracingKeepsBudget() {
        var s = GraphicsSettings()
        s.rayTracing = RayTracingSettings(preset: .quality)
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .testAppleSiliconFull)
        XCTAssertEqual(r.settings.rayTracing.raysPerPixel, 2)
        XCTAssertEqual(r.settings.rayTracing.maxBounces, 2)
        XCTAssertTrue(r.rayTracedReflections)
        XCTAssertFalse(r.screenSpaceAO)
        XCTAssertFalse(r.fallbacks.contains { $0.feature == .rayTracing })
    }

    // Shadow cascades and resolution are clamped to the supported ranges, and each change is reported.
    func testShadowSettingsAreClamped() {
        var s = GraphicsSettings()
        s.shadows.cascades = 9
        s.shadows.resolution = 100
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.settings.shadows.cascades, 4)
        XCTAssertEqual(r.settings.shadows.resolution, 256)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .shadows })
    }

    // Anisotropy that is not a supported power of two rounds down to the nearest valid level.
    func testAnisotropyRoundsDownToValidLevel() {
        var s = GraphicsSettings()
        s.anisotropy = 3
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.settings.anisotropy, 2)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .anisotropy })
    }

    // Frames in flight are limited to the range 1 to 3.
    func testFramesInFlightAreClamped() {
        var s = GraphicsSettings()
        s.frame.maxFramesInFlight = 5
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.settings.frame.maxFramesInFlight, 3)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .framePacing })
    }

    // An explicit MetalFX request on a device without MetalFX falls back to Ferox's own temporal upscaler.
    func testMetalFXRequestFallsBackWithoutSupport() {
        var s = GraphicsSettings()
        s.upscaling = UpscalingSettings(mode: .metalFXTemporal, quality: .quality)
        let baseline = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(baseline.upscaler, .feroxTemporal)
        XCTAssertTrue(baseline.fallbacks.contains { $0.feature == .upscaling })
        let full = GraphicsFeatureResolver.resolve(s, capabilities: .testAppleSiliconFull)
        XCTAssertEqual(full.upscaler, .metalFXTemporal)
    }

    // Dynamic resolution needs an upscaler, so enabling it with native rendering adds one and reports it.
    func testDynamicResolutionAddsUpscaler() {
        var s = GraphicsSettings()
        s.upscaling = UpscalingSettings(mode: .native, quality: .native)
        s.dynamicResolution.enabled = true
        let r = GraphicsFeatureResolver.resolve(s, capabilities: .baseline)
        XCTAssertEqual(r.upscaler, .feroxSpatial)
        XCTAssertTrue(r.fallbacks.contains { $0.feature == .dynamicResolution })
    }
}

final class ShadowSettingsTests: XCTestCase {
    /// Settings files written before local shadows existed decode with the default local budget.
    func testShadowSettingsDecodeWithoutLocalFields() throws {
        var settings = ShadowSettings()
        settings.resolution = 1024
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "localShadowSlices")
        json.removeValue(forKey: "localResolution")
        let decoded = try JSONDecoder().decode(ShadowSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.resolution, 1024)
        XCTAssertEqual(decoded.localShadowSlices, ShadowSettings().localShadowSlices)
        XCTAssertEqual(decoded.localResolution, ShadowSettings().localResolution)
    }

    /// Presets scale the local shadow budget: none on low, more on ultra.
    func testPresetsSetLocalShadowBudget() {
        XCTAssertEqual(GraphicsSettings(preset: .low).shadows.localShadowSlices, 0)
        XCTAssertEqual(GraphicsSettings(preset: .medium).shadows.localShadowSlices, 6)
        XCTAssertEqual(GraphicsSettings(preset: .high).shadows.localShadowSlices, 12)
        XCTAssertEqual(GraphicsSettings(preset: .ultra).shadows.localShadowSlices, 24)
        XCTAssertGreaterThan(
            GraphicsSettings(preset: .ultra).shadows.localResolution,
            GraphicsSettings(preset: .low).shadows.localResolution)
    }
}
