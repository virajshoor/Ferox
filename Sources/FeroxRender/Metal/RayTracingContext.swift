#if canImport(Metal)
import FeroxAssets
import FeroxCore
import Foundation
import Metal

/// Layout-compatible mirror of `MTLAccelerationStructureInstanceDescriptor` (the
/// `.default` instance descriptor type): a column-major packed 4×3 transform followed by
/// four 32-bit fields, 64 bytes in total. Using plain floats avoids depending on how the
/// packed SIMD types import into Swift.
struct RTInstanceDescriptor {
    var transform: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
    var options: UInt32
    var mask: UInt32
    var intersectionFunctionTableOffset: UInt32
    var accelerationStructureIndex: UInt32

    /// `MTLAccelerationStructureInstanceOptions`: disableTriangleCulling (1) | opaque (4).
    static let opaqueNoCulling: UInt32 = 1 | 4

    init(_ m: Mat4, structure: Int) {
        transform = (m.c0.x, m.c0.y, m.c0.z, m.c1.x, m.c1.y, m.c1.z,
                     m.c2.x, m.c2.y, m.c2.z, m.c3.x, m.c3.y, m.c3.z)
        options = Self.opaqueNoCulling
        mask = 0xFF
        intersectionFunctionTableOffset = 0
        accelerationStructureIndex = UInt32(structure)
    }
}

/// Hybrid ray-traced shadows, ambient occlusion and reflections.
///
/// * **BLAS** — one primitive acceleration structure per mesh, built on first use and
///   stored on the `GPUMesh` (so it is freed when the mesh leaves the cache).
/// * **TLAS** — rebuilt every frame from `RenderFrameData.rayTracingInstances`, one per
///   frame-in-flight slot so a build never overwrites a structure the GPU still reads.
/// * **Effects** — each traces a low-sample signal at `resolutionScale` of the render
///   size, then (optionally) `rtTemporal` accumulates it with motion reprojection and
///   three `rtAtrous` iterations (steps 1, 2, 4) remove the remaining noise.
///
/// Limitations: geometry is opaque, hit shading uses constant per-instance materials,
/// and skinned meshes are excluded (see Docs/08-Ray-Tracing.md).
final class RayTracingContext {
    /// Outputs consumed by the forward pass (nil = effect inactive this frame).
    struct Outputs {
        var shadow: (any MTLTexture)?
        var ambientOcclusion: (any MTLTexture)?
        var reflection: (any MTLTexture)?
    }

    /// Persistent textures of one effect at ray-tracing resolution.
    private final class EffectTargets {
        let raw: any MTLTexture
        let history: [any MTLTexture]
        let scratch: [any MTLTexture]
        var historyIndex = 0
        var historyValid = false
        let bytes: Int

