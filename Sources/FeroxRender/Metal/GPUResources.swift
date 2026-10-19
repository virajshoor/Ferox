#if canImport(Metal)
import FeroxAssets
import FeroxCore
import Foundation
import Metal

// GPU resource management for the Metal backend:
//
//  • `FrameAllocator`  — per-frame bump allocator for transient constant/vertex data.
//  • `TexturePool`     — recycles transient render targets between frames.
//  • `GPUUploader`     — creates immutable buffers (shared on unified memory, otherwise
//                        staged into private storage with a blit).
//  • `MeshCache`       — interleaves `MeshData` into the 72-byte vertex layout and keeps it
//                        resident while it is drawn.
//  • `TextureCache`    — turns decoded `ImageData` into `MTLTexture`s, with mipmaps.
//  • `SamplerSet`      — the handful of sampler states every pass shares.
//  • `FallbackTextures`— 1×1 placeholders so every shader slot is always bound.
//  • `MaterialBinder`  — resolves a material asset into uniforms and textures for a draw.
//
// None of these types is thread-safe; the renderer uses them from the thread that encodes
// the frame. Caches never hold strong `AssetHandle` references, so they do not stop the
// asset manager from evicting assets under memory pressure; instead they compare handle
// revisions to detect reloads.

/// A sub-range of a Metal buffer.
public struct BufferSlice {
    public let buffer: any MTLBuffer
    public let offset: Int
    public let length: Int
}

// MARK: - Frame allocator

/// Bump allocator for data that lives for one frame (instance arrays, light lists,
/// uniforms larger than the 4 KB `setBytes` limit, 2D/UI vertex streams).
///
/// The renderer owns one allocator per frame in flight and calls `reset()` only after the
/// GPU has finished the frame that last used it (guarded by the frames-in-flight
/// semaphore), so CPU writes never race GPU reads.
final class FrameAllocator {
    /// Offsets are aligned to 256 bytes, the strictest constant-buffer alignment Metal
    /// requires on any Mac GPU.
    static let alignment = 256

    let device: any MTLDevice
    let blockSize: Int
    private let label: String
    private var blocks: [any MTLBuffer] = []
    private var blockIndex = 0
    private var offset = 0
    /// Bytes handed out since the last reset (for statistics).
    private(set) var usedBytes = 0

    init(device: any MTLDevice, blockSize: Int = 4 << 20, label: String) {
        self.device = device
        self.blockSize = blockSize
        self.label = label
    }

    deinit {
        for b in blocks { MemoryTracker.shared.free("GPU.FrameAllocator", bytes: b.length) }
    }

    /// Makes every block available again. Blocks beyond the first four that were not needed
    /// in the frame just finished are released so a one-off spike does not pin memory.
    func reset() {
        let needed = max(blockIndex + 1, 4)
        if blocks.count > needed {
            for b in blocks[needed...] { MemoryTracker.shared.free("GPU.FrameAllocator", bytes: b.length) }
            blocks.removeSubrange(needed...)
        }
        blockIndex = 0
        offset = 0
        usedBytes = 0
    }

    private func makeBlock(length: Int) -> (any MTLBuffer)? {
        guard let b = device.makeBuffer(length: length, options: [.storageModeShared, .cpuCacheModeWriteCombined])
        else { return nil }
        b.label = "\(label).block\(blocks.count)"
        MemoryTracker.shared.allocate("GPU.FrameAllocator", bytes: b.length)
        return b
    }

    /// Reserves `length` bytes. Returns nil only if Metal cannot allocate memory.
    func allocate(length: Int) -> BufferSlice? {
        let length = max(length, 1)
        let aligned = (length + Self.alignment - 1) / Self.alignment * Self.alignment
        // Oversized requests get a dedicated block appended after the current one.
        if aligned > blockSize {
            guard let b = makeBlock(length: aligned) else { return nil }
            blocks.insert(b, at: min(blockIndex + 1, blocks.count))
            blockIndex = min(blockIndex + 1, blocks.count - 1)
            offset = aligned
            usedBytes += aligned
            return BufferSlice(buffer: b, offset: 0, length: length)
        }
        if blocks.isEmpty {
            guard let b = makeBlock(length: blockSize) else { return nil }
            blocks.append(b)
        }
        if offset + aligned > blocks[blockIndex].length {
            blockIndex += 1
            offset = 0
            if blockIndex >= blocks.count {
                guard let b = makeBlock(length: blockSize) else { return nil }
                blocks.append(b)
            } else if blocks[blockIndex].length < aligned {
                // A dedicated (oversized) block from an earlier frame is fine to reuse; a
                // too-small one cannot occur because normal blocks are `blockSize` long.
                guard let b = makeBlock(length: blockSize) else { return nil }
                blocks.insert(b, at: blockIndex)
            }
        }
        let slice = BufferSlice(buffer: blocks[blockIndex], offset: offset, length: length)
        offset += aligned
        usedBytes += aligned
        return slice
    }

