#if canImport(Metal)
import FeroxCore
import Foundation
import Metal

/// Pixel formats of the persistent targets. Kept in one place so pipelines and attachments
/// cannot disagree.
enum TargetFormat {
    /// Scene colour before tone mapping (pre-exposed linear radiance).
    static let hdr: MTLPixelFormat = .rgba16Float
    /// Reverse-Z depth plus the 2D mask stencil.
    static let depth: MTLPixelFormat = .depth32Float_stencil8
    /// World normal (xyz · 0.5 + 0.5) and roughness.
    static let normal: MTLPixelFormat = .rgba16Float
    /// Screen-space motion in UV units (current − previous).
    static let motion: MTLPixelFormat = .rg16Float
    /// Ambient occlusion (1 = unoccluded).
    static let ao: MTLPixelFormat = .r8Unorm
    /// Tone-mapped, sRGB-encoded colour stored in a unorm texture. Viewed as
    /// `rgba8Unorm_srgb` when presented so the drawable receives correct values.
    static let ldr: MTLPixelFormat = .rgba8Unorm
    static let ldrSRGBView: MTLPixelFormat = .rgba8Unorm_srgb
    /// The drawable format the presenter expects (`CAMetalLayer.pixelFormat`).
    static let drawable: MTLPixelFormat = .bgra8Unorm_srgb
    /// Hierarchical-Z pyramid (farthest reverse-Z depth per texel).
    static let hiz: MTLPixelFormat = .r32Float
}

/// The persistent, size-dependent textures of one view: the prepass G-buffer, the HDR scene
/// colour, temporal history and the LDR ping-pong pair.
///
/// Targets are reallocated only when `Config` changes (resize, MSAA or feature toggle). Each
/// allocation is reported to `MemoryTracker` under "GPU.RenderTargets" and released on
/// reallocation and in `deinit`, so the memory overlay stays exact.
final class RenderTargets {
    struct Config: Equatable {
        var renderWidth: Int
        var renderHeight: Int
        var outputWidth: Int
        var outputHeight: Int
        var msaaSamples: Int
        /// Allocates the two output-resolution history buffers (TAA / temporal upscaling).
        var temporalHistory: Bool
        /// Allocates the Hi-Z pyramid (GPU occlusion culling).
        var hiz: Bool
    }

    let device: any MTLDevice
    private(set) var config: Config?
    private var trackedBytes = 0

    // MARK: Render resolution

    /// Single-sample depth (the MSAA resolve target when multisampling). Sampled by SSAO,
    /// TAA, DOF, ray tracing and the Hi-Z builder.
    private(set) var depth: (any MTLTexture)?
    /// Multisampled depth shared by the prepass and the main pass (nil without MSAA).
    private(set) var depthMSAA: (any MTLTexture)?
    private(set) var hdr: (any MTLTexture)?
    private(set) var hdrMSAA: (any MTLTexture)?
    private(set) var normal: (any MTLTexture)?
    private(set) var normalMSAA: (any MTLTexture)?
    private(set) var motion: (any MTLTexture)?
    private(set) var motionMSAA: (any MTLTexture)?
    /// Screen-space or ray-traced ambient occlusion at render resolution.
    private(set) var ao: (any MTLTexture)?
    private(set) var hiz: (any MTLTexture)?
    /// Per-mip views of `hiz` (compute kernels write one level at a time).
    private(set) var hizMips: [any MTLTexture] = []

    // MARK: Output resolution

    /// TAA / temporal-upscaler history ping-pong (rgba16Float, output size).
    private(set) var history: [any MTLTexture] = []
    /// Index of the history texture written this frame; the other one is read.
    private(set) var historyIndex = 0
    /// False after any reallocation or camera cut, so the resolve ignores stale history.
    var historyValid = false
    /// LDR ping-pong (tone-mapped, sRGB-encoded) at output size.
    private(set) var ldr: [any MTLTexture] = []

    init(device: any MTLDevice) { self.device = device }

    deinit { MemoryTracker.shared.free("GPU.RenderTargets", bytes: trackedBytes) }

    /// The depth texture the passes render into (MSAA when enabled).
    var depthAttachment: (any MTLTexture)? { depthMSAA ?? depth }