        init(device: any MTLDevice, name: String, format: MTLPixelFormat, width: Int, height: Int) throws {
            func make(_ label: String) throws -> any MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                 mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                guard let t = device.makeTexture(descriptor: d) else { throw RenderError.allocation(label) }
                t.label = label
                return t
            }
            raw = try make("Ferox.RT.\(name).Raw")
            history = try [make("Ferox.RT.\(name).History0"), make("Ferox.RT.\(name).History1")]
            scratch = try [make("Ferox.RT.\(name).Filter0"), make("Ferox.RT.\(name).Filter1")]
            bytes = ([raw] + history + scratch).reduce(0) { $0 + $1.allocatedSize }
        }
    }

    let device: any MTLDevice
    let shaders: ShaderLibrary
    private let maxFramesInFlight: Int
    private var tlas: [(any MTLAccelerationStructure)?]
    private var tlasScratch: [(any MTLBuffer)?]
    private var effects: [String: EffectTargets] = [:]
    private var effectSize = (0, 0)
    private var trackedBytes = 0
    /// Number of BLAS builds (diagnostics and tests).
    private(set) var blasBuilds = 0

    init(device: any MTLDevice, shaders: ShaderLibrary, maxFramesInFlight: Int) {
        self.device = device
        self.shaders = shaders
        self.maxFramesInFlight = max(maxFramesInFlight, 1)
        tlas = Array(repeating: nil, count: self.maxFramesInFlight)
        tlasScratch = Array(repeating: nil, count: self.maxFramesInFlight)
    }

    deinit { MemoryTracker.shared.free("GPU.RayTracing", bytes: trackedBytes) }

    /// Forgets temporal history (camera cut, resize, settings change).
    func resetHistory() {
        for e in effects.values { e.historyValid = false }
    }

    /// Releases every acceleration structure and target (device change, purge).
    func release() {
        MemoryTracker.shared.free("GPU.RayTracing", bytes: trackedBytes)
        trackedBytes = 0
        effects.removeAll()
        effectSize = (0, 0)
        tlas = Array(repeating: nil, count: maxFramesInFlight)
        tlasScratch = Array(repeating: nil, count: maxFramesInFlight)
    }

    private func track(_ bytes: Int) {
        trackedBytes += bytes
        MemoryTracker.shared.allocate("GPU.RayTracing", bytes: bytes)
    }

    // MARK: Acceleration structures

    /// Builds the mesh's BLAS on `cb` if it does not have one yet.
    private func ensureBLAS(_ mesh: GPUMesh, commandBuffer cb: any MTLCommandBuffer) -> (any MTLAccelerationStructure)? {
        if let s = mesh.accelerationStructure { return s }
        guard mesh.indexCount >= 3 else { return nil }
        let g = MTLAccelerationStructureTriangleGeometryDescriptor()
        g.vertexBuffer = mesh.vertexBuffer
        g.vertexBufferOffset = MeshVertexLayout.positionOffset
        g.vertexStride = MeshVertexLayout.stride
        g.vertexFormat = .float3
        g.indexBuffer = mesh.indexBuffer
        g.indexType = .uint32
        g.triangleCount = mesh.indexCount / 3
        g.opaque = true
        let desc = MTLPrimitiveAccelerationStructureDescriptor()
        desc.geometryDescriptors = [g]
        let sizes = device.accelerationStructureSizes(descriptor: desc)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let enc = cb.makeAccelerationStructureCommandEncoder()
        else { return nil }
        structure.label = "Ferox.BLAS"
        enc.build(accelerationStructure: structure, descriptor: desc, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        // The scratch buffer is retained by the command buffer until the build completes.
        mesh.accelerationStructure = structure
        blasBuilds += 1
        Profiler.shared.count("Render.BLASBuilds")
        return structure
    }

    /// Builds this frame's TLAS. Returns the structure and the BLASes it references (they
    /// must be made resident with `useResource` in every encoder that traces rays).
    func buildScene(_ frame: RenderFrameData, slot: Int, meshes: MeshCache, assets: AssetManager, frameIndex: UInt64,
                    allocator: FrameAllocator, commandBuffer cb: any MTLCommandBuffer)
        -> (tlas: any MTLAccelerationStructure, blas: [any MTLAccelerationStructure], materials: BufferSlice?)? {
        var structures: [any MTLAccelerationStructure] = []
        var structureIndex: [ObjectIdentifier: Int] = [:]
        var instances: [RTInstanceDescriptor] = []
        var materials: [RTInstanceMaterial] = []
        for inst in frame.rayTracingInstances {
            guard let mesh = meshes.mesh(inst.mesh, assets: assets, frame: frameIndex),
                  mesh.skinBuffer == nil,  // skinned meshes are excluded (bind pose would be wrong)
                  let blas = ensureBLAS(mesh, commandBuffer: cb) else { continue }
            let id = ObjectIdentifier(blas)
            let index = structureIndex[id] ?? {
                structures.append(blas)
                structureIndex[id] = structures.count - 1
                return structures.count - 1
            }()
            instances.append(RTInstanceDescriptor(inst.transform, structure: index))
            materials.append(inst.material)
        }
        guard !instances.isEmpty, let instanceSlice = allocator.upload(instances) else { return nil }

        let desc = MTLInstanceAccelerationStructureDescriptor()
        desc.instancedAccelerationStructures = structures
        desc.instanceCount = instances.count
        desc.instanceDescriptorBuffer = instanceSlice.buffer
        desc.instanceDescriptorBufferOffset = instanceSlice.offset
        desc.instanceDescriptorStride = MemoryLayout<RTInstanceDescriptor>.stride
        desc.instanceDescriptorType = .default
        let sizes = device.accelerationStructureSizes(descriptor: desc)

        let s = slot % maxFramesInFlight
        // Grow the slot's TLAS and scratch geometrically so instance-count jitter does not
        // reallocate every frame.
        if (tlas[s]?.size ?? 0) < sizes.accelerationStructureSize {
            if let old = tlas[s] { trackedBytes -= old.size; MemoryTracker.shared.free("GPU.RayTracing", bytes: old.size) }
            tlas[s] = device.makeAccelerationStructure(size: sizes.accelerationStructureSize * 3 / 2)
            tlas[s]?.label = "Ferox.TLAS\(s)"
            if let t = tlas[s] { track(t.size) }
        }
        if (tlasScratch[s]?.length ?? 0) < sizes.buildScratchBufferSize {
            if let old = tlasScratch[s] { trackedBytes -= old.length; MemoryTracker.shared.free("GPU.RayTracing", bytes: old.length) }
            tlasScratch[s] = device.makeBuffer(length: max(sizes.buildScratchBufferSize * 3 / 2, 16),
                                               options: .storageModePrivate)
            if let b = tlasScratch[s] { track(b.length) }
        }
        guard let top = tlas[s], let scratch = tlasScratch[s],
              let enc = cb.makeAccelerationStructureCommandEncoder() else { return nil }
        enc.label = "Ferox.BuildTLAS"
        enc.build(accelerationStructure: top, descriptor: desc, scratchBuffer: scratch, scratchBufferOffset: 0)
        enc.endEncoding()
        return (top, structures, allocator.upload(materials))
    }

    // MARK: Effects

    private func targets(_ name: String, format: MTLPixelFormat, width: Int, height: Int) -> EffectTargets? {
        if effectSize != (width, height) {
            MemoryTracker.shared.free("GPU.RayTracing", bytes: effects.values.reduce(0) { $0 + $1.bytes })
            trackedBytes -= effects.values.reduce(0) { $0 + $1.bytes }
            effects.removeAll()
            effectSize = (width, height)
        }
        if let e = effects[name] { return e }
        guard let e = try? EffectTargets(device: device, name: name, format: format, width: width, height: height)
        else { return nil }
        effects[name] = e
        track(e.bytes)
        return e
    }

    /// Traces and denoises the enabled effects. `depth`, `normal` and `motion` are the
    /// resolved prepass targets at render resolution.
    func encodeEffects(_ cb: any MTLCommandBuffer, frame: RenderFrameData, uniforms: FrameUniforms,
                       graphics: ResolvedGraphics, slot: Int, depth: any MTLTexture, normal: any MTLTexture,
                       motion: any MTLTexture, environment: any MTLTexture, resources r: SceneResources) -> Outputs {
        var out = Outputs()
        guard graphics.usesRayTracing,
              let scene = buildScene(frame, slot: slot, meshes: r.meshes, assets: r.assets, frameIndex: r.frameIndex,
                                     allocator: r.allocator, commandBuffer: cb)
        else { return out }
        let rt = graphics.settings.rayTracing
        let scale = min(max(rt.resolutionScale, 0.25), 1)
        let w = max(Int(Float(depth.width) * scale), 1), h = max(Int(Float(depth.height) * scale), 1)

        var u = RTUniforms()
        u.params = Vec4(rt.aoRadius, rt.maxReflectionRoughness, 0.0093, uniforms.exposure.y)
        u.size = SIMD4(UInt32(w), UInt32(h), UInt32(min(max(rt.raysPerPixel, 1), 16)), 0)
        u.depthSize = Vec4(Float(depth.width), Float(depth.height), 1 / Float(w), 1 / Float(h))

        guard let enc = cb.makeComputeCommandEncoder() else { return out }
        enc.label = "Ferox.RayTracing"
        defer { enc.endEncoding() }
        // Instanced BLASes are referenced indirectly through the TLAS, so they must be made
        // resident explicitly.
        for b in scene.blas { enc.useResource(b, usage: .read) }
        enc.setAccelerationStructure(scene.tlas, bufferIndex: 1)
        enc.setValue(uniforms, index: BufferIndex.frame, allocator: r.allocator)

        func run(_ name: String, kernel: String, format: MTLPixelFormat, temporalWeight: Float,
                 bind: (any MTLComputeCommandEncoder, EffectTargets) -> Void) -> (any MTLTexture)? {
            guard let t = targets(name, format: format, width: w, height: h),
                  let trace = try? shaders.computePipeline(kernel) else { return nil }
            var eu = u
            eu.size.w = t.historyValid ? 1 : 0
            eu.denoise.w = temporalWeight
            enc.setValue(eu, index: 0, allocator: r.allocator)
            bind(enc, t)
            enc.dispatch2D(trace, width: w, height: h)
            Profiler.shared.updateRenderCounters { $0.computeDispatches += 1; $0.rayTracingRays += w * h * Int(u.size.z) }
            guard rt.denoise, let temporal = try? shaders.computePipeline("rtTemporal"),
                  let atrous = try? shaders.computePipeline("rtAtrous") else { return t.raw }

            let current = t.history[t.historyIndex], previous = t.history[t.historyIndex ^ 1]
            enc.setTexture(t.raw, index: 0)
            enc.setTexture(previous, index: 1)
            enc.setTexture(motion, index: 2)
            enc.setTexture(current, index: 3)
            enc.dispatch2D(temporal, width: w, height: h)

            // À-trous: history → scratch0 → scratch1 → scratch0 with steps 1, 2, 4.
            var input = current
            for (i, step) in [1, 2, 4].enumerated() {
                var fu = eu
                fu.denoise.x = Float(step)
                enc.setValue(fu, index: 0, allocator: r.allocator)
                let output = t.scratch[i % 2]
                enc.setTexture(input, index: 0)
                enc.setTexture(depth, index: 1)
                enc.setTexture(normal, index: 2)
                enc.setTexture(output, index: 3)
                enc.dispatch2D(atrous, width: w, height: h)
                input = output
            }
            t.historyIndex ^= 1
            t.historyValid = true
            Profiler.shared.updateRenderCounters { $0.computeDispatches += 4 }
            return input
        }

        if graphics.rayTracedShadows, frame.sun != nil {
            out.shadow = run("Shadow", kernel: "rtShadows", format: .r16Float, temporalWeight: 0.2) { enc, t in
                enc.setTexture(depth, index: 0)
                enc.setTexture(normal, index: 1)
                enc.setTexture(t.raw, index: 2)
            }
        }
        if graphics.rayTracedAO {
            out.ambientOcclusion = run("AO", kernel: "rtAO", format: .r16Float, temporalWeight: 0.1) { enc, t in
                enc.setTexture(depth, index: 0)
                enc.setTexture(normal, index: 1)
                enc.setTexture(t.raw, index: 2)
            }
        }
        if graphics.rayTracedReflections, let mats = scene.materials {
            out.reflection = run("Reflection", kernel: "rtReflections", format: .rgba16Float, temporalWeight: 0.15) { enc, t in
                enc.setSlice(mats, index: 3)
                enc.setTexture(depth, index: 0)
                enc.setTexture(normal, index: 1)
                enc.setTexture(environment, index: 2)
                enc.setTexture(t.raw, index: 3)
            }
        }
        return out
    }
}
#endif