    /// Copies an array into frame memory.
    func upload<T>(_ array: [T]) -> BufferSlice? {
        let length = MemoryLayout<T>.stride * array.count
        guard let s = allocate(length: length) else { return nil }
        array.withUnsafeBytes { src in
            if let base = src.baseAddress, length > 0 {
                s.buffer.contents().advanced(by: s.offset).copyMemory(from: base, byteCount: length)
            }
        }
        return s
    }

    /// Copies a single value into frame memory.
    func upload<T>(value: T) -> BufferSlice? {
        guard let s = allocate(length: MemoryLayout<T>.stride) else { return nil }
        withUnsafeBytes(of: value) { src in
            if let base = src.baseAddress {
                s.buffer.contents().advanced(by: s.offset).copyMemory(from: base, byteCount: src.count)
            }
        }
        return s
    }
}

// MARK: - Constant binding helpers

extension MTLRenderCommandEncoder {
    /// Binds a value as vertex constants, using `setVertexBytes` below Metal's 4 KB limit.
    func setVertexValue<T>(_ value: T, index: Int, allocator: FrameAllocator) {
        let size = MemoryLayout<T>.stride
        if size <= 4096 {
            withUnsafeBytes(of: value) { setVertexBytes($0.baseAddress!, length: $0.count, index: index) }
        } else if let s = allocator.upload(value: value) {
            setVertexBuffer(s.buffer, offset: s.offset, index: index)
        }
    }

    /// Binds a value as fragment constants, using `setFragmentBytes` below the 4 KB limit.
    func setFragmentValue<T>(_ value: T, index: Int, allocator: FrameAllocator) {
        let size = MemoryLayout<T>.stride
        if size <= 4096 {
            withUnsafeBytes(of: value) { setFragmentBytes($0.baseAddress!, length: $0.count, index: index) }
        } else if let s = allocator.upload(value: value) {
            setFragmentBuffer(s.buffer, offset: s.offset, index: index)
        }
    }

    func setVertexSlice(_ s: BufferSlice?, index: Int) {
        if let s { setVertexBuffer(s.buffer, offset: s.offset, index: index) }
    }

    func setFragmentSlice(_ s: BufferSlice?, index: Int) {
        if let s { setFragmentBuffer(s.buffer, offset: s.offset, index: index) }
    }
}

extension MTLComputeCommandEncoder {
    func setValue<T>(_ value: T, index: Int, allocator: FrameAllocator) {
        let size = MemoryLayout<T>.stride
        if size <= 4096 {
            withUnsafeBytes(of: value) { setBytes($0.baseAddress!, length: $0.count, index: index) }
        } else if let s = allocator.upload(value: value) {
            setBuffer(s.buffer, offset: s.offset, index: index)
        }
    }

    func setSlice(_ s: BufferSlice?, index: Int) {
        if let s { setBuffer(s.buffer, offset: s.offset, index: index) }
    }

    /// Binds `pipeline` and dispatches enough threadgroups to cover `width`×`height` threads.
    func dispatch2D(_ pipeline: any MTLComputePipelineState, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(pipeline.maxTotalThreadsPerThreadgroup / w, 1)
        let group = MTLSize(width: w, height: min(h, 8), depth: 1)
        let grid = MTLSize(width: RenderMath.groups(width, group.width), height: RenderMath.groups(height, group.height),
                           depth: 1)
        dispatchThreadgroups(grid, threadsPerThreadgroup: group)
    }

    /// Binds `pipeline` and covers `width`×`height`×`depth` threads, with `depth` mapped to
    /// whole threadgroup layers (cube faces, array slices).
    func dispatch3D(_ pipeline: any MTLComputePipelineState, width: Int, height: Int, depth: Int) {
        guard width > 0, height > 0, depth > 0 else { return }
        setComputePipelineState(pipeline)
        let w = min(8, pipeline.threadExecutionWidth)
        let h = max(min(pipeline.maxTotalThreadsPerThreadgroup / w, 8), 1)
        let group = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: RenderMath.groups(width, w), height: RenderMath.groups(height, h), depth: depth)
        dispatchThreadgroups(grid, threadsPerThreadgroup: group)
    }

    /// Binds `pipeline` and dispatches enough threadgroups to cover `count` threads in one
    /// dimension.
    func dispatch1D(_ pipeline: any MTLComputePipelineState, count: Int, groupSize: Int? = nil) {
        guard count > 0 else { return }
        setComputePipelineState(pipeline)
        let g = min(groupSize ?? pipeline.threadExecutionWidth * 2, pipeline.maxTotalThreadsPerThreadgroup)
        dispatchThreadgroups(MTLSize(width: RenderMath.groups(count, g), height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: g, height: 1, depth: 1))
    }
}

// MARK: - Texture pool

/// Description of a pooled texture. Two requests with equal keys may share a texture
/// across (but never within) frames.
struct TextureKey: Hashable {
    var width: Int
    var height: Int
    var format: MTLPixelFormat
    var usage: MTLTextureUsage.RawValue
    var sampleCount = 1
    var mipLevels = 1
    var arrayLength = 1
    var type: MTLTextureType = .type2D
    var memoryless = false