    /// Ensures every target matches `config`. Returns true when textures were reallocated
    /// (history and anything derived from the old targets must be discarded).
    @discardableResult
    func ensure(_ newConfig: Config) throws -> Bool {
        if newConfig == config { return false }
        release()
        let c = newConfig
        let rw = max(c.renderWidth, 1), rh = max(c.renderHeight, 1)
        let ow = max(c.outputWidth, 1), oh = max(c.outputHeight, 1)
        let msaa = c.msaaSamples > 1 ? c.msaaSamples : 1
        let rt: MTLTextureUsage = [.renderTarget, .shaderRead]

        depth = try make("Ferox.Depth", TargetFormat.depth, rw, rh, rt)
        hdr = try make("Ferox.HDR", TargetFormat.hdr, rw, rh, [.renderTarget, .shaderRead, .shaderWrite])
        normal = try make("Ferox.Normal", TargetFormat.normal, rw, rh, rt)
        motion = try make("Ferox.Motion", TargetFormat.motion, rw, rh, rt)
        if msaa > 1 {
            // Multisampled attachments stay resident between the prepass and the main pass,
            // so they cannot be memoryless; only their resolved copies are sampled.
            depthMSAA = try make("Ferox.DepthMSAA", TargetFormat.depth, rw, rh, .renderTarget, samples: msaa)
            hdrMSAA = try make("Ferox.HDRMSAA", TargetFormat.hdr, rw, rh, .renderTarget, samples: msaa)
            normalMSAA = try make("Ferox.NormalMSAA", TargetFormat.normal, rw, rh, .renderTarget, samples: msaa)
            motionMSAA = try make("Ferox.MotionMSAA", TargetFormat.motion, rw, rh, .renderTarget, samples: msaa)
        }
        ao = try make("Ferox.AO", TargetFormat.ao, rw, rh, [.renderTarget, .shaderRead, .shaderWrite])

        if c.hiz {
            let mips = RenderMath.mipCount(rw, rh)
            let h = try make("Ferox.HiZ", TargetFormat.hiz, rw, rh, [.shaderRead, .shaderWrite], mips: mips)
            hiz = h
            hizMips = (0..<mips).compactMap { level in
                h.makeTextureView(pixelFormat: TargetFormat.hiz, textureType: .type2D,
                                  levels: level..<(level + 1), slices: 0..<1)
            }
        }
        if c.temporalHistory {
            history = try (0..<2).map { i in
                try make("Ferox.History\(i)", TargetFormat.hdr, ow, oh, [.renderTarget, .shaderRead, .shaderWrite])
            }
        }
        ldr = try (0..<2).map { i in
            try make("Ferox.LDR\(i)", TargetFormat.ldr, ow, oh, [.renderTarget, .shaderRead, .pixelFormatView])
        }
        config = c
        historyValid = false
        historyIndex = 0
        return true
    }

    /// Advances the history ping-pong. Call once per frame before the temporal resolve.
    func swapHistory() { historyIndex ^= 1 }

    /// History written this frame (nil when temporal history is disabled).
    var currentHistory: (any MTLTexture)? { history.isEmpty ? nil : history[historyIndex] }
    /// History written last frame.
    var previousHistory: (any MTLTexture)? { history.isEmpty ? nil : history[historyIndex ^ 1] }

    /// Frees every target (used on resize and by `Renderer.purgeCaches`).
    func release() {
        MemoryTracker.shared.free("GPU.RenderTargets", bytes: trackedBytes)
        trackedBytes = 0
        depth = nil; depthMSAA = nil
        hdr = nil; hdrMSAA = nil
        normal = nil; normalMSAA = nil
        motion = nil; motionMSAA = nil
        ao = nil
        hiz = nil; hizMips = []
        history = []
        ldr = []
        config = nil
        historyValid = false
    }

    private func make(_ label: String, _ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage,
                      samples: Int = 1, mips: Int = 1) throws -> any MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = samples > 1 ? .type2DMultisample : .type2D
        d.pixelFormat = format
        d.width = w
        d.height = h
        d.sampleCount = samples
        d.mipmapLevelCount = samples > 1 ? 1 : max(mips, 1)
        d.usage = usage
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw RenderError.allocation(label) }
        t.label = label
        trackedBytes += t.allocatedSize
        MemoryTracker.shared.allocate("GPU.RenderTargets", bytes: t.allocatedSize)
        return t
    }
}
#endif
