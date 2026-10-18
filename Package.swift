// swift-tools-version:5.10
//
// Ferox — a Metal-based game engine for macOS.
//
// Module layout (see Docs/04-Architecture.md for the full dependency graph):
//
//   FeroxMath ─┬─ FeroxCore ─┬─ FeroxScene ─┬─ FeroxPhysics
//              │             │              ├─ FeroxAnimation
//              │             │              └─ FeroxAssets
//              │             ├─ FeroxInput
//              │             ├─ FeroxAudio
//              │             ├─ FeroxNet
//              │             └─ FeroxUI
//              └─ FeroxRender (Metal; macOS only)
//   Ferox (umbrella: Engine, main loop, integration) ── FeroxEditor, examples, tools
//
// Every module except FeroxRender, FeroxAudio's AVFoundation backend and the
// platform backends of FeroxInput/FeroxUI is platform-independent Swift so that the
// simulation core can be unit-tested anywhere a Swift toolchain exists.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ExistentialAny"),
    .define("FEROX_DEBUG", .when(configuration: .debug)),
]

let package = Package(
    name: "Ferox",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Ferox", targets: ["Ferox"]),
        .library(name: "FeroxMath", targets: ["FeroxMath"]),
        .library(name: "FeroxCore", targets: ["FeroxCore"]),
        .library(name: "FeroxScene", targets: ["FeroxScene"]),
        .library(name: "FeroxPhysics", targets: ["FeroxPhysics"]),
        .library(name: "FeroxRender", targets: ["FeroxRender"]),
        .executable(name: "FeroxEditor", targets: ["FeroxEditor"]),
        .executable(name: "FeroxDiag", targets: ["FeroxDiag"]),
        .executable(name: "FeroxBenchmarks", targets: ["FeroxBenchmarks"]),
        .executable(name: "HelloFerox", targets: ["HelloFerox"]),
        .executable(name: "Platformer2D", targets: ["Platformer2D"]),
        .executable(name: "Showcase3D", targets: ["Showcase3D"]),
    ],
    targets: [
        // MARK: Portable core
        .target(name: "FeroxMath", swiftSettings: swiftSettings),
        .target(name: "FeroxCore", dependencies: ["FeroxMath"], swiftSettings: swiftSettings),
        .target(name: "FeroxScene", dependencies: ["FeroxMath", "FeroxCore"], swiftSettings: swiftSettings),
        .target(name: "FeroxPhysics", dependencies: ["FeroxMath", "FeroxCore", "FeroxScene"],
                swiftSettings: swiftSettings),
        .target(name: "FeroxAnimation", dependencies: ["FeroxMath", "FeroxCore", "FeroxScene"],
                swiftSettings: swiftSettings),
        .target(name: "FeroxInput", dependencies: ["FeroxMath", "FeroxCore"], swiftSettings: swiftSettings),
        .target(name: "FeroxAssets", dependencies: ["FeroxMath", "FeroxCore", "FeroxScene", "FeroxAnimation"],
                swiftSettings: swiftSettings),
        .target(name: "FeroxNet", dependencies: ["FeroxCore"], swiftSettings: swiftSettings),
        .target(name: "FeroxAudio", dependencies: ["FeroxMath", "FeroxCore"], swiftSettings: swiftSettings),
        .target(name: "FeroxUI", dependencies: ["FeroxMath", "FeroxCore", "FeroxInput"], swiftSettings: swiftSettings),

        // MARK: Metal backend (macOS)
        .target(
            name: "FeroxRender",
            dependencies: ["FeroxMath", "FeroxCore", "FeroxScene", "FeroxAssets", "FeroxAnimation", "FeroxUI"],
            resources: [.copy("Shaders")],
            swiftSettings: swiftSettings
        ),

        // MARK: Umbrella / runtime
        .target(
            name: "Ferox",
            dependencies: [
                "FeroxMath", "FeroxCore", "FeroxScene", "FeroxPhysics", "FeroxAnimation", "FeroxInput",
                "FeroxAssets", "FeroxNet", "FeroxAudio", "FeroxUI", "FeroxRender",
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: Tools
        .executableTarget(name: "FeroxEditor", dependencies: ["Ferox"], swiftSettings: swiftSettings),
        .executableTarget(name: "FeroxDiag", dependencies: ["Ferox"], swiftSettings: swiftSettings),
        .executableTarget(name: "FeroxBenchmarks", dependencies: ["Ferox"], swiftSettings: swiftSettings),

        // MARK: Examples
        .executableTarget(name: "HelloFerox", dependencies: ["Ferox"], path: "Examples/HelloFerox",
                          swiftSettings: swiftSettings),
        .executableTarget(name: "Platformer2D", dependencies: ["Ferox"], path: "Examples/Platformer2D",
                          swiftSettings: swiftSettings),
        .executableTarget(name: "Showcase3D", dependencies: ["Ferox"], path: "Examples/Showcase3D",
                          swiftSettings: swiftSettings),

        // MARK: Tests
        .testTarget(name: "FeroxMathTests", dependencies: ["FeroxMath"]),
        .testTarget(name: "FeroxCoreTests", dependencies: ["FeroxCore"]),
        .testTarget(name: "FeroxSceneTests", dependencies: ["FeroxScene"]),
        .testTarget(name: "FeroxPhysicsTests", dependencies: ["FeroxPhysics"]),
        .testTarget(name: "FeroxSubsystemTests",
                    dependencies: ["FeroxInput", "FeroxAnimation", "FeroxAssets", "FeroxNet", "FeroxUI", "FeroxAudio"]),
        .testTarget(name: "FeroxRenderTests", dependencies: ["FeroxRender", "Ferox"]),
        .testTarget(name: "FeroxIntegrationTests", dependencies: ["Ferox"]),
    ]
)