    init(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage, sampleCount: Int = 1,
         mipLevels: Int = 1, arrayLength: Int = 1, type: MTLTextureType = .type2D, memoryless: Bool = false) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.format = format
        self.usage = usage.rawValue
        self.sampleCount = max(sampleCount, 1)
        self.mipLevels = max(mipLevels, 1)
        self.arrayLength = max(arrayLength, 1)
        self.type = sampleCount > 1 ? .type2DMultisample : type
        self.memoryless = memoryless
    }

    func descriptor() -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.textureType = type
        d.pixelFormat = format
        d.width = width
        d.height = height
        d.sampleCount = sampleCount
        d.mipmapLevelCount = mipLevels
        d.arrayLength = arrayLength
        d.usage = MTLTextureUsage(rawValue: usage)
        d.storageMode = memoryless ? .memoryless : .private
        return d
    }
}

/// Recycles transient textures (intermediate post-processing targets, MSAA attachments,
/// SSAO buffers) between frames.
///
/// Reusing a texture in the next frame while the GPU may still be reading it in the
/// previous one is safe: pooled textures are allocated from the device (not a heap), so
/// Metal tracks their hazards, and all work is submitted to one ordered queue.
final class TexturePool {
    private struct Entry {
        let texture: any MTLTexture
        var lastUsedFrame: UInt64
    }

    let device: any MTLDevice
    /// Textures unused for this many frames are released (e.g. after a resize).
    var maxIdleFrames: UInt64 = 60
    private var free: [TextureKey: [Entry]] = [:]
    private var inUse: [(TextureKey, Entry)] = []
    private var frame: UInt64 = 0
    private(set) var allocatedBytes = 0

    init(device: any MTLDevice) { self.device = device }

    deinit { MemoryTracker.shared.free("GPU.TexturePool", bytes: allocatedBytes) }

    /// Returns a texture matching `key` for use during the current frame.
    func texture(_ key: TextureKey, label: String) -> (any MTLTexture)? {
        if var list = free[key], let e = list.popLast() {
            free[key] = list.isEmpty ? nil : list
            e.texture.label = label
            inUse.append((key, Entry(texture: e.texture, lastUsedFrame: frame)))
            return e.texture
        }
        guard let t = device.makeTexture(descriptor: key.descriptor()) else {
            Log.error("Render", "Texture pool allocation failed: \(key.width)x\(key.height) \(key.format.rawValue)")
            return nil
        }
        t.label = label
        allocatedBytes += t.allocatedSize
        MemoryTracker.shared.allocate("GPU.TexturePool", bytes: t.allocatedSize)
        inUse.append((key, Entry(texture: t, lastUsedFrame: frame)))
        return t
    }

    /// Returns this frame's textures to the free lists and releases stale ones.
    func endFrame() {
        for (k, e) in inUse { free[k, default: []].append(e) }
        inUse.removeAll(keepingCapacity: true)
        frame += 1
        for (k, list) in free {
            let keep = list.filter { frame - $0.lastUsedFrame <= maxIdleFrames }
            if keep.count != list.count {
                for e in list where frame - e.lastUsedFrame > maxIdleFrames {
                    allocatedBytes -= e.texture.allocatedSize
                    MemoryTracker.shared.free("GPU.TexturePool", bytes: e.texture.allocatedSize)
                }
                free[k] = keep.isEmpty ? nil : keep
            }
        }
    }

    /// Releases every free texture (on resize or memory warning).
    func purge() {
        for list in free.values {
            for e in list {
                allocatedBytes -= e.texture.allocatedSize
                MemoryTracker.shared.free("GPU.TexturePool", bytes: e.texture.allocatedSize)
            }
        }
        free.removeAll()
    }

    var pooledTextureCount: Int { free.values.reduce(0) { $0 + $1.count } + inUse.count }
}

// MARK: - Static uploads

/// Creates immutable GPU buffers. On unified-memory GPUs (all Apple Silicon) a shared
/// buffer is already in GPU-visible memory, so no copy is needed. On discrete GPUs data is
/// staged and blitted into private storage; the queue orders the blit before any use.
final class GPUUploader {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let unifiedMemory: Bool

    init(device: any MTLDevice, queue: any MTLCommandQueue, unifiedMemory: Bool) {
        self.device = device
        self.queue = queue
        self.unifiedMemory = unifiedMemory
    }

    func makeBuffer(bytes: UnsafeRawPointer, length: Int, label: String) -> (any MTLBuffer)? {
        guard length > 0 else { return nil }
        if unifiedMemory {
            let b = device.makeBuffer(bytes: bytes, length: length, options: .storageModeShared)
            b?.label = label
            return b
        }
        guard let staging = device.makeBuffer(bytes: bytes, length: length, options: .storageModeShared),
              let dst = device.makeBuffer(length: length, options: .storageModePrivate),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        dst.label = label
        cb.label = "Ferox.Upload \(label)"
        blit.copy(from: staging, sourceOffset: 0, to: dst, destinationOffset: 0, size: length)
        blit.endEncoding()
        cb.commit()  // `staging` is retained by the command buffer until it completes.
        return dst
    }

    func makeBuffer<T>(_ array: [T], label: String) -> (any MTLBuffer)? {
        array.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return makeBuffer(bytes: base, length: raw.count, label: label)
        }
    }
}

