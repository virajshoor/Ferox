import FeroxCore
import Foundation

/// Errors raised while decoding untrusted network data. Decoding never traps: every read
/// is bounds-checked and every length is capped.
public enum NetDecodeError: Error, Equatable, CustomStringConvertible {
    case truncated
    case lengthExceeded(Int, max: Int)
    case invalidValue(String)
    case unknownMessage(UInt16)

    public var description: String {
        switch self {
        case .truncated: return "packet truncated"
        case let .lengthExceeded(n, m): return "length \(n) exceeds maximum \(m)"
        case .invalidValue(let s): return "invalid value: \(s)"
        case .unknownMessage(let id): return "unknown message type \(id)"
        }
    }
}

/// Little-endian byte writer with LEB128 variable-length integers.
public struct NetWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init(capacity: Int = 256) { bytes.reserveCapacity(capacity) }

    public mutating func write(_ v: UInt8) { bytes.append(v) }
    public mutating func write(_ v: Bool) { bytes.append(v ? 1 : 0) }
    public mutating func write(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    public mutating func write(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    public mutating func write(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    public mutating func write(_ v: Float) { write(v.bitPattern) }
    public mutating func write(_ v: Double) { write(v.bitPattern) }
    public mutating func writeVarUInt(_ v: UInt64) {
        var x = v
        repeat {
            var b = UInt8(x & 0x7F)
            x >>= 7
            if x != 0 { b |= 0x80 }
            bytes.append(b)
        } while x != 0
    }
    /// Zig-zag encoded signed varint.
    public mutating func writeVarInt(_ v: Int64) { writeVarUInt(UInt64(bitPattern: (v << 1) ^ (v >> 63))) }
    public mutating func write(_ s: String) {
        let u = Array(s.utf8)
        writeVarUInt(UInt64(u.count))
        bytes += u
    }
    public mutating func write(_ d: [UInt8]) {
        writeVarUInt(UInt64(d.count))
        bytes += d
    }
    public mutating func write(_ v: Vec3) {
        write(v.x)
        write(v.y)
        write(v.z)
    }
    public mutating func write(_ q: Quat) {
        // Smallest-three would be smaller; full floats keep the example readable and exact.
        write(q.x)
        write(q.y)
        write(q.z)
        write(q.w)
    }
    /// Quantises a float in [lo, hi] to `bits` bits (≤ 16).
    public mutating func writeQuantized(_ v: Float, lo: Float, hi: Float, bits: Int = 16) {
        let maxV = Float((1 << min(bits, 16)) - 1)
        let t = ((v - lo) / (hi - lo)).saturated
        write(UInt16((t * maxV).rounded()))
    }
    public mutating func append(_ other: [UInt8]) { bytes += other }
}

/// Bounds-checked reader over untrusted bytes.
public struct NetReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset = 0
    /// Upper bound for string and blob lengths.
    public var maxLength = 4096

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else { throw NetDecodeError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }
    public mutating func readBool() throws -> Bool {
        let b = try readUInt8()
        guard b <= 1 else { throw NetDecodeError.invalidValue("bool \(b)") }
        return b == 1
    }
    public mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw NetDecodeError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw NetDecodeError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
        offset += 4
        return v
    }
    public mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw NetDecodeError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        offset += 8
        return v
    }
    public mutating func readFloat() throws -> Float {
        let f = Float(bitPattern: try readUInt32())
        guard f.isFinite else { throw NetDecodeError.invalidValue("non-finite float") }
        return f
    }
    public mutating func readDouble() throws -> Double {
        let d = Double(bitPattern: try readUInt64())
        guard d.isFinite else { throw NetDecodeError.invalidValue("non-finite double") }
        return d
    }
    public mutating func readVarUInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try readUInt8()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw NetDecodeError.invalidValue("varint too long") }
        }
    }
    public mutating func readVarInt() throws -> Int64 {
        let u = try readVarUInt()
        return Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
    }
    public mutating func readLength(max m: Int? = nil) throws -> Int {
        let n = try readVarUInt()
        let limit = m ?? maxLength
        guard n <= UInt64(limit) else { throw NetDecodeError.lengthExceeded(Int(clamping: n), max: limit) }
        guard Int(n) <= remaining else { throw NetDecodeError.truncated }
        return Int(n)
    }
    public mutating func readString(max m: Int? = nil) throws -> String {
        let n = try readLength(max: m)
        defer { offset += n }
        guard let s = String(bytes: bytes[offset..<(offset + n)], encoding: .utf8) else {
            throw NetDecodeError.invalidValue("invalid UTF-8")
        }
        return s
    }
    public mutating func readBytes(max m: Int? = nil) throws -> [UInt8] {
        let n = try readLength(max: m)
        defer { offset += n }
        return Array(bytes[offset..<(offset + n)])
    }
    public mutating func readVec3() throws -> Vec3 {
        let x = try readFloat(), y = try readFloat(), z = try readFloat()
        return Vec3(x, y, z)
    }
    public mutating func readQuat() throws -> Quat {
        let x = try readFloat(), y = try readFloat(), z = try readFloat(), w = try readFloat()
        return Quat(x: x, y: y, z: z, w: w).normalized
    }
    public mutating func readQuantized(lo: Float, hi: Float, bits: Int = 16) throws -> Float {
        let maxV = Float((1 << min(bits, 16)) - 1)
        return lo + (hi - lo) * Float(try readUInt16()) / maxV
    }
}

/// A typed network message. Implement `encode`/`init(from:)` with `NetWriter`/`NetReader`.
public protocol NetMessage: Sendable {
    /// Unique message type id (0–999 are reserved for Ferox).
    static var messageID: UInt16 { get }
    func encode(_ w: inout NetWriter)
    init(from r: inout NetReader) throws
}

/// Maps message ids to decoders.
public final class NetMessageRegistry: @unchecked Sendable {
    private var decoders: [UInt16: (inout NetReader) throws -> any NetMessage] = [:]
    public init() {}
    public func register<M: NetMessage>(_ type: M.Type) {
        precondition(decoders[M.messageID] == nil, "Duplicate message id \(M.messageID)")
        decoders[M.messageID] = { r in try M(from: &r) }
    }
    public func decode(id: UInt16, _ r: inout NetReader) throws -> any NetMessage {
        guard let d = decoders[id] else { throw NetDecodeError.unknownMessage(id) }
        return try d(&r)
    }
    public func isRegistered(_ id: UInt16) -> Bool { decoders[id] != nil }
}
