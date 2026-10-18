#if canImport(Metal)
import FeroxAssets
import FeroxCore
import FeroxScene
import Foundation
import Metal

/// Image-based lighting resources derived from the scene's `Environment`:
///
/// ```
/// procedural sky / equirect HDR / flat colour ──generateEnvironment──▶ environment cube (mipmapped)
/// environment cube ──convolveIrradiance──▶ irradiance cube (diffuse)
/// environment cube ──prefilterSpecular──▶ prefiltered cube (GGX, roughness per mip)
/// integrateBRDF ──▶ split-sum LUT (computed once)
/// ```
///
/// Regeneration is driven by `Key`: it changes only when the sky definition changes (the
/// sun direction is quantised to ~0.25° so a slowly animated sun regenerates occasionally,
/// not every frame). Generation is a handful of compute dispatches on the frame's command
/// buffer, so there is no stall.
final class EnvironmentLighting {
    /// Everything that affects the generated cubes.
    struct Key: Hashable {
        var mode: UInt32
        var sun: SIMD3<Int32>
        var turbidity: Float
        var texture: AssetID?
        var textureReady: Bool
        var color: SIMD3<Float>
    }

    static let environmentSize = 256
    static let irradianceSize = 32
    static let prefilteredSize = 128
    static let prefilteredMips = 6
    static let brdfSize = 256

    let device: any MTLDevice
    let shaders: ShaderLibrary
    /// Source radiance cube (mip chain used by the filters and the sky pass).
    let environment: any MTLTexture
    let irradiance: any MTLTexture
    let prefiltered: any MTLTexture
    let brdfLUT: any MTLTexture
    private let prefilteredViews: [any MTLTexture]
    private var key: Key?
    private var brdfReady = false
    private var trackedBytes = 0

    /// Number of times the cubes were regenerated (diagnostics and tests).
    private(set) var generations = 0