// MARK: - Mesh cache

/// GPU copy of a `MeshData`.
final class GPUMesh {
    let vertexBuffer: any MTLBuffer
    /// Joints/weights stream (buffer 1), present for skinned meshes only.
    let skinBuffer: (any MTLBuffer)?
    let indexBuffer: any MTLBuffer
    let indexCount: Int
    let submeshes: [MeshData.Submesh]
    let vertexCount: Int
    let revision: UInt64
    var lastUsedFrame: UInt64 = 0
    /// Bottom-level acceleration structure, built lazily when ray tracing is enabled.
    var accelerationStructure: (any MTLAccelerationStructure)?
    let byteCount: Int

    init(vertexBuffer: any MTLBuffer, skinBuffer: (any MTLBuffer)?, indexBuffer: any MTLBuffer, indexCount: Int,
         submeshes: [MeshData.Submesh], vertexCount: Int, revision: UInt64) {
        self.vertexBuffer = vertexBuffer
        self.skinBuffer = skinBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indexCount
        self.submeshes = submeshes
        self.vertexCount = vertexCount
        self.revision = revision
        byteCount = vertexBuffer.length + (skinBuffer?.length ?? 0) + indexBuffer.length
    }

    /// The index range of submesh `i` (the whole mesh when there are no submeshes).
    func range(ofSubmesh i: Int) -> (offset: Int, count: Int) {
        guard !submeshes.isEmpty else { return (0, indexCount) }
        let s = submeshes[min(max(i, 0), submeshes.count - 1)]
        let offset = min(max(s.indexOffset, 0), indexCount)
        return (offset, min(max(s.indexCount, 0), indexCount - offset))
    }
}

/// Uploads meshes on first use and keeps them while they are drawn.
final class MeshCache {
    let uploader: GPUUploader
    /// Meshes not drawn for this many frames are released (about ten seconds at 60 Hz).
    var maxIdleFrames: UInt64 = 600
    private var meshes: [AssetID: GPUMesh] = [:]
    private(set) var residentBytes = 0
    /// Incremented when a mesh is (re)uploaded so the ray-tracing context can rebuild.
    private(set) var generation: UInt64 = 0

    init(uploader: GPUUploader) { self.uploader = uploader }

    deinit { MemoryTracker.shared.free("GPU.Meshes", bytes: residentBytes) }

    var count: Int { meshes.count }

    /// The GPU mesh for `id`, uploading (or re-uploading after a hot reload) as needed.
    /// Returns nil while the asset is not loaded.
    func mesh(_ id: AssetID, assets: AssetManager, frame: UInt64) -> GPUMesh? {
        guard let handle = assets.mesh(id), let data = handle.value else { return nil }
        if let m = meshes[id], m.revision == handle.revision {
            m.lastUsedFrame = frame
            return m
        }
        guard let m = upload(data, revision: handle.revision, label: data.name.isEmpty ? id.rawValue : data.name) else {
            return nil
        }
        if let old = meshes[id] { release(old) }
        m.lastUsedFrame = frame
        meshes[id] = m
        residentBytes += m.byteCount
        MemoryTracker.shared.allocate("GPU.Meshes", bytes: m.byteCount)
        generation &+= 1
        return m
    }

    /// Already-uploaded mesh without touching the asset manager (ray-tracing builds).
    func resident(_ id: AssetID) -> GPUMesh? { meshes[id] }

    private func release(_ m: GPUMesh) {
        residentBytes -= m.byteCount
        MemoryTracker.shared.free("GPU.Meshes", bytes: m.byteCount)
    }

    /// Releases meshes that have not been drawn recently.
    func evict(frame: UInt64) {
        for (id, m) in meshes where frame > m.lastUsedFrame + maxIdleFrames {
            release(m)
            meshes[id] = nil
            generation &+= 1
        }
    }

    func removeAll() {
        for m in meshes.values { release(m) }
        meshes.removeAll()
        generation &+= 1
    }

    /// Interleaves the mesh into `MeshVertexLayout` (18 floats per vertex) with defaults
    /// for missing attributes: normal +Y, tangent +X (w = 1), colour white.
    static func interleave(_ d: MeshData) -> [Float] {
        let n = d.positions.count
        let floatsPerVertex = MeshVertexLayout.stride / 4
        var v = [Float](repeating: 0, count: n * floatsPerVertex)
        let hasN = d.normals.count == n, hasT = d.tangents.count == n
        let hasUV0 = d.uv0.count == n, hasUV1 = d.uv1.count == n, hasC = d.colors.count == n
        for i in 0..<n {
            let o = i * floatsPerVertex
            let p = d.positions[i]
            v[o] = p.x; v[o + 1] = p.y; v[o + 2] = p.z
            let nn = hasN ? d.normals[i] : Vec3(0, 1, 0)
            v[o + 3] = nn.x; v[o + 4] = nn.y; v[o + 5] = nn.z
            let t = hasT ? d.tangents[i] : Vec4(1, 0, 0, 1)
            v[o + 6] = t.x; v[o + 7] = t.y; v[o + 8] = t.z; v[o + 9] = t.w
            let a = hasUV0 ? d.uv0[i] : .zero
            v[o + 10] = a.x; v[o + 11] = a.y
            let b = hasUV1 ? d.uv1[i] : a
            v[o + 12] = b.x; v[o + 13] = b.y
            let c = hasC ? d.colors[i] : Vec4(1, 1, 1, 1)
            v[o + 14] = c.x; v[o + 15] = c.y; v[o + 16] = c.z; v[o + 17] = c.w
        }
        return v
    }

