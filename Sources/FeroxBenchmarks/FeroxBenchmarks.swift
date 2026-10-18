import Ferox
import Foundation

/// `FeroxBenchmarks` — repeatable CPU micro-benchmarks for the engine's hot paths, plus an
/// optional offscreen GPU frame on macOS.
///
/// ```
/// swift run -c release FeroxBenchmarks                     # full run, text report
/// swift run -c release FeroxBenchmarks --quick             # fewer iterations (CI)
/// swift run -c release FeroxBenchmarks --output out.json   # also write JSON
/// swift run -c release FeroxBenchmarks --filter physics    # only matching benchmarks
/// ```
///
/// Every number in the report is measured on the machine running the tool; nothing is
/// estimated or copied from elsewhere. Results are only comparable between runs on the
/// same machine, build configuration and power state — always benchmark `-c release`.
@main
enum FeroxBenchmarks {
    /// One benchmark's measured result. Times are per iteration, in milliseconds.
    struct Result: Codable {
        var name: String
        var iterations: Int
        var meanMs: Double
        var medianMs: Double
        var minMs: Double
        var maxMs: Double
        /// Optional work-rate figure, e.g. "entities/s".
        var throughput: Double?
        var throughputUnit: String?
    }

    struct Report: Codable {
        var ferox: String
        var date: String
        var os: String
        var processors: Int
        var memoryGB: Double
        var buildConfiguration: String
        var quick: Bool
        var gpu: String?
        var results: [Result]
    }

