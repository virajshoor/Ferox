import Ferox
import Foundation

/// `FeroxDiag` — prints what Ferox detects on this machine and how each quality preset
/// resolves against it, so a bug report can include the exact configuration.
///
/// ```
/// swift run FeroxDiag            # human-readable report
/// swift run FeroxDiag --json     # machine-readable (attach to issues)
/// swift run FeroxDiag --render   # also renders one offscreen frame as a smoke test (macOS)
/// ```
///
/// Nothing is sent anywhere: the report is written to standard output only.
@main
enum FeroxDiag {
    struct PresetReport: Codable {
        var preset: String
        var antiAliasing: String
        var msaaSamples: Int
        var upscaler: String
        var renderScale: Float
        var renderSizeFor1440p: String
        var rayTracing: [String]
        var fallbacks: [String]
    }

    struct Report: Codable {
        var ferox: String
        var os: String
        var processors: Int
        var memoryGB: Double
        var metalAvailable: Bool
        var capabilities: DeviceCapabilities?
        var presets: [PresetReport]
        var offscreenRender: String?
    }

    static func main() {
        let args = Set(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print("usage: FeroxDiag [--json] [--render]")
            return
        }
        var report = Report(
            ferox: FeroxVersion.string,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            processors: ProcessInfo.processInfo.activeProcessorCount,
            memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            metalAvailable: false, capabilities: nil, presets: [], offscreenRender: nil)

        #if canImport(Metal)
        if let device = try? RenderDevice() {
            report.metalAvailable = true
            report.capabilities = device.capabilities
            if args.contains("--render") { report.offscreenRender = renderSmokeTest(device) }
        }
        #endif

        // Without Metal, presets are resolved against the conservative baseline.
        let caps = report.capabilities ?? .baseline
        for preset in QualityPreset.allCases {
            var settings = GraphicsSettings(preset: preset)
            if preset == .ultra { settings.rayTracing = RayTracingSettings(preset: .balanced) }
            let r = GraphicsFeatureResolver.resolve(settings, capabilities: caps)
            let size = r.renderSize(forOutput: 2560, 1440)
            var rt: [String] = []
            if r.rayTracedShadows { rt.append("shadows") }
            if r.rayTracedReflections { rt.append("reflections") }
            if r.rayTracedAO { rt.append("ambient occlusion") }
            report.presets.append(PresetReport(
                preset: preset.rawValue, antiAliasing: r.antiAliasing.rawValue, msaaSamples: r.msaaSamples,
                upscaler: r.upscaler.rawValue, renderScale: r.renderScale, renderSizeFor1440p: "\(size.width)×\(size.height)",
                rayTracing: rt, fallbacks: r.fallbacks.map(\.description)))
        }

        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) { print(text) }
        } else {
            printText(report)
        }
    }

    static func printText(_ r: Report) {
        print("Ferox \(r.ferox) diagnostics")
        print("OS: \(r.os) · \(r.processors) CPU cores · \(String(format: "%.1f", r.memoryGB)) GB RAM")
        if let c = r.capabilities {
            print("GPU: \(c.deviceName) (Apple family \(c.appleFamily), Metal 3: \(c.supportsMetal3), unified memory: \(c.hasUnifiedMemory))")
            print("  ray tracing: \(c.supportsRaytracing) (hardware: \(c.hasHardwareRayTracing)) · MetalFX spatial: \(c.supportsMetalFXSpatial) · temporal: \(c.supportsMetalFXTemporal)")
            print("  MSAA sample counts: \(c.supportedSampleCounts.map(String.init).joined(separator: ", ")) · mesh shaders: \(c.supportsMeshShaders)")
            print("  working set: \(c.recommendedMaxWorkingSetSize / 1_048_576) MB · max buffer: \(c.maxBufferLength / 1_048_576) MB")
        } else {
            print("GPU: Metal is not available on this system; presets below use the baseline capability set.")
        }
        for p in r.presets {
            print("\n[\(p.preset)] AA \(p.antiAliasing)\(p.msaaSamples > 1 ? " ×\(p.msaaSamples)" : "") · upscaler \(p.upscaler) (scale \(p.renderScale)) · 1440p renders at \(p.renderSizeFor1440p)")
            if !p.rayTracing.isEmpty { print("  ray traced: \(p.rayTracing.joined(separator: ", "))") }
            for f in p.fallbacks { print("  fallback: \(f)") }
        }
        if let o = r.offscreenRender { print("\nOffscreen render: \(o)") }
    }

    #if canImport(Metal)
    /// Renders one frame of a tiny scene offscreen and reports whether it produced pixels.
    static func renderSmokeTest(_ device: RenderDevice) -> String {
        do {
            let assets = AssetManager(database: nil)
            let renderer = try Renderer(device: device, settings: GraphicsSettings(preset: .medium), assets: assets)
            let world = World()
            let mesh = AssetID("diag.cube")
            _ = assets.registerMesh(.cube(), id: mesh)
            let cube = world.createEntity(named: "Cube")
            world.add(MeshRenderer(mesh: mesh), to: cube)
            let cam = world.createEntity(named: "Camera", transform: Transform(position: Vec3(0, 0, 3)))
            world.add(Camera.perspective(), to: cam)
            let sun = world.createEntity(named: "Sun", transform: Transform(rotation: .lookRotation(forward: Vec3(0, -1, -1).normalized)))
            world.add(Light.directional(), to: sun)
            TransformSystem.update(world)
            guard let texture = renderer.renderOffscreen(world: world, width: 256, height: 256) else {
                return "failed (no output texture)"
            }
            renderer.waitUntilIdle()
            guard let pixels = renderer.readPixels(texture) else { return "failed (readback)" }
            let lit = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 8 || pixels[$0 + 1] > 8 || pixels[$0 + 2] > 8 }.count
            return "ok (256×256, \(lit) non-black pixels, \(renderer.statistics.visibleObjects) visible objects)"
        } catch {
            return "failed (\(error))"
        }
    }
    #endif
}
