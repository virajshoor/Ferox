import Foundation

/// A dynamically typed JSON value. Used for scene/prefab component payloads, asset
/// metadata, editor property editing and network messages where the schema is open.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let n = try? c.decode(Double.self) {
            self = .number(n)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
            return
        }
        if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var floatValue: Float? { doubleValue.map { Float($0) } }
    public var intValue: Int? { doubleValue.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// Converts any `Encodable` value into a `JSONValue` tree.
    ///
    /// `userInfo` values must be `Sendable`. Swift 6's encoder stores them that way.
    /// A mutable table used only on this thread can be `@unchecked Sendable`.
    public static func encode<T: Encodable>(
        _ value: T, userInfo: [CodingUserInfoKey: any Sendable] = [:]
    ) throws -> JSONValue {
        let enc = JSONEncoder()
        applyUserInfo(userInfo, toEncoder: enc)
        enc.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try enc.encode(value)
        let dec = JSONDecoder()
        return try dec.decode(JSONValue.self, from: data)
    }

    /// Decodes a `Decodable` value from this tree.
    public func decode<T: Decodable>(
        _ type: T.Type, userInfo: [CodingUserInfoKey: any Sendable] = [:]
    ) throws -> T {
        let data = try JSONEncoder().encode(self)
        let dec = JSONDecoder()
        Self.applyUserInfo(userInfo, toDecoder: dec)
        dec.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try dec.decode(T.self, from: data)
    }

    /// Swift 5.10's encoder stores `[CodingUserInfoKey: Any]`. Swift 6 stores
    /// `[CodingUserInfoKey: any Sendable]`. The dictionaries are invariant, so each
    /// SDK gets the assignment it accepts. The values are the same objects.
    private static func applyUserInfo(_ userInfo: [CodingUserInfoKey: any Sendable], toEncoder encoder: JSONEncoder) {
        #if compiler(>=6.0)
            encoder.userInfo = userInfo
        #else
            for (key, value) in userInfo { encoder.userInfo[key] = value }
        #endif
    }

    private static func applyUserInfo(_ userInfo: [CodingUserInfoKey: any Sendable], toDecoder decoder: JSONDecoder) {
        #if compiler(>=6.0)
            decoder.userInfo = userInfo
        #else
            for (key, value) in userInfo { decoder.userInfo[key] = value }
        #endif
    }

    /// Maximum nesting depth of the tree (used to reject maliciously deep documents).
    public var depth: Int {
        switch self {
        case .array(let a): return 1 + (a.map(\.depth).max() ?? 0)
        case .object(let o): return 1 + (o.values.map(\.depth).max() ?? 0)
        default: return 0
        }
    }
}

/// Stable identifier of an asset. Generated once at import time and stored in the asset's
/// `.meta` sidecar, so references survive renames and moves inside the project.
public struct AssetID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String
    public init(_ raw: String) { rawValue = raw }
    public init() { rawValue = UUID().uuidString.lowercased() }
    public static let none = AssetID("")
    public var isNone: Bool { rawValue.isEmpty }
    public var description: String { rawValue }
    public static func < (a: AssetID, b: AssetID) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Deterministic ID derived from a project-relative path (used for built-in assets and
    /// when no `.meta` file exists yet). FNV-1a 64-bit, formatted as hex.
    public static func derived(fromPath path: String) -> AssetID {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in path.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return AssetID("path-" + String(h, radix: 16))
    }
}