    /// Packs the skin stream: two words of joint indices (ushort4) then four float weights.
    static func packSkin(_ d: MeshData) -> [UInt32] {
        let n = d.positions.count
        var out = [UInt32](repeating: 0, count: n * 6)
        for i in 0..<n {
            let j = d.joints[i]
            var w = d.weights.count == n ? d.weights[i] : Vec4(1, 0, 0, 0)
            let sum = w.x + w.y + w.z + w.w
            w = sum > 1e-6 ? w / sum : Vec4(1, 0, 0, 0)  // normalise so the vertex keeps its size
            let o = i * 6
            out[o] = UInt32(j.x) | (UInt32(j.y) << 16)
            out[o + 1] = UInt32(j.z) | (UInt32(j.w) << 16)
            out[o + 2] = w.x.bitPattern
            out[o + 3] = w.y.bitPattern
            out[o + 4] = w.z.bitPattern
            out[o + 5] = w.w.bitPattern
        }
        return out
    }

    private func upload(_ d: MeshData, revision: UInt64, label: String) -> GPUMesh? {
        guard !d.positions.isEmpty, !d.indices.isEmpty else { return nil }
        // Out-of-range indices would read outside the vertex buffer; `MeshData.validate()`
        // rejects them at import, but procedural meshes bypass the importer.
        let n = UInt32(d.positions.count)
        guard d.indices.allSatisfy({ $0 < n }) else {
            Log.error("Render", "Mesh '\(label)' has out-of-range indices; not uploaded")
            return nil
        }
        guard let vb = uploader.makeBuffer(Self.interleave(d), label: "\(label).vertices"),
              let ib = uploader.makeBuffer(d.indices, label: "\(label).indices") else { return nil }
        let sb = d.isSkinned ? uploader.makeBuffer(Self.packSkin(d), label: "\(label).skin") : nil
        return GPUMesh(vertexBuffer: vb, skinBuffer: sb, indexBuffer: ib, indexCount: d.indices.count,
                       submeshes: d.submeshes, vertexCount: d.positions.count, revision: revision)
    }
}

// MARK: - Texture cache

/// Converts decoded images into Metal textures on first use.
final class TextureCache {
    private struct Key: Hashable {
        var id: AssetID
        var srgb: Bool
    }
    private struct Entry {
        let texture: any MTLTexture
        let revision: UInt64
        var lastUsedFrame: UInt64
    }

    let device: any MTLDevice
    let capabilities: DeviceCapabilities
    var maxIdleFrames: UInt64 = 600
    private var entries: [Key: Entry] = [:]
    /// Textures whose mip chain must be generated on the GPU before first use.
    private var pendingMipmaps: [any MTLTexture] = []
    /// Discrete-GPU uploads: a shared staging buffer blitted into a private texture.
    private struct StagedUpload {
        var buffer: any MTLBuffer
        var bytesPerRow: Int
        var bytesPerImage: Int
        var width: Int
        var height: Int
        var texture: any MTLTexture
        var slice: Int
        var level: Int
    }
    private var stagedUploads: [StagedUpload] = []
    private(set) var residentBytes = 0

    init(device: any MTLDevice, capabilities: DeviceCapabilities) {
        self.device = device
        self.capabilities = capabilities
    }

    deinit { MemoryTracker.shared.free("GPU.Textures", bytes: residentBytes) }

    var count: Int { entries.count }

    /// The texture for `id`, or nil while it is loading (callers bind a fallback).
    /// Requesting a texture starts its load and marks it as recently used.
    func texture(_ id: AssetID, srgb: Bool, assets: AssetManager, frame: UInt64) -> (any MTLTexture)? {
        let handle = assets.texture(id, srgb: srgb)
        guard handle.state == .loaded, let image = handle.value else { return nil }
        let key = Key(id: id, srgb: srgb)
        if var e = entries[key], e.revision == handle.revision {
            e.lastUsedFrame = frame
            entries[key] = e
            return e.texture
        }
        guard let t = makeTexture(image, srgb: srgb, label: id.rawValue) else { return nil }
        if let old = entries[key] { release(old.texture) }
        entries[key] = Entry(texture: t, revision: handle.revision, lastUsedFrame: frame)
        residentBytes += t.allocatedSize
        MemoryTracker.shared.allocate("GPU.Textures", bytes: t.allocatedSize)
        return t
    }

    private func release(_ t: any MTLTexture) {
        residentBytes -= t.allocatedSize
        MemoryTracker.shared.free("GPU.Textures", bytes: t.allocatedSize)
    }

