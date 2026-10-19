import FeroxCore
import Foundation

/// Identifies a client on the server.
public struct ClientID: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt32
    public var description: String { "Client#\(value)" }
}

public enum NetEvent: Sendable {
    case connected(ClientID)
    case disconnected(ClientID, reason: String)
    case message(ClientID, any NetMessage)
}

public enum ClientEvent: Sendable {
    case connected
    case connectionFailed(String)
    case disconnected(String)
    case message(any NetMessage)
}

/// Shared configuration.
public struct NetConfig: Sendable {
    /// Distinguishes your game's traffic; packets with another id are ignored.
    public var protocolID: UInt16 = 0xFE70
    /// Bump when the message schema changes; mismatched clients are denied.
    public var protocolVersion: UInt16 = 1
    public var maxClients = 16
    public var timeout: Double = 10
    public var connectAttemptInterval: Double = 0.25
    public var connectTimeout: Double = 5
    /// Per-endpoint cap on connection requests per second (handshake flood protection).
    public var maxConnectRequestsPerSecond = 10
    /// Per-client cap on packets per second; excess packets are dropped.
    public var maxPacketsPerSecond = 300
    public init() {}
}

/// Packet framing shared by server and client.
enum Framing {
    /// Connection requests are padded so the challenge reply is never larger than the
    /// request (prevents using the server as a reflection amplifier).
    static let requestPadding = 64

    static func header(_ w: inout NetWriter, _ cfg: NetConfig, _ type: PacketType) {
        w.write(cfg.protocolID)
        w.write(type.rawValue)
    }
}

/// Authoritative server over any `NetTransport`.
///
/// Handshake: request(version, client salt) → challenge(server salt) → response(xor) →
/// accept. No per-client state is allocated until the challenge is answered, and
/// challenges expire after a few seconds, which limits spoofed-source floods.
public final class NetServer {
    public let transport: any NetTransport
    public let registry: NetMessageRegistry
    public var config: NetConfig
    private var clients: [NetEndpoint: (ClientID, NetConnection)] = [:]
    private var byID: [ClientID: NetConnection] = [:]
    private var challenges: [NetEndpoint: (server: UInt64, client: UInt64, time: Double)] = [:]
    private var requestCounts: [NetEndpoint: (window: Double, count: Int)] = [:]
    private var packetCounts: [NetEndpoint: (window: Double, count: Int)] = [:]
    private var nextClient: UInt32 = 1
    public private(set) var events: [NetEvent] = []

    public init(transport: any NetTransport, registry: NetMessageRegistry, config: NetConfig = NetConfig()) {
        self.transport = transport
        self.registry = registry
        self.config = config
    }

    public var clientIDs: [ClientID] { Array(byID.keys) }
    public func stats(_ id: ClientID) -> NetStats? { byID[id]?.stats }

    public func send<M: NetMessage>(_ m: M, to id: ClientID, channel: NetChannel = .reliableOrdered) {
        guard let c = byID[id] else { return }
        var w = NetWriter()
        m.encode(&w)
        c.send(type: M.messageID, payload: w.bytes, channel: channel)
    }

    public func broadcast<M: NetMessage>(_ m: M, channel: NetChannel = .reliableOrdered, except: ClientID? = nil) {
        var w = NetWriter()
        m.encode(&w)
        for (id, c) in byID where id != except { c.send(type: M.messageID, payload: w.bytes, channel: channel) }
    }

    public func disconnect(_ id: ClientID, reason: String = "kicked") {
        guard let c = byID[id] else { return }
        var w = NetWriter()
        Framing.header(&w, config, .disconnect)
        w.write(c.token)
        transport.send(w.bytes, to: c.endpoint)
        remove(c.endpoint, reason: reason)
    }

    private func remove(_ ep: NetEndpoint, reason: String) {
        guard let id = clients.removeValue(forKey: ep)?.0 else { return }
        byID[id] = nil
        events.append(.disconnected(id, reason: reason))
        Log.info("Net", "\(id) disconnected: \(reason)")
    }

