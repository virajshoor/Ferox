#if canImport(Metal)
import FeroxCore
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

/// Errors raised while creating GPU objects.
public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case commandQueue
    case shaderSourceMissing(String)
    case shaderCompilation(file: String, message: String)
    case functionMissing(String)
    case pipeline(name: String, message: String)
    case allocation(String)

    public var description: String {
        switch self {
        case .noDevice: return "No Metal device is available"
        case .commandQueue: return "Could not create a Metal command queue"
        case .shaderSourceMissing(let f): return "Shader source not found: \(f)"
        case .shaderCompilation(let f, let m): return "Shader compilation failed in \(f): \(m)"
        case .functionMissing(let n): return "Shader function not found: \(n)"
        case .pipeline(let n, let m): return "Pipeline '\(n)' could not be created: \(m)"
        case .allocation(let what): return "GPU allocation failed: \(what)"
        }
    }
}

/// Fills `DeviceCapabilities` from runtime `MTLDevice` queries. Nothing is assumed from
/// the device name; every optional feature is queried.
public enum CapabilityProbe {
    public static func probe(_ device: any MTLDevice) -> DeviceCapabilities {
        var family = 0
        let families: [(MTLGPUFamily, Int)] = [(.apple9, 9), (.apple8, 8), (.apple7, 7), (.apple6, 6), (.apple5, 5)]
        for (f, n) in families where device.supportsFamily(f) {
            family = n
            break
        }
        let mac2 = device.supportsFamily(.mac2)
        let counts = [1, 2, 4, 8].filter { device.supportsTextureSampleCount($0) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var spatial = false, temporal = false
        #if canImport(MetalFX)
        spatial = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        temporal = MTLFXTemporalScalerDescriptor.supportsDevice(device)
        #endif
        return DeviceCapabilities(
            deviceName: device.name,
            appleFamily: family,
            supportsMac2Family: mac2,
            supportsMetal3: device.supportsFamily(.metal3),
            hasUnifiedMemory: device.hasUnifiedMemory,
            isAppleSilicon: family >= 7,
            isLowPower: device.isLowPower,
            isHeadless: device.isHeadless,
            recommendedMaxWorkingSetSize: device.recommendedMaxWorkingSetSize,
            maxThreadgroupMemoryLength: device.maxThreadgroupMemoryLength,
            maxBufferLength: UInt64(device.maxBufferLength),
            supportedSampleCounts: counts.isEmpty ? [1] : counts,
            supportsRaytracing: device.supportsRaytracing,
            supportsRaytracingFromRender: device.supportsRaytracingFromRender,
            supportsMetalFXSpatial: spatial,
            supportsMetalFXTemporal: temporal,
            supportsStageBoundaryCounters: device.supportsCounterSampling(.atStageBoundary),
            supportsMeshShaders: family >= 7 || mac2,
            argumentBuffersTier: device.argumentBuffersSupport == .tier2 ? 2 : 1,
            supportsBCTextureCompression: device.supportsBCTextureCompression,
            supportsDepthResolveMinMax: family >= 5 || mac2,
            supports32BitFloatFiltering: device.supports32BitFloatFiltering,
            osMajor: os.majorVersion,
            osMinor: os.minorVersion)
    }
}

/// The Metal device, its command queue and probed capabilities.
public final class RenderDevice {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    public let capabilities: DeviceCapabilities

    public init(device: (any MTLDevice)? = nil) throws {
        guard let d = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        guard let q = d.makeCommandQueue() else { throw RenderError.commandQueue }
        q.label = "Ferox.MainQueue"
        self.device = d
        queue = q
        capabilities = CapabilityProbe.probe(d)
        Log.info("Render", "Metal device: \(d.name) (apple family \(capabilities.appleFamily), mac2 \(capabilities.supportsMac2Family), ray tracing \(capabilities.supportsRaytracing))")
    }
}
#endif
