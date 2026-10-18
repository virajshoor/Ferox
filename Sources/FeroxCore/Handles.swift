/// A generational handle into a `HandlePool`. Stale handles (whose slot has been reused)
/// are detected by comparing generations, so dangling references fail safely rather than
/// aliasing a new object.
public struct Handle<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let index: UInt32
    public let generation: UInt32
    public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }
    public static var invalid: Handle { Handle(index: .max, generation: 0) }
    public var isValid: Bool { index != .max }
    public var description: String { "Handle(\(index)v\(generation))" }
}

/// Dense, generation-checked storage for engine-owned resources (meshes, textures,
/// materials, sounds). Elements are stored contiguously; freed slots are recycled.
public struct HandlePool<Tag, Value> {
    private var values: [Value?] = []
    private var generations: [UInt32] = []
    private var freeList: [UInt32] = []
    public private(set) var count = 0

    public init() {}

    public mutating func insert(_ value: Value) -> Handle<Tag> {
        if let idx = freeList.popLast() {
            values[Int(idx)] = value
            count += 1
            return Handle(index: idx, generation: generations[Int(idx)])
        }
        values.append(value)
        generations.append(1)
        count += 1
        return Handle(index: UInt32(values.count - 1), generation: 1)
    }

    public func contains(_ h: Handle<Tag>) -> Bool {
        let i = Int(h.index)
        return h.isValid && i < values.count && generations[i] == h.generation && values[i] != nil
    }

    public subscript(_ h: Handle<Tag>) -> Value? {
        get { contains(h) ? values[Int(h.index)] : nil }
        set {
            guard contains(h) else { return }
            if let v = newValue { values[Int(h.index)] = v } else { remove(h) }
        }
    }

    @discardableResult
    public mutating func remove(_ h: Handle<Tag>) -> Value? {
        guard contains(h) else { return nil }
        let i = Int(h.index)
        let v = values[i]
        values[i] = nil
        generations[i] &+= 1
        if generations[i] == 0 { generations[i] = 1 }
        freeList.append(h.index)
        count -= 1
        return v
    }

    /// Iterates live values with their handles.
    public func forEach(_ body: (Handle<Tag>, Value) throws -> Void) rethrows {
        for i in values.indices {
            if let v = values[i] { try body(Handle(index: UInt32(i), generation: generations[i]), v) }
        }
    }

    public mutating func removeAll() {
        for i in values.indices where values[i] != nil {
            values[i] = nil
            generations[i] &+= 1
            freeList.append(UInt32(i))
        }
        count = 0
    }
}