    /// A named benchmark. `make` builds fresh state (untimed) and returns the timed body,
    /// which returns the number of work items it processed (for the throughput figure).
    struct Benchmark {
        var name: String
        var unit: String?
        var make: (_ quick: Bool) -> () -> Int
    }

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print("usage: FeroxBenchmarks [--quick] [--output file.json] [--filter substring]")
            return
        }
        let quick = args.contains("--quick")
        args.removeAll { $0 == "--quick" }
        let output = value(after: "--output", in: args)
        let filter = value(after: "--filter", in: args)?.lowercased()

        #if DEBUG
        let configuration = "debug"
        print("warning: debug build — numbers are not representative; use `swift run -c release FeroxBenchmarks`")
        #else
        let configuration = "release"
        #endif

        var report = Report(
            ferox: FeroxVersion.string,
            date: ISO8601DateFormatter().string(from: Date()),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            processors: ProcessInfo.processInfo.activeProcessorCount,
            memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            buildConfiguration: configuration, quick: quick, gpu: nil, results: [])

        var benchmarks = cpuBenchmarks
        #if canImport(Metal)
        if let device = try? RenderDevice() {
            report.gpu = device.capabilities.deviceName
            benchmarks.append(contentsOf: gpuBenchmarks(device))
        }
        #endif

        for b in benchmarks where filter.map({ b.name.lowercased().contains($0) }) ?? true {
            let r = measure(b, quick: quick)
            report.results.append(r)
            var line = r.name.padding(toLength: max(34, r.name.count), withPad: " ", startingAt: 0)
            line += String(format: " mean %9.3f ms  median %9.3f ms  min %9.3f ms  (n=%d)",
                           r.meanMs, r.medianMs, r.minMs, r.iterations)
            if let t = r.throughput, let u = r.throughputUnit { line += String(format: "  %.3g ", t) + u }
            print(line)
        }

        if let output {
            do {
                // Only plain relative or absolute file paths are accepted; the parent folder is
                // created if missing so CI can write into a fresh `BenchmarkResults/`.
                let url = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: url, options: .atomic)
                print("wrote \(url.path)")
            } catch {
                print("error: could not write \(output): \(error)")
                exit(1)
            }
        }
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Runs one warm-up iteration, then times `iterations` fresh runs (setup excluded).
    static func measure(_ b: Benchmark, quick: Bool) -> Result {
        let iterations = quick ? 5 : 20
        _ = b.make(quick)() // warm-up: page in code and data, fill caches and pools
        var samples: [Double] = []
        var work = 0
        for _ in 0..<iterations {
            let body = b.make(quick)
            let start = MonotonicClock.now()
            work = body()
            samples.append((MonotonicClock.now() - start) * 1000)
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let median = samples.count % 2 == 1 ? samples[samples.count / 2]
            : (samples[samples.count / 2 - 1] + samples[samples.count / 2]) / 2
        let throughput = b.unit != nil && median > 0 ? Double(work) / (median / 1000) : nil
        return Result(name: b.name, iterations: iterations, meanMs: mean, medianMs: median,
                      minMs: samples.first ?? 0, maxMs: samples.last ?? 0,
                      throughput: throughput, throughputUnit: throughput == nil ? nil : b.unit)
    }

    // MARK: - CPU benchmarks

    static let cpuBenchmarks: [Benchmark] = [
        Benchmark(name: "ecs.create+destroy", unit: "entities/s") { quick in
            let n = quick ? 20_000 : 100_000
            return {
                let world = World()
                var entities: [Entity] = []
                entities.reserveCapacity(n)
                for i in 0..<n {
                    let e = world.createEntity()
                    world.add(Transform(position: Vec3(Float(i), 0, 0)), to: e)
                    entities.append(e)
                }
                for e in entities { world.destroy(e) }
                return n
            }
        },
        Benchmark(name: "ecs.forEach(Transform)", unit: "components/s") { quick in
            let n = quick ? 50_000 : 200_000
            let world = World()
            for i in 0..<n { world.add(Transform(position: Vec3(Float(i), 0, 0)), to: world.createEntity()) }
            return {
                world.forEach(Transform.self) { _, t in t.position.y += 0.01 }
                return n
            }
        },
        Benchmark(name: "transform.hierarchy", unit: "entities/s") { quick in
            // A forest of 4-level chains with every root moved each frame, so the whole
            // hierarchy is dirty: the worst case for `TransformSystem`.
            let roots = quick ? 2_500 : 10_000
            let world = World()
            var rootEntities: [Entity] = []
            for i in 0..<roots {
                var parent = world.createEntity(named: "r\(i)", transform: Transform(position: Vec3(Float(i), 0, 0)))
                rootEntities.append(parent)
                for _ in 0..<3 { parent = world.createEntity(named: "c", transform: Transform(position: Vec3(0, 1, 0)), parent: parent) }
            }
            TransformSystem.update(world)
            return {
                for e in rootEntities { world.modify(Transform.self, e) { $0.position.z += 0.1 } }
                TransformSystem.update(world)
                return roots * 4
            }
        },
        Benchmark(name: "physics2d.pile(500).60steps", unit: "body-steps/s") { quick in
            let n = quick ? 200 : 500
            let engine = makeEngine(physics2D: true, physics3D: false)
            let ground = engine.world.createEntity(named: "Ground")
            engine.world.add(Collider2D.box(Vec2(200, 1)), to: ground)
            for i in 0..<n {
                let e = engine.world.createEntity(named: "Box", transform: Transform(position: Vec3(Float(i % 25) * 1.1 - 13, 1 + Float(i / 25) * 1.1, 0)))
                engine.world.add(RigidBody2D(), to: e)
                engine.world.add(Collider2D.box(Vec2(1, 1)), to: e)
            }
            return {
                engine.simulate(frames: 60)
                return n * 60
            }
        },
        Benchmark(name: "physics3d.pile(500).60steps", unit: "body-steps/s") { quick in
            let n = quick ? 200 : 500
            let engine = makeEngine(physics2D: false, physics3D: true)
            let ground = engine.world.createEntity(named: "Ground")
            engine.world.add(Collider3D.box(Vec3(100, 1, 100)), to: ground)
            for i in 0..<n {
                let p = Vec3(Float(i % 10) * 1.1 - 5, 1 + Float(i / 100) * 1.1, Float((i / 10) % 10) * 1.1 - 5)
                let e = engine.world.createEntity(named: "Crate", transform: Transform(position: p))
                engine.world.add(RigidBody3D(), to: e)
                engine.world.add(Collider3D.box(Vec3(1, 1, 1)), to: e)
            }
            return {
                engine.simulate(frames: 60)
                return n * 60
            }
        },
        Benchmark(name: "events.enqueue+flush", unit: "events/s") { quick in
            let n = quick ? 100_000 : 500_000
            let bus = EventBus()
            var sum = 0
            let subscription = bus.subscribe(BenchEvent.self) { sum &+= $0.value }
            return {
                for i in 0..<n { bus.enqueue(BenchEvent(value: i)) }
                bus.flush()
                withExtendedLifetime(subscription) {}
                return n
            }
        },
        Benchmark(name: "math.mat4-multiply", unit: "products/s") { quick in
            let n = quick ? 200_000 : 1_000_000
            let a = Mat4(translation: Vec3(1, 2, 3), rotation: Quat(angle: 0.3, axis: Vec3(0, 1, 0)), scale: Vec3(1, 1, 1))
            return {
                var m = Mat4.identity
                for _ in 0..<n { m = m * a }
                blackHole(m)
                return n
            }
        },
        Benchmark(name: "engine.tick(empty scene)", unit: "ticks/s") { quick in
            let n = quick ? 2_000 : 10_000
            let engine = makeEngine(physics2D: true, physics3D: true)
            return {
                engine.simulate(frames: n)
                return n
            }
        },
    ]

    struct BenchEvent: Event { var value: Int }

    static func makeEngine(physics2D: Bool, physics3D: Bool) -> Engine {
        var config = EngineConfiguration(title: "Benchmark")
        config.enableAudio = false
        config.physics2D = physics2D
        config.physics3D = physics3D
        // Benchmarks never touch the file system; a failure here is a programming error.
        guard let engine = try? Engine(configuration: config) else { fatalError("Engine failed to start") }
        return engine
    }

    /// Prevents the optimiser from removing a computation whose result is otherwise unused.
    @inline(never) static func blackHole<T>(_ value: T) { withExtendedLifetime(value) {} }

    // MARK: - GPU benchmarks (macOS)

    #if canImport(Metal)
    /// Times complete offscreen frames (CPU encode + GPU execution + wait) of a lit scene.
    static func gpuBenchmarks(_ device: RenderDevice) -> [Benchmark] {
        QualityPreset.allCases.compactMap { preset in
            // One renderer per preset, created up front: pipeline compilation is a one-off
            // cost that must not land in the timed loop.
            let assets = AssetManager(database: nil)
            guard let renderer = try? Renderer(device: device, settings: GraphicsSettings(preset: preset), assets: assets) else {
                print("note: skipping gpu.\(preset.rawValue) (renderer creation failed)")
                return nil
            }
            let world = benchmarkScene(assets)
            return Benchmark(name: "gpu.offscreen-1080p.\(preset.rawValue)", unit: "frames/s") { quick in
                let frames = quick ? 10 : 60
                return {
                    for _ in 0..<frames { _ = renderer.renderOffscreen(world: world, width: 1920, height: 1080) }
                    renderer.waitUntilIdle()
                    return frames
                }
            }
        }
    }

    /// 400 lit spheres on a floor with a shadowed sun and four point lights.
    static func benchmarkScene(_ assets: AssetManager) -> World {
        let world = World()
        let sphere = AssetID("bench.sphere"), floor = AssetID("bench.floor")
        _ = assets.registerMesh(.sphere(radius: 0.4, segments: 32, rings: 16), id: sphere)
        _ = assets.registerMesh(.plane(size: 60, subdivisions: 1), id: floor)
        var material = MaterialData(id: AssetID("bench.material"), name: "Bench")
        material.baseColor = Color(0.8, 0.6, 0.4, 1)
        material.roughness = 0.4
        assets.registerMaterial(material)
        let f = world.createEntity(named: "Floor")
        world.add(MeshRenderer(mesh: floor, materials: [material.id]), to: f)
        for x in 0..<20 {
            for z in 0..<20 {
                let e = world.createEntity(named: "S", transform: Transform(position: Vec3(Float(x) - 10, 0.4, Float(z) - 10)))
                world.add(MeshRenderer(mesh: sphere, materials: [material.id]), to: e)
            }
        }
        let sun = world.createEntity(named: "Sun", transform: Transform(rotation: .lookRotation(forward: Vec3(-0.4, -1, -0.3).normalized)))
        world.add(Light.directional(), to: sun)
        for i in 0..<4 {
            let p = world.createEntity(named: "Point", transform: Transform(position: Vec3(Float(i) * 5 - 7.5, 2, 0)))
            world.add(Light(type: .point, color: Color(1, 0.8, 0.6, 1), intensity: 20, range: 8), to: p)
        }
        let cam = world.createEntity(named: "Camera", transform: Transform(
            position: Vec3(0, 8, 16), rotation: .lookRotation(forward: Vec3(0, -8, -16).normalized)))
        world.add(Camera.perspective(), to: cam)
        TransformSystem.update(world)
        return world
    }
    #endif
}