    /// Receives, processes timeouts and sends. Returns events since the last call.
    public func update(now: Double) -> [NetEvent] {
        for (bytes, from) in transport.receive() { handle(bytes, from: from, now: now) }
        for (ep, entry) in clients where entry.1.timedOut(now: now) { remove(ep, reason: "timed out") }
        challenges = challenges.filter { now - $0.value.time < 5 }
        for entry in clients.values {
            let c = entry.1
            for p in c.flush(now: now) { transport.send(p, to: c.endpoint) }
        }
        defer { events.removeAll() }
        return events
    }

    private func rateLimited(
        _ table: inout [NetEndpoint: (window: Double, count: Int)], _ ep: NetEndpoint, now: Double, limit: Int
    ) -> Bool {
        var e = table[ep] ?? (now, 0)
        if now - e.window >= 1 { e = (now, 0) }
        e.count += 1
        table[ep] = e
        if table.count > 4096 { table = table.filter { now - $0.value.window < 2 } }
        return e.count > limit
    }

    private func handle(_ bytes: [UInt8], from ep: NetEndpoint, now: Double) {
        var r = NetReader(bytes)
        do {
            guard try r.readUInt16() == config.protocolID, let type = PacketType(rawValue: try r.readUInt8()) else {
                return
            }
            switch type {
            case .connectRequest:
                guard bytes.count >= Framing.requestPadding,
                    !rateLimited(&requestCounts, ep, now: now, limit: config.maxConnectRequestsPerSecond)
                else { return }
                let version = try r.readUInt16()
                let clientSalt = try r.readUInt64()
                if clients[ep] != nil { return }  // already connected; ignore duplicates
                var w = NetWriter()
                if version != config.protocolVersion || clients.count >= config.maxClients {
                    Framing.header(&w, config, .deny)
                    w.write(version != config.protocolVersion ? "protocol version mismatch" : "server full")
                } else {
                    // Salts come from the system CSPRNG so they cannot be predicted by spoofers.
                    let serverSalt = challenges[ep]?.server ?? UInt64.random(in: .min ... .max)
                    challenges[ep] = (serverSalt, clientSalt, now)
                    Framing.header(&w, config, .challenge)
                    w.write(clientSalt)
                    w.write(serverSalt)
                }
                transport.send(w.bytes, to: ep)
            case .challengeResponse:
                let token = try r.readUInt64()
                guard let ch = challenges[ep], token == ch.server ^ ch.client else { return }
                challenges[ep] = nil
                if clients[ep] == nil {
                    guard clients.count < config.maxClients else { return }
                    let id = ClientID(value: nextClient)
                    nextClient += 1
                    let c = NetConnection(endpoint: ep, token: token, protocolID: config.protocolID, now: now)
                    c.timeout = config.timeout
                    clients[ep] = (id, c)
                    byID[id] = c
                    events.append(.connected(id))
                    Log.info("Net", "\(id) connected from \(ep)")
                }
                var w = NetWriter()
                Framing.header(&w, config, .accept)
                w.write(token)
                transport.send(w.bytes, to: ep)
            case .payload, .keepAlive:
                guard let entry = clients[ep] else { return }
                let (id, c) = entry
                if rateLimited(&packetCounts, ep, now: now, limit: config.maxPacketsPerSecond) { return }
                try c.receive(&r, now: now)
                for (t, payload) in c.takeInbox() {
                    var mr = NetReader(payload)
                    do {
                        events.append(.message(id, try registry.decode(id: t, &mr)))
                    } catch {
                        Log.warning("Net", "\(id): dropped malformed message \(t): \(error)")
                    }
                }
            case .disconnect:
                guard let c = clients[ep]?.1, try r.readUInt64() == c.token else { return }
                remove(ep, reason: "client disconnected")
            case .challenge, .accept, .deny:
                return  // client-bound packets
            }
        } catch {
            Log.debug("Net", "Dropped malformed packet from \(ep): \(error)")
        }
    }
}

