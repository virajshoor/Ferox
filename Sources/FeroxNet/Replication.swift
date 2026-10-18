import FeroxCore
import Foundation

/// Transform state of one replicated object.
public struct ObjectState: Sendable, Hashable {
    public var netID: UInt32
    public var position: Vec3
    public var rotation: Quat
    public var velocity: Vec3
    public init(netID: UInt32, position: Vec3, rotation: Quat, velocity: Vec3 = .zero) {
        self.netID = netID
        self.position = position
        self.rotation = rotation
        self.velocity = velocity
    }
}

/// Server → client snapshot of replicated objects for one simulation tick (sent unreliable-sequenced).
///
/// One message must fit in `NetConnection.maxMessageSize` (1024 bytes). The header is 13
/// bytes and an object takes at most 45 (a 5-byte net id plus 40 bytes of state), so at most
/// 22 objects fit. Use `split(tick:serverTime:objects:)` to send larger sets as several messages.
public struct SnapshotMessage: NetMessage, Hashable {
    public static let messageID: UInt16 = 1
    public static let maxObjects = 22
    public var tick: UInt32
    public var serverTime: Double
    public var objects: [ObjectState]
    public init(tick: UInt32, serverTime: Double, objects: [ObjectState]) {
        self.tick = tick
        self.serverTime = serverTime
        self.objects = objects
    }
    public func encode(_ w: inout NetWriter) {
        w.write(tick)
        w.write(serverTime)
        w.writeVarUInt(UInt64(min(objects.count, SnapshotMessage.maxObjects)))
        for o in objects.prefix(SnapshotMessage.maxObjects) {
            w.writeVarUInt(UInt64(o.netID))
            w.write(o.position)
            w.write(o.rotation)
            w.write(o.velocity)
        }
    }
    public init(from r: inout NetReader) throws {
        tick = try r.readUInt32()
        serverTime = try r.readDouble()
        let n = try r.readVarUInt()
        guard n <= UInt64(SnapshotMessage.maxObjects) else { throw NetDecodeError.lengthExceeded(Int(clamping: n), max: SnapshotMessage.maxObjects) }
        var objs: [ObjectState] = []
        for _ in 0..<Int(n) {
            let id = try r.readVarUInt()
            guard id <= UInt64(UInt32.max) else { throw NetDecodeError.invalidValue("netID") }
            let p = try r.readVec3(), q = try r.readQuat(), v = try r.readVec3()
            objs.append(ObjectState(netID: UInt32(id), position: p, rotation: q, velocity: v))
        }
        objects = objs
    }

    /// Splits `objects` into as many snapshots as needed, each within `maxObjects`, all with
    /// the same tick and server time. An empty set gives one empty snapshot.
    public static func split(tick: UInt32, serverTime: Double, objects: [ObjectState]) -> [SnapshotMessage] {
        guard !objects.isEmpty else { return [SnapshotMessage(tick: tick, serverTime: serverTime, objects: [])] }
        return stride(from: 0, to: objects.count, by: maxObjects).map {
            SnapshotMessage(tick: tick, serverTime: serverTime,
                            objects: Array(objects[$0..<min($0 + maxObjects, objects.count)]))
        }
    }
}

/// Server → client: spawn/despawn of replicated objects (reliable). `prefab` names what to create.
public struct SpawnMessage: NetMessage, Hashable {
    public static let messageID: UInt16 = 2
    public var netID: UInt32
    public var prefab: String
    public var owner: UInt32
    public var despawn: Bool
    public init(netID: UInt32, prefab: String, owner: UInt32, despawn: Bool = false) {
        self.netID = netID
        self.prefab = prefab
        self.owner = owner
        self.despawn = despawn
    }
    public func encode(_ w: inout NetWriter) {
        w.write(netID)
        w.write(prefab)
        w.write(owner)
        w.write(despawn)
    }
    public init(from r: inout NetReader) throws {
        netID = try r.readUInt32()
        prefab = try r.readString(max: 128)
        owner = try r.readUInt32()
        despawn = try r.readBool()
    }
}

