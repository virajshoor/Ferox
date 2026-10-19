import Foundation

/// Where mesh and post shaders are loaded from. Hot reload (`FEROX_SHADER_DIR`) always
/// wins. Otherwise a precompiled metallib is used when one is present, and source
/// compilation remains the fallback so a checkout without a metallib still runs.
public enum ShaderSourcePolicy: Equatable, Sendable {
    case hotReloadDirectory
    case compiledMetallib
    case runtimeSource

    public static func resolve(shaderDirectorySet: Bool, metallibPresent: Bool) -> ShaderSourcePolicy {
        if shaderDirectorySet { return .hotReloadDirectory }
        if metallibPresent { return .compiledMetallib }
        return .runtimeSource
    }
}

/// One mesh-pipeline variant the renderer should build before the first frame.
public struct PipelinePrewarmKey: Hashable, Sendable {
    public var pass: String
    public var skinning: Bool
    public var alphaTest: Bool
    public var clusters: Bool
    public var unlit: Bool
    public var samples: Int
    public var materialArguments: Bool

    public init(
        pass: String, skinning: Bool, alphaTest: Bool, clusters: Bool, unlit: Bool, samples: Int,
        materialArguments: Bool
    ) {
        self.pass = pass
        self.skinning = skinning
        self.alphaTest = alphaTest
        self.clusters = clusters
        self.unlit = unlit
        self.samples = samples
        self.materialArguments = materialArguments
    }
}

public enum PipelinePrewarm {
    /// The variants a resolved preset will draw: shadowed and unshadowed, skinned and not,
    /// with and without the material argument-buffer permutation when that path is on.
    public static func keys(clusters: Bool, samples: Int, materialArguments: Bool) -> [PipelinePrewarmKey] {
        var keys: [PipelinePrewarmKey] = []
        let sampleCount = max(samples, 1)
        for skinning in [false, true] {
            for alpha in [false, true] {
                keys.append(
                    PipelinePrewarmKey(
                        pass: "shadow", skinning: skinning, alphaTest: alpha, clusters: false, unlit: false,
                        samples: 1, materialArguments: false))
            }
            for unlit in [false, true] {
                for pass in ["prepass", "forward"] {
                    keys.append(
                        PipelinePrewarmKey(
                            pass: pass, skinning: skinning, alphaTest: false, clusters: clusters, unlit: unlit,
                            samples: pass == "prepass" ? sampleCount : sampleCount, materialArguments: materialArguments
                        ))
                }
            }
        }
        return keys
    }
}