/// Client connecting to a `NetServer`.
public final class NetClient {
    public enum State: Equatable, Sendable { case disconnected, connecting, connected }
    public let transport: any NetTransport
    public let registry: NetMessageRegistry
    public var config: NetConfig
    public private(set) var state: State = .disconnected
    private var server: NetEndpoint?
    private var connection: NetConnection?
    private var salt: UInt64 = 0
    private var serverSalt: UInt64?
    private var connectStarted: Double = 0
    private var lastAttempt: Double = -1
    private var events: [ClientEvent] = []

    public init(transport: any NetTransport, registry: NetMessageRegistry, config: NetConfig = NetConfig()) {
        self.transport = transport
        self.registry = registry
        self.config = config
    }

    public var stats: NetStats? { connection?.stats }

    public func connect(to server: NetEndpoint, now: Double) {
        self.server = server
        state = .connecting
        salt = UInt64.random(in: .min ... .max)
        serverSalt = nil
        connectStarted = now
        lastAttempt = -1
    }

    public func disconnect() {
        if let c = connection, let s = server {
            var w = NetWriter()
            Framing.header(&w, config, .disconnect)
            w.write(c.token)
            transport.send(w.bytes, to: s)
        }
        connection = nil
        state = .disconnected
        events.append(.disconnected("local disconnect"))
    }

    public func send<M: NetMessage>(_ m: M, channel: NetChannel = .reliableOrdered) {
        guard let c = connection else { return }
        var w = NetWriter()
        m.encode(&w)
        c.send(type: M.messageID, payload: w.bytes, channel: channel)
    }

    public func update(now: Double) -> [ClientEvent] {
        guard let server else { return [] }
        for (bytes, from) in transport.receive() where from == server { handle(bytes, now: now) }
        switch state {
        case .connecting:
            if now - connectStarted > config.connectTimeout {
                state = .disconnected
                events.append(.connectionFailed("timed out"))
            } else if lastAttempt < 0 || now - lastAttempt >= config.connectAttemptInterval {
                lastAttempt = now
                var w = NetWriter()
                if let ss = serverSalt {
                    Framing.header(&w, config, .challengeResponse)
                    w.write(ss ^ salt)
                } else {
                    Framing.header(&w, config, .connectRequest)
                    w.write(config.protocolVersion)
                    w.write(salt)
                    while w.bytes.count < Framing.requestPadding { w.write(UInt8(0)) }
                }
                transport.send(w.bytes, to: server)
            }
        case .connected:
            if let c = connection {
                if c.timedOut(now: now) {
                    connection = nil
                    state = .disconnected
                    events.append(.disconnected("timed out"))
                } else {
                    for p in c.flush(now: now) { transport.send(p, to: server) }
                }
            }
        case .disconnected:
            break
        }
        defer { events.removeAll() }
        return events
    }

    private func handle(_ bytes: [UInt8], now: Double) {
        var r = NetReader(bytes)
        do {
            guard try r.readUInt16() == config.protocolID, let type = PacketType(rawValue: try r.readUInt8()) else {
                return
            }
            switch type {
            case .challenge:
                guard state == .connecting, try r.readUInt64() == salt else { return }
                serverSalt = try r.readUInt64()
                lastAttempt = -1
            case .accept:
                guard state == .connecting, let ss = serverSalt, try r.readUInt64() == ss ^ salt, let server else {
                    return
                }
                let c = NetConnection(endpoint: server, token: ss ^ salt, protocolID: config.protocolID, now: now)
                c.timeout = config.timeout
                connection = c
                state = .connected
                events.append(.connected)
            case .deny:
                let reason = (try? r.readString(max: 256)) ?? "denied"
                state = .disconnected
                events.append(.connectionFailed(reason))
            case .payload, .keepAlive:
                guard let c = connection else { return }
                try c.receive(&r, now: now)
                for (t, payload) in c.takeInbox() {
                    var mr = NetReader(payload)
                    if let m = try? registry.decode(id: t, &mr) { events.append(.message(m)) }
                }
            case .disconnect:
                guard let c = connection, try r.readUInt64() == c.token else { return }
                connection = nil
                state = .disconnected
                events.append(.disconnected("server closed the connection"))
            case .connectRequest, .challengeResponse:
                return
            }
        } catch {
            Log.debug("Net", "Client dropped malformed packet: \(error)")
        }
    }
}
