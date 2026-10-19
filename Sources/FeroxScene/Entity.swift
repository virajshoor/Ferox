import FeroxCore
import Foundation

/// Lightweight identifier of an object in a `World`.
///
/// An entity is an index into the world's slot table plus a generation that is
/// incremented whenever the slot is recycled, so stale entity values held by game code
/// are detected (`world.isAlive(e) == false`) rather than silently referring to a new object.
@frozen
public struct Entity: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let index: UInt32
    public let generation: UInt32

    @inlinable public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    public static let null = Entity(index: .max, generation: 0)
    @inlinable public var isNull: Bool { index == .max }
    public var description: String { isNull ? "Entity(null)" : "Entity(\(index):\(generation))" }
    public static func < (a: Entity, b: Entity) -> Bool {
        a.index != b.index ? a.index < b.index : a.generation < b.generation
    }
}

// MARK: - Serialization of entity references

/// Maps entities to compact document-local identifiers while saving, and back while
/// loading, so references between entities (parents, joint targets, camera follow targets)
/// survive a save/load round trip even though runtime indices differ.
/// Not shared across threads. `@unchecked Sendable` lets it sit in encoder `userInfo`,
/// which Swift 6 requires to be `Sendable`. Encode and decode use one table on one thread.
public final class EntityRemapTable: @unchecked Sendable {
    public private(set) var toLocal: [Entity: Int] = [:]
    public private(set) var fromLocal: [Int: Entity] = [:]
    public init() {}
    public func register(_ e: Entity, local: Int) {
        toLocal[e] = local
        fromLocal[local] = e
    }
}

extension CodingUserInfoKey {
    /// `EntityRemapTable` used when encoding/decoding entity references.
    public static let feroxEntityRemap = CodingUserInfoKey(rawValue: "ferox.entityRemap")!
}

extension Entity: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        let local = try c.decode(Int.self)
        if local < 0 {
            self = .null
            return
        }
        if let table = decoder.userInfo[.feroxEntityRemap] as? EntityRemapTable {
            self = table.fromLocal[local] ?? .null
        } else {
            self = .null
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        if isNull {
            try c.encode(-1)
            return
        }
        if let table = encoder.userInfo[.feroxEntityRemap] as? EntityRemapTable, let local = table.toLocal[self] {
            try c.encode(local)
        } else {
            // Reference to an entity outside the serialized set.
            try c.encode(-1)
        }
    }
}