    init(device: any MTLDevice, shaders: ShaderLibrary) throws {
        self.device = device
        self.shaders = shaders
        func cube(_ label: String, _ size: Int, mips: Int) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size,
                                                               mipmapped: mips > 1)
            d.mipmapLevelCount = mips
            d.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.allocation(label) }
            t.label = label
            return t
        }
        // Locals first: `self` cannot be read until every stored property is set.
        let env = try cube("Ferox.EnvironmentCube", Self.environmentSize,
                           mips: RenderMath.mipCount(Self.environmentSize, Self.environmentSize))
        let irr = try cube("Ferox.IrradianceCube", Self.irradianceSize, mips: 1)
        let pre = try cube("Ferox.PrefilteredCube", Self.prefilteredSize, mips: Self.prefilteredMips)
        let views = (0..<Self.prefilteredMips).compactMap { level in
            pre.makeTextureView(pixelFormat: .rgba16Float, textureType: .typeCube,
                                levels: level..<(level + 1), slices: 0..<6)
        }
        guard views.count == Self.prefilteredMips else { throw RenderError.allocation("prefiltered cube views") }
        let ld = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: Self.brdfSize,
                                                          height: Self.brdfSize, mipmapped: false)
        ld.usage = [.shaderRead, .shaderWrite]
        ld.storageMode = .private
        guard let lut = device.makeTexture(descriptor: ld) else { throw RenderError.allocation("BRDF LUT") }
        lut.label = "Ferox.BRDFLUT"
        environment = env
        irradiance = irr
        prefiltered = pre
        prefilteredViews = views
        brdfLUT = lut
        trackedBytes = [env, irr, pre, lut].reduce(0) { $0 + $1.allocatedSize }
        MemoryTracker.shared.allocate("GPU.Environment", bytes: trackedBytes)
    }

    deinit { MemoryTracker.shared.free("GPU.Environment", bytes: trackedBytes) }

    /// Mip count of the prefiltered cube (`FrameUniforms.exposure.z`).
    var prefilteredMipCount: Int { Self.prefilteredMips }

    /// Builds the key for an environment. `sun` overrides the procedural sun direction so
    /// the sky follows the scene's main directional light.
    static func key(for env: Environment, sun: Vec3?, textureReady: Bool) -> Key {
        switch env.sky {
        case let .procedural(dir, turbidity):
            let d = (sun ?? dir).lengthSquared > 1e-8 ? (sun ?? dir).normalized : Vec3.up
            // 1/229 ≈ 0.25° steps on the unit sphere.
            let q = SIMD3<Int32>(Int32((d.x * 229).rounded()), Int32((d.y * 229).rounded()), Int32((d.z * 229).rounded()))
            return Key(mode: 0, sun: q, turbidity: turbidity, texture: nil, textureReady: false, color: .zero)
        case let .texture(id):
            return Key(mode: 1, sun: .zero, turbidity: 0, texture: id, textureReady: textureReady, color: .zero)
        case let .color(c):
            return Key(mode: 2, sun: .zero, turbidity: 0, texture: nil, textureReady: false, color: c.rgb)
        }
    }

    /// Regenerates the cubes when the environment changed. `equirect` is the loaded sky
    /// texture for `.texture` skies (nil while it is still loading, in which case the
    /// ambient colour is used until it arrives).
    func update(_ env: Environment, sun: Vec3?, equirect: (any MTLTexture)?, fallback: any MTLTexture,
                commandBuffer cb: any MTLCommandBuffer, allocator: FrameAllocator) {
        let k = Self.key(for: env, sun: sun, textureReady: equirect != nil)
        if !brdfReady { encodeBRDF(cb) }
        guard k != key else { return }

        var p = SkyParams()
        switch env.sky {
        case let .procedural(dir, turbidity):
            let d = sun ?? dir
            p.sunDirection = Vec4(d.lengthSquared > 1e-8 ? d.normalized : .up, max(turbidity, 1))
            p.mode.x = 0
        case .texture:
            if equirect != nil {
                p.mode.x = 1
            } else {
                p.mode.x = 2
                p.tint = Vec4(env.ambientColor.rgb, 1)
            }
        case let .color(c):
            p.mode.x = 2
            p.tint = Vec4(c.rgb, 1)
        }
        p.mode.y = UInt32(Self.environmentSize)

        do {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.label = "Ferox.GenerateEnvironment"
            let gen = try shaders.computePipeline("generateEnvironment")
            enc.setComputePipelineState(gen)
            enc.setValue(p, index: 0, allocator: allocator)
            enc.setTexture(equirect ?? fallback, index: 0)
            enc.setTexture(environment, index: 1)
            dispatchCube(enc, gen, size: Self.environmentSize)
            enc.endEncoding()

            // The filters sample lower mips of the source to keep sample counts small.
            if let blit = cb.makeBlitCommandEncoder() {
                blit.label = "Ferox.EnvironmentMips"
                blit.generateMipmaps(for: environment)
                blit.endEncoding()
            }

            guard let filter = cb.makeComputeCommandEncoder() else { return }
            filter.label = "Ferox.FilterEnvironment"
            let irr = try shaders.computePipeline("convolveIrradiance")
            var ip = p
            ip.mode.z = 128
            ip.filter = Vec4(0, Float(Self.environmentSize), 0, 0)
            filter.setComputePipelineState(irr)
            filter.setValue(ip, index: 0, allocator: allocator)
            filter.setTexture(environment, index: 0)
            filter.setTexture(irradiance, index: 1)
            dispatchCube(filter, irr, size: Self.irradianceSize)

            let pre = try shaders.computePipeline("prefilterSpecular")
            filter.setComputePipelineState(pre)
            filter.setTexture(environment, index: 0)
            for (level, view) in prefilteredViews.enumerated() {
                var fp = p
                fp.mode.z = 64
                fp.mode.w = UInt32(level)
                // Roughness is linear in mip index; the forward shader uses the same mapping.
                fp.filter = Vec4(Float(level) / Float(max(Self.prefilteredMips - 1, 1)), Float(Self.environmentSize), 0, 0)
                filter.setValue(fp, index: 0, allocator: allocator)
                filter.setTexture(view, index: 1)
                dispatchCube(filter, pre, size: max(Self.prefilteredSize >> level, 1))
            }
            filter.endEncoding()
            key = k
            generations += 1
            Profiler.shared.count("Render.EnvironmentRegenerations")
        } catch {
            // A missing kernel leaves the previous cubes in place; ShaderLibrary already
            // logged the compile error, so only note it once per key.
            Log.error("Render", "Environment generation failed: \(error)")
            key = k
        }
    }

    /// Forces regeneration on the next `update` (shader hot reload, device change).
    func invalidate() {
        key = nil
        brdfReady = false
    }

    private func encodeBRDF(_ cb: any MTLCommandBuffer) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Ferox.IntegrateBRDF"
        defer { enc.endEncoding() }
        do {
            let pso = try shaders.computePipeline("integrateBRDF")
            enc.setTexture(brdfLUT, index: 0)
            enc.dispatch2D(pso, width: Self.brdfSize, height: Self.brdfSize)
            brdfReady = true
        } catch {
            Log.error("Render", "BRDF LUT integration failed: \(error)")
            brdfReady = true  // do not retry every frame; the LUT stays black
        }
    }

    private func dispatchCube(_ enc: any MTLComputeCommandEncoder, _ pso: any MTLComputePipelineState, size: Int) {
        let w = min(8, pso.threadExecutionWidth)
        let h = max(min(pso.maxTotalThreadsPerThreadgroup / w, 8), 1)
        let group = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: RenderMath.groups(size, w), height: RenderMath.groups(size, h), depth: 6)
        enc.setComputePipelineState(pso)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
    }
}
#endif