    func evict(frame: UInt64) {
        for (k, e) in entries where frame > e.lastUsedFrame + maxIdleFrames {
            release(e.texture)
            entries[k] = nil
        }
    }

    func removeAll() {
        for e in entries.values { release(e.texture) }
        entries.removeAll()
        pendingMipmaps.removeAll()
        stagedUploads.removeAll()
    }

    /// Encodes mipmap generation for textures created since the last call. Must run before
    /// any pass samples them; the renderer calls it first in every frame.
    func encodePendingWork(_ cb: any MTLCommandBuffer) {
        guard !pendingMipmaps.isEmpty || !stagedUploads.isEmpty, let blit = cb.makeBlitCommandEncoder() else { return }
        blit.label = "Ferox.Mipmaps"
        for u in stagedUploads {
            blit.copy(from: u.buffer, sourceOffset: 0, sourceBytesPerRow: u.bytesPerRow,
                      sourceBytesPerImage: u.bytesPerImage,
                      sourceSize: MTLSize(width: u.width, height: u.height, depth: 1),
                      to: u.texture, destinationSlice: u.slice, destinationLevel: u.level,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        stagedUploads.removeAll()
        for t in pendingMipmaps { blit.generateMipmaps(for: t) }
        blit.endEncoding()
        pendingMipmaps.removeAll()
    }

    static func pixelFormat(_ f: PixelFormat, srgb: Bool) -> MTLPixelFormat {
        switch f {
        case .rgba8Unorm: return srgb ? .rgba8Unorm_srgb : .rgba8Unorm
        case .rgba8UnormSRGB: return srgb ? .rgba8Unorm_srgb : .rgba8Unorm
        case .rgba16Float: return .rgba16Float
        case .rgba32Float: return .rgba32Float
        case .r8Unorm: return .r8Unorm
        case .rg8Unorm: return .rg8Unorm
        }
    }

    /// Creates a texture from decoded pixels. Unified memory writes a shared texture in
    /// place. A discrete GPU gets a private texture filled by a staging blit (see
    /// `GPUTextureUpload`), so the GPU never samples a managed texture that was only
    /// `replace`d.
    func makeTexture(_ image: ImageData, srgb: Bool, label: String) -> (any MTLTexture)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        let format = Self.pixelFormat(image.format, srgb: srgb)
        let bpp = image.format.bytesPerPixel
        // 32-bit float textures can only be filtered (and so mipmapped) on some GPUs.
        let canFilter = image.format != .rgba32Float || capabilities.supports32BitFloatFiltering
        let fullChain = RenderMath.mipCount(w, h)
        let providedMips = image.isCubemap ? 0 : image.mips.count
        let levels = canFilter ? (providedMips > 0 ? min(providedMips + 1, fullChain) : fullChain) : 1

        let d = MTLTextureDescriptor()
        d.textureType = image.isCubemap ? .typeCube : .type2D
        d.pixelFormat = format
        d.width = w
        d.height = image.isCubemap ? w : h
        d.mipmapLevelCount = levels
        d.usage = .shaderRead
        let stage = GPUTextureUpload.path(unifiedMemory: capabilities.hasUnifiedMemory) == .stagingBlitToPrivate
        d.storageMode = stage ? .private : .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = label

        func upload(_ data: Data, level: Int, slice: Int, width: Int, height: Int) -> Bool {
            let rowBytes = width * bpp
            let length = rowBytes * height
            guard data.count >= length else { return false }
            if stage {
                guard let staging = device.makeBuffer(length: length, options: .storageModeShared) else { return false }
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    staging.contents().copyMemory(from: base, byteCount: length)
                }
                stagedUploads.append(StagedUpload(buffer: staging, bytesPerRow: rowBytes, bytesPerImage: length,
                                                  width: width, height: height, texture: t, slice: slice, level: level))
                return true
            }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level, slice: slice,
                          withBytes: base, bytesPerRow: rowBytes, bytesPerImage: length)
            }
            return true
        }

        if image.isCubemap {
            for (i, face) in image.faces.enumerated() where !upload(face, level: 0, slice: i, width: w, height: w) {
                Log.error("Render", "Cubemap '\(label)' face \(i) is truncated")
                return nil
            }
        } else {
            guard upload(image.pixels, level: 0, slice: 0, width: w, height: h) else {
                Log.error("Render", "Texture '\(label)' pixel data is truncated")
                return nil
            }
            if providedMips > 0 {
                var mw = w, mh = h
                for (i, m) in image.mips.prefix(levels - 1).enumerated() {
                    mw = max(mw / 2, 1)
                    mh = max(mh / 2, 1)
                    if !upload(m, level: i + 1, slice: 0, width: mw, height: mh) { break }
                }
            }
        }
        if levels > 1 && providedMips == 0 { pendingMipmaps.append(t) }
        return t
    }
}

// MARK: - Samplers

/// Sampler states shared by all passes.
final class SamplerSet {
    let anisotropicRepeat: any MTLSamplerState
    let linearRepeat: any MTLSamplerState
    let linearClamp: any MTLSamplerState
    let nearestClamp: any MTLSamplerState
    let nearestRepeat: any MTLSamplerState
    /// Hardware depth comparison (`less`, standard-Z shadow maps) with bilinear PCF.
    let shadowCompare: any MTLSamplerState

