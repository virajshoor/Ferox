#if canImport(Metal)
import FeroxAnimation
import FeroxAssets
import FeroxCore
import FeroxScene
import Foundation
import Metal

/// Captured, prefiltered reflection probes.
///
/// Each `ReflectionProbe` entity owns one slice of a cube-map array. Capturing renders the
/// scene's opaque geometry and sky into the six faces of a scratch cube (forward lighting,
/// no shadows, no probes — so a probe never samples itself), builds its mip chain and
/// prefilters it into the probe's slice with the same GGX kernel and roughness-per-mip
/// mapping as the global environment. The forward shader then box-projects reflections
/// inside each probe's volume and blends to the global IBL at its edges.
///
/// Capture is budgeted to one probe per frame: new probes and probes whose `revision`
/// changed go first, then `realtime` probes round-robin. Probes that have never been
/// captured are not submitted to the shader, so nothing ever samples an empty slice.
///
/// All probes share one cube array, so they share one face size: the largest
/// `ReflectionProbe.resolution` in the scene, rounded up to a power of two within
/// `RenderMath.probeFaceSizeRange`. A change of size reallocates the array and recaptures
/// every probe.
///
/// Limitations: at most `maxProbes` probes, and the innermost containing probe wins (no
/// blending between overlapping probes). See Docs/08-Rendering-3D.md.
final class ReflectionProbes {
    static let maxProbes = 16
    static let defaultFaceSize = 128
    /// Must equal `EnvironmentLighting.prefilteredMips`: the forward shader uses one
    /// roughness → LOD mapping for both.
    static let mips = EnvironmentLighting.prefilteredMips

    private struct Slot {
        var index: Int
        var revision: UInt64
        var captured: Bool
        var lastSeen: UInt64
    }

    let device: any MTLDevice
    let shaders: ShaderLibrary
    /// Edge length of every probe face, in texels.
    private(set) var faceSize: Int
    /// Prefiltered probe cubes (`texturecube_array`, bound at `TextureIndex.probes`).
    private(set) var array: any MTLTexture
    /// Scratch cube the faces are rendered into before prefiltering.
    private var captureCube: any MTLTexture
    /// One cube view per (slice, mip), written by `prefilterSpecular`.
    private var sliceViews: [[any MTLTexture]] = []
    /// `faceSize`² colour/depth targets for one face (no MSAA, no history).
    private let targets: RenderTargets
    private var slots: [Entity: Slot] = [:]
    private var freeSlots: [Int]
    private var realtimeCursor = 0
    private var trackedBytes = 0
    /// A face size whose allocation failed; not retried until the requested size changes.
    private var failedFaceSize: Int?

    /// Number of probe captures performed (diagnostics and tests).
    private(set) var captures = 0

    init(device: any MTLDevice, shaders: ShaderLibrary) throws {
        self.device = device
        self.shaders = shaders
        let size = Self.defaultFaceSize
        let t = RenderTargets(device: device)
        let textures = try Self.makeTextures(device: device, faceSize: size, targets: t)
        faceSize = size
        array = textures.array
        captureCube = textures.cube
        sliceViews = textures.views
        targets = t
        freeSlots = Array((0..<Self.maxProbes).reversed())
        trackedBytes = textures.array.allocatedSize + textures.cube.allocatedSize
        MemoryTracker.shared.allocate("GPU.ReflectionProbes", bytes: trackedBytes)
    }

    /// Allocates the probe array, the capture cube, the per-slice views and the face
    /// targets for `faceSize`.
    private static func makeTextures(device: any MTLDevice, faceSize: Int, targets: RenderTargets) throws
        -> (array: any MTLTexture, cube: any MTLTexture, views: [[any MTLTexture]]) {
        let ad = MTLTextureDescriptor()
        ad.textureType = .typeCubeArray
        ad.pixelFormat = .rgba16Float
        ad.width = faceSize
        ad.height = faceSize
        ad.arrayLength = maxProbes
        ad.mipmapLevelCount = mips
        ad.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        ad.storageMode = .private
        guard let arr = device.makeTexture(descriptor: ad) else { throw RenderError.allocation("probe cube array") }
        arr.label = "Ferox.ReflectionProbes"

        let cd = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: faceSize,
                                                            mipmapped: true)
        cd.usage = [.shaderRead, .renderTarget]
        cd.storageMode = .private
        guard let cube = device.makeTexture(descriptor: cd) else { throw RenderError.allocation("probe capture cube") }
        cube.label = "Ferox.ProbeCapture"