/// Client → server: player input for a tick (unreliable; the server treats it as untrusted
/// intent and validates it, e.g. clamps movement vectors).
public struct InputMessage: NetMessage, Hashable {
    public static let messageID: UInt16 = 3
    public var tick: UInt32
    public var move: Vec2
    public var buttons: UInt32
    public init(tick: UInt32, move: Vec2, buttons: UInt32) {
        self.tick = tick
        self.move = move
        self.buttons = buttons
    }
    public func encode(_ w: inout NetWriter) {
        w.write(tick)
        w.writeQuantized(move.x, lo: -1, hi: 1)
        w.writeQuantized(move.y, lo: -1, hi: 1)
        w.write(buttons)
    }
    public init(from r: inout NetReader) throws {
        tick = try r.readUInt32()
        let x = try r.readQuantized(lo: -1, hi: 1), y = try r.readQuantized(lo: -1, hi: 1)
        move = Vec2(x, y)
        buttons = try r.readUInt32()
    }
}

/// Text chat / free-form message (reliable).
public struct TextMessage: NetMessage, Hashable {
    public static let messageID: UInt16 = 4
    public var text: String
    public init(_ text: String) { self.text = text }
    public func encode(_ w: inout NetWriter) { w.write(String(text.prefix(512))) }
    public init(from r: inout NetReader) throws { text = try r.readString(max: 2048) }
}

extension NetMessageRegistry {
    /// Registers Ferox's built-in replication messages (ids 1–4).
    public func registerBuiltins() {
        register(SnapshotMessage.self)
        register(SpawnMessage.self)
        register(InputMessage.self)
        register(TextMessage.self)
    }
}

/// Client-side snapshot interpolation buffer.
///
/// Renders remote objects `delay` seconds in the past and interpolates between the two
/// snapshots bracketing that time, hiding jitter and moderate packet loss. Extrapolates
/// with the last velocity for at most `maxExtrapolation` seconds when snapshots run out.
public struct SnapshotInterpolator: Sendable {
    public var delay: Double = 0.1
    public var maxExtrapolation: Double = 0.25
    private var snapshots: [(time: Double, objects: [UInt32: ObjectState])] = []
    public init(delay: Double = 0.1) { self.delay = delay }

    public mutating func add(_ s: SnapshotMessage) {
        if let last = snapshots.last, s.serverTime <= last.time { return }  // stale/out of order
        snapshots.append((s.serverTime, Dictionary(s.objects.map { ($0.netID, $0) }, uniquingKeysWith: { $1 })))
        if snapshots.count > 64 { snapshots.removeFirst(snapshots.count - 64) }
    }

    public var latestServerTime: Double? { snapshots.last?.time }

    /// Interpolated states at `serverTime - delay`.
    public func sample(serverTime: Double) -> [UInt32: ObjectState] {
        let t = serverTime - delay
        guard let first = snapshots.first else { return [:] }
        if t <= first.time { return first.objects }
        for i in 1..<max(snapshots.count, 1) where i < snapshots.count && t <= snapshots[i].time {
            let a = snapshots[i - 1], b = snapshots[i]
            let u = Float((t - a.time) / max(b.time - a.time, 1e-6))
            var out: [UInt32: ObjectState] = [:]
            for (id, sb) in b.objects {
                guard let sa = a.objects[id] else {
                    out[id] = sb
                    continue
                }
                out[id] = ObjectState(netID: id, position: sa.position.lerp(to: sb.position, u),
                                      rotation: sa.rotation.slerp(to: sb.rotation, u), velocity: sa.velocity.lerp(to: sb.velocity, u))
            }
            return out
        }
        let last = snapshots[snapshots.count - 1]
        let dt = Float(min(t - last.time, maxExtrapolation))
        return last.objects.mapValues { o in
            var e = o
            e.position += o.velocity * dt
            return e
        }
    }
}