    init(device: any MTLDevice, anisotropy: Int) throws {
        func make(_ configure: (MTLSamplerDescriptor) -> Void) throws -> any MTLSamplerState {
            let d = MTLSamplerDescriptor()
            configure(d)
            guard let s = device.makeSamplerState(descriptor: d) else { throw RenderError.allocation("sampler") }
            return s
        }
        anisotropicRepeat = try make {
            $0.minFilter = .linear; $0.magFilter = .linear; $0.mipFilter = .linear
            $0.sAddressMode = .repeat; $0.tAddressMode = .repeat
            $0.maxAnisotropy = min(max(anisotropy, 1), 16)
            $0.label = "Ferox.AnisotropicRepeat"
        }
        linearRepeat = try make {
            $0.minFilter = .linear; $0.magFilter = .linear; $0.mipFilter = .linear
            $0.sAddressMode = .repeat; $0.tAddressMode = .repeat
            $0.label = "Ferox.LinearRepeat"
        }
        linearClamp = try make {
            $0.minFilter = .linear; $0.magFilter = .linear; $0.mipFilter = .linear
            $0.sAddressMode = .clampToEdge; $0.tAddressMode = .clampToEdge; $0.rAddressMode = .clampToEdge
            $0.label = "Ferox.LinearClamp"
        }
        nearestClamp = try make {
            $0.minFilter = .nearest; $0.magFilter = .nearest; $0.mipFilter = .nearest
            $0.sAddressMode = .clampToEdge; $0.tAddressMode = .clampToEdge
            $0.label = "Ferox.NearestClamp"
        }
        nearestRepeat = try make {
            $0.minFilter = .nearest; $0.magFilter = .nearest; $0.mipFilter = .nearest
            $0.sAddressMode = .repeat; $0.tAddressMode = .repeat
            $0.label = "Ferox.NearestRepeat"
        }
        shadowCompare = try make {
            $0.minFilter = .linear; $0.magFilter = .linear
            $0.sAddressMode = .clampToEdge; $0.tAddressMode = .clampToEdge
            $0.compareFunction = .less
            $0.label = "Ferox.ShadowCompare"
        }
    }
}

// MARK: - Fallback textures

/// 1×1 placeholders bound to every texture slot a draw does not otherwise fill, so shaders
/// never read an unbound texture (undefined behaviour in Metal).
final class FallbackTextures {
    /// Opaque white (RGBA8): material textures, AO = 1 (unoccluded), RT shadow = 1 (lit).
    let white: any MTLTexture
    /// Transparent black: RT reflections with zero weight.
    let clear: any MTLTexture
    /// Black cube for missing environment maps.
    let blackCube: any MTLTexture
    /// One-element cube array for scenes without reflection probes.
    let cubeArray: any MTLTexture
    /// One-slice depth array cleared to 1 (standard-Z far plane) = never in shadow.
    let shadowArray: any MTLTexture
    /// 1×1 `r32Float` bound when the Hi-Z pyramid is not allocated (occlusion culling off).
    /// The cull kernel's texture argument is `texture2d<float, access::read>`, which rejects
    /// the RGBA8 white placeholder.
    let hiz: any MTLTexture

    init(device: any MTLDevice, queue: any MTLCommandQueue) throws {
        func make(_ type: MTLTextureType, _ format: MTLPixelFormat, storage: MTLStorageMode = .shared,
                  usage: MTLTextureUsage = .shaderRead, array: Int = 1, label: String) throws -> any MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = type
            d.pixelFormat = format
            d.width = 1
            d.height = 1
            d.arrayLength = array
            d.usage = usage
            d.storageMode = storage
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.allocation(label) }
            t.label = label
            return t
        }
        func fill(_ t: any MTLTexture, _ bytes: [UInt8], slices: Int) {
            for s in 0..<slices {
                bytes.withUnsafeBytes {
                    t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: s, withBytes: $0.baseAddress!,
                              bytesPerRow: 4, bytesPerImage: 4)
                }
            }
        }
        // Shared storage is valid for colour textures on every Mac GPU since macOS 10.15
        // except some discrete GPUs; `.managed` is the portable choice there.
        let unified = device.hasUnifiedMemory
        let colorStorage: MTLStorageMode = unified ? .shared : .managed
        white = try make(.type2D, .rgba8Unorm, storage: colorStorage, label: "Ferox.Fallback.White")
        fill(white, [255, 255, 255, 255], slices: 1)
        clear = try make(.type2D, .rgba8Unorm, storage: colorStorage, label: "Ferox.Fallback.Clear")
        fill(clear, [0, 0, 0, 0], slices: 1)
        blackCube = try make(.typeCube, .rgba8Unorm, storage: colorStorage, label: "Ferox.Fallback.BlackCube")
        fill(blackCube, [0, 0, 0, 255], slices: 6)
        cubeArray = try make(.typeCubeArray, .rgba8Unorm, storage: colorStorage, label: "Ferox.Fallback.CubeArray")
        fill(cubeArray, [0, 0, 0, 255], slices: 6)
        // Fill through a local. A closure that reads `hiz` captures `self` before `shadowArray` is set.
        let hizTexture = try make(.type2D, .r32Float, storage: colorStorage, label: "Ferox.Fallback.HiZ")
        let farDepth: Float = 0  // reverse-Z far: a sample (if occlusion is wrongly left on) stays conservative
        withUnsafeBytes(of: farDepth) { raw in
            hizTexture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                bytesPerRow: 4, bytesPerImage: 4)
        }
        hiz = hizTexture
        // Depth textures must be private; clear it with a render pass.
        shadowArray = try make(.type2DArray, .depth32Float, storage: .private, usage: [.shaderRead, .renderTarget],
                               label: "Ferox.Fallback.ShadowArray")
        let rp = MTLRenderPassDescriptor()
        rp.depthAttachment.texture = shadowArray
        rp.depthAttachment.slice = 0
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .store
        rp.depthAttachment.clearDepth = 1
        if let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.label = "Ferox.ClearFallbackShadow"
            enc.endEncoding()
            // `replace` on a managed texture does not reach the GPU until a blit synchronizes it.
            // (`didModify` is the buffer API; textures use `synchronize`.)
            let managed = [white, clear, blackCube, cubeArray, hiz].filter { $0.storageMode == .managed }
            if !managed.isEmpty, let blit = cb.makeBlitCommandEncoder() {
                blit.label = "Ferox.SyncFallbackTextures"
                for t in managed {
                    for slice in 0..<t.arrayLength {
                        blit.synchronize(texture: t, slice: slice, level: 0)
                    }
                }
                blit.endEncoding()
            }
            cb.commit()
        }
    }
}

