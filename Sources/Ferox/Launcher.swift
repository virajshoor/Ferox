import Foundation

/// Command-line entry point shared by games, the examples and tools.
///
/// ```
/// MyGame                       # windowed (macOS)
/// MyGame --headless --frames 600 --dt 0.016667
/// ```
///
/// `--headless` runs the simulation without a window or renderer and prints a short
/// summary — useful for smoke tests, servers and platforms without Metal (where it is the
/// only mode).
public enum GameLauncher {
    public struct Options: Equatable, Sendable {
        public var headless = false
        public var frames = 600
        public var delta = 1.0 / 60
        public init() {}
    }

    /// Parses launcher flags; unknown arguments are ignored (they belong to the game).
    public static func parse(_ arguments: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--headless":
                o.headless = true
            case "--frames" where i + 1 < arguments.count:
                i += 1
                o.frames = min(max(Int(arguments[i]) ?? o.frames, 0), 10_000_000)
            case "--dt" where i + 1 < arguments.count:
                i += 1
                if let d = Double(arguments[i]), d.isFinite, d > 0, d <= 1 { o.delta = d }
            default:
                break
            }
            i += 1
        }
        return o
    }

    /// Runs `game` according to the process arguments. Never returns normally in windowed
    /// mode until the window is closed.
    @MainActor
    public static func main(_ game: any Game, configuration: EngineConfiguration,
                            arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        let options = parse(arguments)
        #if canImport(AppKit) && canImport(MetalKit)
        if !options.headless {
            GameHost.run(game, configuration: configuration)
            return
        }
        #endif
        runHeadless(game, configuration: configuration, options: options)
    }

    /// Simulates `options.frames` frames without rendering. Exits with status 1 on errors.
    public static func runHeadless(_ game: any Game, configuration: EngineConfiguration, options: Options) {
        var config = configuration
        config.enableAudio = false
        do {
            let engine = try Engine(configuration: config)
            try engine.start(game)
            let start = MonotonicClock.now()
            var frames = 0
            while frames < options.frames && !engine.quitRequested {
                engine.tick(delta: options.delta)
                frames += 1
            }
            let wall = MonotonicClock.now() - start
            let entities = engine.world.entities.count
            engine.shutdown()
            print("\(config.title): simulated \(frames) frames (\(String(format: "%.2f", Double(frames) * options.delta)) s game time) in \(String(format: "%.3f", wall)) s wall time; \(entities) entities")
        } catch {
            Log.error("Engine", "Headless run failed: \(error)")
            exit(1)
        }
    }
}
