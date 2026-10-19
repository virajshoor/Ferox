import FeroxAssets
import FeroxMath

/// Writes `MeshVertexLayout` and the skin stream straight into caller-owned memory.
/// The GPU upload path uses this so a mesh is not first copied into a `[Float]`.
public enum MeshVertexWriter {
    public static var floatsPerVertex: Int { MeshVertexLayout.stride / MemoryLayout<Float>.stride }
    public static var skinWordsPerVertex: Int { 6 }

    public static func interleavedByteCount(vertexCount: Int) -> Int {
        vertexCount * MeshVertexLayout.stride
    }

    public static func skinByteCount(vertexCount: Int) -> Int {
        vertexCount * skinWordsPerVertex * MemoryLayout<UInt32>.stride
    }

    public static func writeInterleaved(_ mesh: MeshData, to memory: UnsafeMutableRawPointer) {
        let n = mesh.positions.count
        let floats = memory.bindMemory(to: Float.self, capacity: n * floatsPerVertex)
        let hasN = mesh.normals.count == n
        let hasT = mesh.tangents.count == n
        let hasUV0 = mesh.uv0.count == n
        let hasUV1 = mesh.uv1.count == n
        let hasC = mesh.colors.count == n
        let stride = floatsPerVertex
        for i in 0..<n {
            let o = i * stride
            let p = mesh.positions[i]
            floats[o] = p.x
            floats[o + 1] = p.y
            floats[o + 2] = p.z
            let normal = hasN ? mesh.normals[i] : Vec3(0, 1, 0)
            floats[o + 3] = normal.x
            floats[o + 4] = normal.y
            floats[o + 5] = normal.z
            let tangent = hasT ? mesh.tangents[i] : Vec4(1, 0, 0, 1)
            floats[o + 6] = tangent.x
            floats[o + 7] = tangent.y
            floats[o + 8] = tangent.z
            floats[o + 9] = tangent.w
            let uv0 = hasUV0 ? mesh.uv0[i] : .zero
            floats[o + 10] = uv0.x
            floats[o + 11] = uv0.y
            let uv1 = hasUV1 ? mesh.uv1[i] : uv0
            floats[o + 12] = uv1.x
            floats[o + 13] = uv1.y
            let color = hasC ? mesh.colors[i] : Vec4(1, 1, 1, 1)
            floats[o + 14] = color.x
            floats[o + 15] = color.y
            floats[o + 16] = color.z
            floats[o + 17] = color.w
        }
    }

    public static func writeSkin(_ mesh: MeshData, to memory: UnsafeMutableRawPointer) {
        let n = mesh.positions.count
        let words = memory.bindMemory(to: UInt32.self, capacity: n * skinWordsPerVertex)
        for i in 0..<n {
            let joints = i < mesh.joints.count ? mesh.joints[i] : SIMD4<UInt16>(repeating: 0)
            var weight = mesh.weights.count == n ? mesh.weights[i] : Vec4(1, 0, 0, 0)
            let sum = weight.x + weight.y + weight.z + weight.w
            weight = sum > 1e-6 ? weight / sum : Vec4(1, 0, 0, 0)
            let o = i * skinWordsPerVertex
            words[o] = UInt32(joints.x) | (UInt32(joints.y) << 16)
            words[o + 1] = UInt32(joints.z) | (UInt32(joints.w) << 16)
            words[o + 2] = weight.x.bitPattern
            words[o + 3] = weight.y.bitPattern
            words[o + 4] = weight.z.bitPattern
            words[o + 5] = weight.w.bitPattern
        }
    }
}
