import FeroxCore
import Foundation

/// Minimal little-endian binary writer/reader for cached import products. Arrays of POD
/// values are copied as raw bytes, which makes cache loads close to memcpy speed.
struct BinaryWriter {
    var data = Data()
    mutating func write<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    mutating func write(_ s: String) {
        let b = Data(s.utf8)
        write(UInt32(b.count))
        data.append(b)
    }
    mutating func writeArray<T>(_ a: [T]) {
        write(UInt64(a.count))
        a.withUnsafeBytes { data.append(contentsOf: $0) }
    }
    mutating func write(_ d: Data) {
        write(UInt64(d.count))
        data.append(d)
    }
}

struct BinaryReader {
    let data: Data
    var offset = 0
    let name: String
    init(_ data: Data, name: String) {
        self.data = data
        self.name = name
    }
    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard offset + n <= data.count else { throw AssetError.corrupt(name, reason: "cache truncated") }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += n
        return T(littleEndian: v)
    }
    mutating func readString() throws -> String {
        let n = Int(try read(UInt32.self))
        guard n <= 1 << 20, offset + n <= data.count else { throw AssetError.corrupt(name, reason: "bad string") }
        let s = String(decoding: data[(data.startIndex + offset)..<(data.startIndex + offset + n)], as: UTF8.self)
        offset += n
        return s
    }
    mutating func readArray<T>(_: T.Type, limit: Int = 100_000_000) throws -> [T] {
        let count = Int(try read(UInt64.self))
        let bytes = count * MemoryLayout<T>.stride
        guard count >= 0, count <= limit, offset + bytes <= data.count else {
            throw AssetError.corrupt(name, reason: "bad array length")
        }
        var out = [T]()
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            for i in 0..<count {
                out.append(base.advanced(by: i * MemoryLayout<T>.stride).loadUnaligned(as: T.self))
            }
        }
        offset += bytes
        return out
    }
    mutating func readData() throws -> Data {
        let n = Int(try read(UInt64.self))
        guard n >= 0, offset + n <= data.count else { throw AssetError.corrupt(name, reason: "bad blob length") }
        let d = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        offset += n
        return d
    }
}

extension MeshData {
    static let cacheMagic: UInt32 = 0x4853_4D46  // "FMSH"

    func encodeBinary(into w: inout BinaryWriter) {
        w.write(MeshData.cacheMagic)
        w.write(name)
        w.writeArray(positions)
        w.writeArray(normals)
        w.writeArray(tangents)
        w.writeArray(uv0)
        w.writeArray(uv1)
        w.writeArray(colors)
        w.writeArray(joints)
        w.writeArray(weights)
        w.writeArray(indices)
        w.write(UInt32(submeshes.count))
        for s in submeshes {
            w.write(UInt32(s.indexOffset))
            w.write(UInt32(s.indexCount))
            w.write(UInt32(s.materialIndex))
        }
    }

    static func decodeBinary(_ r: inout BinaryReader) throws -> MeshData {
        guard try r.read(UInt32.self) == cacheMagic else { throw AssetError.corrupt(r.name, reason: "bad mesh magic") }
        let name = try r.readString()
        let positions = try r.readArray(Vec3.self)
        var m = MeshData(name: name, positions: positions, indices: [], submeshes: [])
        m.normals = try r.readArray(Vec3.self)
        m.tangents = try r.readArray(Vec4.self)
        m.uv0 = try r.readArray(Vec2.self)
        m.uv1 = try r.readArray(Vec2.self)
        m.colors = try r.readArray(Vec4.self)
        m.joints = try r.readArray(SIMD4<UInt16>.self)
        m.weights = try r.readArray(Vec4.self)
        m.indices = try r.readArray(UInt32.self)
        let sc = Int(try r.read(UInt32.self))
        guard sc <= 65536 else { throw AssetError.corrupt(r.name, reason: "too many submeshes") }
        for _ in 0..<sc {
            let o = Int(try r.read(UInt32.self))
            let c = Int(try r.read(UInt32.self))
            let mi = Int(try r.read(UInt32.self))
            m.submeshes.append(Submesh(indexOffset: o, indexCount: c, materialIndex: mi))
        }
        m.recomputeBounds()
        try m.validate()
        return m
    }
}

extension ImageData {
    func encodeBinary(into w: inout BinaryWriter) {
        w.write(UInt32(0x4D49_5846))  // "FXIM"
        w.write(UInt32(width))
        w.write(UInt32(height))
        w.write(format.rawValue)
        w.write(pixels)
        w.write(UInt32(mips.count))
        for m in mips { w.write(m) }
        w.write(UInt32(faces.count))
        for f in faces { w.write(f) }
    }

    static func decodeBinary(_ r: inout BinaryReader) throws -> ImageData {
        guard try r.read(UInt32.self) == 0x4D49_5846 else {
            throw AssetError.corrupt(r.name, reason: "bad image magic")
        }
        let w = Int(try r.read(UInt32.self))
        let h = Int(try r.read(UInt32.self))
        guard let fmt = PixelFormat(rawValue: try r.readString()) else {
            throw AssetError.corrupt(r.name, reason: "bad pixel format")
        }
        var img = ImageData(width: w, height: h, format: fmt, pixels: try r.readData())
        guard img.pixels.count == w * h * fmt.bytesPerPixel else {
            throw AssetError.corrupt(r.name, reason: "pixel size mismatch")
        }
        let mc = Int(try r.read(UInt32.self))
        guard mc <= 32 else { throw AssetError.corrupt(r.name, reason: "bad mip count") }
        for _ in 0..<mc { img.mips.append(try r.readData()) }
        let fc = Int(try r.read(UInt32.self))
        guard fc == 0 || fc == 6 else { throw AssetError.corrupt(r.name, reason: "bad face count") }
        for _ in 0..<fc { img.faces.append(try r.readData()) }
        return img
    }
}