        var views: [[any MTLTexture]] = []
        for slice in 0..<maxProbes {
            let perMip = (0..<mips).compactMap { level in
                arr.makeTextureView(pixelFormat: .rgba16Float, textureType: .typeCube,
                                    levels: level..<(level + 1), slices: (slice * 6)..<(slice * 6 + 6))
            }
            guard perMip.count == mips else { throw RenderError.allocation("probe cube views") }
            views.append(perMip)
        }
        try targets.ensure(RenderTargets.Config(renderWidth: faceSize, renderHeight: faceSize,
                                                outputWidth: faceSize, outputHeight: faceSize,
                                                msaaSamples: 1, temporalHistory: false, hiz: false))
        return (arr, cube, views)
    }

    /// Reallocates for a new face size and marks every probe for recapture. On failure
    /// the previous textures stay in use.
    private func resize(to size: Int) {
        do {
            let textures = try Self.makeTextures(device: device, faceSize: size, targets: targets)
            MemoryTracker.shared.free("GPU.ReflectionProbes", bytes: trackedBytes)
            faceSize = size
            array = textures.array
            captureCube = textures.cube
            sliceViews = textures.views
            trackedBytes = textures.array.allocatedSize + textures.cube.allocatedSize
            MemoryTracker.shared.allocate("GPU.ReflectionProbes", bytes: trackedBytes)
            failedFaceSize = nil
            invalidateAll()
        } catch {
            Log.error("Render", "Could not resize reflection probes to \(size)²: \(error)")
            failedFaceSize = size  // do not retry the same size every frame
            // Keep the face targets matching the textures still in use.
            _ = try? targets.ensure(RenderTargets.Config(renderWidth: faceSize, renderHeight: faceSize,
                                                     outputWidth: faceSize, outputHeight: faceSize,
                                                     msaaSamples: 1, temporalHistory: false, hiz: false))
        }
    }

    deinit { MemoryTracker.shared.free("GPU.ReflectionProbes", bytes: trackedBytes) }

    /// Forces every probe to be recaptured (shader reload, environment change).
    func invalidateAll() {
        for k in slots.keys { slots[k]?.captured = false }
    }

    /// Assigns slots to this frame's probes, frees the slots of probes that disappeared,
    /// and returns the GPU records of captured probes, innermost (smallest) first so the
    /// shader's first-hit lookup picks the most specific probe.
    func update(_ probes: [RenderProbe], frameIndex: UInt64) -> [ProbeData] {
        let size = RenderMath.probeFaceSize(requested: probes.map(\.probe.resolution), current: faceSize)
        if size != faceSize && size != failedFaceSize { resize(to: size) }
        for p in probes {
            if slots[p.entity] == nil {
                guard let index = freeSlots.popLast() else {
                    Log.warning("Render", "More than \(Self.maxProbes) reflection probes; extra probes are ignored")
                    continue
                }
                slots[p.entity] = Slot(index: index, revision: p.probe.revision, captured: false, lastSeen: frameIndex)
            }
            slots[p.entity]?.lastSeen = frameIndex
        }
        for (e, s) in slots where s.lastSeen != frameIndex {
            freeSlots.append(s.index)
            slots[e] = nil
        }
        var out: [(volume: Float, data: ProbeData)] = []
        for p in probes {
            guard let s = slots[p.entity], s.captured else { continue }
            let ext = Vec3(max(p.probe.extents.x, 0.01), max(p.probe.extents.y, 0.01), max(p.probe.extents.z, 0.01))
            var d = ProbeData()
            // Blend over the outer quarter of the smallest half-extent.
            d.center = Vec4(p.position, max(min(ext.x, min(ext.y, ext.z)) * 0.25, 0.01))
            d.extents = Vec4(ext, Float(s.index))
            out.append((ext.x * ext.y * ext.z, d))
        }
        return out.sorted { $0.volume < $1.volume }.map(\.data)
    }

    /// The probe to capture this frame, if any.
    func nextCapture(_ probes: [RenderProbe]) -> RenderProbe? {
        if let p = probes.first(where: { p in
            guard let s = slots[p.entity] else { return false }
            return !s.captured || s.revision != p.probe.revision
        }) { return p }
        let realtime = probes.filter { $0.probe.realtime && slots[$0.entity] != nil }
        guard !realtime.isEmpty else { return nil }
        realtimeCursor = (realtimeCursor + 1) % realtime.count
        return realtime[realtimeCursor]
    }

    /// Renders and prefilters one probe on `cb`. Must be encoded before the main view's
    /// `ScenePasses.prepare`, which it would otherwise disturb (shared culling state).
    func capture(_ probe: RenderProbe, world: World, animations: AnimationLibrary?, graphics: ResolvedGraphics,
                 passes: ScenePasses, environment: EnvironmentLighting, commandBuffer cb: any MTLCommandBuffer,
                 resources r: SceneResources) {
        guard let slot = slots[probe.entity] else { return }
        // Cheap, artefact-free lighting for captures: no shadows, culling or ray tracing.
        var g = graphics
        g.settings.shadows.enabled = false
        g.settings.gpuDrivenCulling = false
        g.settings.occlusionCulling = false
        g.rayTracedShadows = false
        g.rayTracedAO = false
        g.rayTracedReflections = false
        g.screenSpaceAO = false

        let lighting = LightingTextures(prefiltered: environment.prefiltered, brdfLUT: environment.brdfLUT,
                                        shadowMap: r.fallback.shadowArray, rtShadow: r.fallback.white,
                                        rtReflection: r.fallback.clear, ambientOcclusion: r.fallback.white,
                                        irradiance: environment.irradiance, probes: r.fallback.cubeArray,
                                        localShadows: r.fallback.shadowArray)
        let extentLength = probe.probe.extents.length
        let faces = FrameUniformsBuilder.cubeFaceCameras(position: probe.position, near: 0.05,
                                                         far: max(extentLength * 8, 500))
        passes.frontFacing = .clockwise
        defer { passes.frontFacing = .counterClockwise }

        cb.pushDebugGroup("Ferox.ProbeCapture")
        defer { cb.popDebugGroup() }
        for (face, camera) in faces.enumerated() {
            var options = ExtractionOptions()
            options.cameraOverride = camera
            let frame = RenderSceneExtractor.extract(world: world, assets: r.assets, animations: animations,
                                                     aspect: 1, options: options)
            // Exposure 1: probes store linear radiance; the forward pass applies exposure.
            let u = FrameUniformsBuilder.make(camera: camera, width: faceSize, height: faceSize,
                                              jitter: .zero, previous: nil, environment: frame.environment,
                                              exposure: 1, time: 0, frameIndex: r.frameIndex,
                                              environmentMips: environment.prefilteredMipCount)
            let state = passes.prepare(frame, uniforms: u, graphics: g, probes: [], targets: targets, resources: r)
            passes.encodeCompute(cb, frame: frame, state: state, targets: targets, resources: r)
            passes.encodePrepass(cb, frame: frame, state: state, targets: targets, resources: r)
            guard let pass = passes.mainPassDescriptor(targets: targets, clearColor: .black),
                  let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.label = "Ferox.ProbeFace\(face)"
            passes.encodeOpaque(enc, frame: frame, state: state, lighting: lighting, resources: r)
            passes.encodeSky(enc, environment: environment.environment, state: state, resources: r)
            enc.endEncoding()

            guard let hdr = targets.hdr, let blit = cb.makeBlitCommandEncoder() else { return }
            blit.copy(from: hdr, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: faceSize, height: faceSize, depth: 1),
                      to: captureCube, destinationSlice: face, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
        }
        guard let mips = cb.makeBlitCommandEncoder() else { return }
        mips.generateMipmaps(for: captureCube)
        mips.endEncoding()

        do {
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            enc.label = "Ferox.ProbePrefilter"
            defer { enc.endEncoding() }
            let pso = try shaders.computePipeline("prefilterSpecular")
            enc.setTexture(captureCube, index: 0)
            for (level, view) in sliceViews[slot.index].enumerated() {
                var p = SkyParams()
                p.mode = SIMD4(0, UInt32(faceSize), 64, UInt32(level))
                p.filter = Vec4(Float(level) / Float(max(Self.mips - 1, 1)), Float(faceSize), 0, 0)
                enc.setValue(p, index: 0, allocator: r.allocator)
                enc.setTexture(view, index: 1)
                let size = max(faceSize >> level, 1)
                enc.dispatch3D(pso, width: size, height: size, depth: 6)
            }
            slots[probe.entity]?.captured = true
            slots[probe.entity]?.revision = probe.probe.revision
            captures += 1
            Profiler.shared.count("Render.ProbeCaptures")
        } catch {
            Log.error("Render", "Reflection probe prefilter failed: \(error)")
        }
    }
}
#endif