// MARK: - Materials

/// Uniforms and textures for one material, ready to bind.
struct BoundMaterial {
    var uniforms = MaterialUniforms()
    /// Slots 0…4: base colour, normal, metallic-roughness, occlusion, emissive.
    var textures: [any MTLTexture]
    var alphaMode: AlphaMode = .opaque
    var doubleSided = false
    var unlit = false
}

/// Resolves material assets into `BoundMaterial`s, memoised for the current frame.
final class MaterialBinder {
    private var cache: [AssetID: BoundMaterial] = [:]
    private var defaultMaterial: BoundMaterial?

    /// Clears the per-frame memo (materials and textures can change between frames).
    func beginFrame() {
        cache.removeAll(keepingCapacity: true)
        defaultMaterial = nil
    }

    func material(_ id: AssetID?, assets: AssetManager, textures: TextureCache, fallback: FallbackTextures,
                  frame: UInt64) -> BoundMaterial {
        if let id, let m = cache[id] { return m }
        if id == nil, let m = defaultMaterial { return m }
        let data = id.flatMap { assets.loadedMaterial($0) } ?? .default
        let m = Self.bind(data, assets: assets, textures: textures, fallback: fallback, frame: frame)
        if let id { cache[id] = m } else { defaultMaterial = m }
        return m
    }

    /// Builds uniforms; a texture bit is set only when its texture is resident, so a
    /// still-loading normal map does not perturb normals with the white fallback.
    static func bind(_ m: MaterialData, assets: AssetManager, textures: TextureCache, fallback: FallbackTextures,
                     frame: UInt64) -> BoundMaterial {
        var b = BoundMaterial(textures: Array(repeating: fallback.white, count: 5))
        var u = MaterialUniforms()
        u.baseColor = m.baseColor.vector
        u.emissive = Vec4(m.emissive.rgb * m.emissiveStrength, 0)
        u.params = Vec4(min(max(m.metallic, 0), 1), min(max(m.roughness, 0.02), 1), m.normalScale,
                        min(max(m.occlusionStrength, 0), 1))
        let mode: Float = m.alphaMode == .opaque ? 0 : (m.alphaMode == .mask ? 1 : 2)
        u.params2 = Vec4(m.alphaCutoff, mode, m.unlit ? 1 : 0, m.doubleSided ? 1 : 0)
        if let c = m.vectorParameters["custom"] { u.custom = c }

        // Colour textures are sRGB-encoded; data textures are linear.
        let slots: [(AssetID?, Bool, UInt32)] = [
            (m.baseColorTexture, true, MaterialTextureBits.baseColor),
            (m.normalTexture, false, MaterialTextureBits.normal),
            (m.metallicRoughnessTexture, false, MaterialTextureBits.metallicRoughness),
            (m.occlusionTexture, false, MaterialTextureBits.occlusion),
            (m.emissiveTexture, true, MaterialTextureBits.emissive),
        ]
        var bits: UInt32 = 0
        for (i, slot) in slots.enumerated() {
            guard let id = slot.0, let t = textures.texture(id, srgb: slot.1, assets: assets, frame: frame) else { continue }
            b.textures[i] = t
            bits |= slot.2
        }
        u.flags = SIMD4(bits, 0, 0, 0)
        b.uniforms = u
        b.alphaMode = m.alphaMode
        b.doubleSided = m.doubleSided
        b.unlit = m.unlit
        return b
    }
}
#endif
