import FeroxCore
import Foundation

#if canImport(Network)
import Network
#endif

/// Opaque address of a remote peer.
public struct NetEndpoint: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    public var description: String { "\(host):\(port)" }
}

/// Datagram transport. Implementations: `LoopbackTransport` (in-process, deterministic,
/// with an optional `NetworkConditioner`) and `UDPTransport` (Network.framework).
///
/// Datagrams may be lost, duplicated or reordered; `NetConnection` builds reliability on top.
public protocol NetTransport: AnyObject {
    var localEndpoint: NetEndpoint { get }
    func send(_ bytes: [UInt8], to: NetEndpoint)
    /// Returns datagrams received since the last call. Called on the game thread.
    func receive() -> [(bytes: [UInt8], from: NetEndpoint)]
    func close()
}

/// Simulates adverse network conditions for testing: latency, jitter, loss, duplication.
public struct NetworkConditioner: Sendable, Hashable {
    public var latency: Double = 0
    public var jitter: Double = 0
    /// Probability [0, 1] a datagram is dropped.
    public var loss: Double = 0
    /// Probability [0, 1] a datagram is delivered twice.
    public var duplication: Double = 0
    public init(latency: Double = 0, jitter: Double = 0, loss: Double = 0, duplication: Double = 0) {
        self.latency = latency
        self.jitter = jitter
        self.loss = loss
        self.duplication = duplication
    }
    public static let perfect = NetworkConditioner()
    /// A typical poor Wi-Fi link (≈ 120 ms ± 30 ms, 3 % loss).
    public static let poorWiFi = NetworkConditioner(latency: 0.06, jitter: 0.015, loss: 0.03, duplication: 0.005)
}

/// In-process "network" connecting `LoopbackTransport`s by endpoint. Time is supplied by
/// the caller so tests are deterministic (use `advance(to:)`).
public final class LoopbackNetwork: @unchecked Sendable {
    struct InFlight {
        var deliverAt: Double
        var bytes: [UInt8]
        var from: NetEndpoint
        var to: NetEndpoint
    }
    private let lock = NSLock()
    private var inFlight: [InFlight] = []
    private var transports: [NetEndpoint: LoopbackTransport] = [:]
    public var conditioner: NetworkConditioner
    public private(set) var now: Double = 0
    private var rng: PCG32
    public private(set) var sentCount = 0
    public private(set) var droppedCount = 0

    public init(conditioner: NetworkConditioner = .perfect, seed: UInt64 = 1) {
        self.conditioner = conditioner
        rng = PCG32(seed: seed)
    }

    public func makeTransport(port: UInt16, host: String = "loopback") -> LoopbackTransport {
        let t = LoopbackTransport(network: self, endpoint: NetEndpoint(host: host, port: port))
        lock.locked { transports[t.localEndpoint] = t }
        return t
    }

    func unregister(_ e: NetEndpoint) { _ = lock.locked { transports.removeValue(forKey: e) } }

    func send(_ bytes: [UInt8], from: NetEndpoint, to: NetEndpoint) {
        lock.locked {
            sentCount += 1
            if Double(rng.nextFloat()) < conditioner.loss {
                droppedCount += 1
                return
            }
            let copies = Double(rng.nextFloat()) < conditioner.duplication ? 2 : 1
            for _ in 0..<copies {
                let j = conditioner.jitter * (Double(rng.nextFloat()) * 2 - 1)
                inFlight.append(InFlight(deliverAt: now + max(0, conditioner.latency + j), bytes: bytes, from: from, to: to))
            }
        }
    }

    /// Advances simulated time and delivers due datagrams to their transports' inboxes.
    public func advance(to time: Double) {
        let due: [InFlight] = lock.locked {
            now = max(now, time)
            let d = inFlight.filter { $0.deliverAt <= now }.sorted { $0.deliverAt < $1.deliverAt }
            inFlight.removeAll { $0.deliverAt <= now }
            return d
        }
        for p in due {
            let target = lock.locked { transports[p.to] }
            target?.deliver(p.bytes, from: p.from)
        }
    }

    public func advance(by dt: Double) { advance(to: now + dt) }
}

public final class LoopbackTransport: NetTransport, @unchecked Sendable {
    public let localEndpoint: NetEndpoint
    private weak var network: LoopbackNetwork?
    private let inbox = ThreadSafeQueue<([UInt8], NetEndpoint)>()

    init(network: LoopbackNetwork, endpoint: NetEndpoint) {
        self.network = network
        localEndpoint = endpoint
    }

    public func send(_ bytes: [UInt8], to: NetEndpoint) { network?.send(bytes, from: localEndpoint, to: to) }
    func deliver(_ bytes: [UInt8], from: NetEndpoint) { inbox.push((bytes, from)) }
    public func receive() -> [(bytes: [UInt8], from: NetEndpoint)] { inbox.drain().map { ($0.0, $0.1) } }
    public func close() { network?.unregister(localEndpoint) }
}

#if canImport(Network)
/// UDP transport using Network.framework.
///
/// Server mode listens on a port and creates a connection per remote endpoint; client
/// mode connects to one server. Received datagrams are queued and drained on the game
/// thread by `receive()`. Datagrams larger than `maxDatagramSize` are dropped.
///
/// Transport security: plain UDP is unencrypted and unauthenticated. For production use,
/// pass `dtls: true` to wrap traffic in DTLS (Network.framework `NWProtocolTLS`), and keep
/// game-level validation regardless (see Docs/26-Networking.md).
public final class UDPTransport: NetTransport, @unchecked Sendable {
    public private(set) var localEndpoint: NetEndpoint
    public static let maxDatagramSize = 1400
    private let queue = DispatchQueue(label: "dev.ferox.net.udp")
    private var listener: NWListener?
    private var connections: [NetEndpoint: NWConnection] = [:]
    private let inbox = ThreadSafeQueue<([UInt8], NetEndpoint)>()
    private let lock = NSLock()
    private let parameters: NWParameters

    /// Creates a server transport listening on `port` (0 = ephemeral).
    public init(listenOn port: UInt16, dtls: Bool = false) throws {
        parameters = dtls ? NWParameters(dtls: NWProtocolTLS.Options(), udp: NWProtocolUDP.Options()) : .udp
        parameters.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port) else { throw NetDecodeError.invalidValue("port \(port)") }
        let l = try NWListener(using: parameters, on: p)
        localEndpoint = NetEndpoint(host: "0.0.0.0", port: port)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.adopt(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = l.port?.rawValue { self?.lock.locked { self?.localEndpoint = NetEndpoint(host: "0.0.0.0", port: port) } }
            if case .failed(let e) = state { Log.error("Net", "UDP listener failed: \(e)") }
        }
        l.start(queue: queue)
    }

    /// Creates a client transport connected to `server`.
    public init(connectingTo server: NetEndpoint, dtls: Bool = false) {
        parameters = dtls ? NWParameters(dtls: NWProtocolTLS.Options(), udp: NWProtocolUDP.Options()) : .udp
        localEndpoint = NetEndpoint(host: "client", port: 0)
        let c = NWConnection(host: NWEndpoint.Host(server.host), port: NWEndpoint.Port(rawValue: server.port) ?? 0, using: parameters)
        connections[server] = c
        start(c, endpoint: server)
    }

    private func adopt(_ c: NWConnection) {
        guard case let .hostPort(host, port) = c.endpoint else {
            c.cancel()
            return
        }
        let ep = NetEndpoint(host: "\(host)", port: port.rawValue)
        lock.locked { connections[ep] = c }
        start(c, endpoint: ep)
    }

    private func start(_ c: NWConnection, endpoint: NetEndpoint) {
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let e):
                Log.warning("Net", "UDP connection \(endpoint) failed: \(e)")
                _ = self?.lock.locked { self?.connections.removeValue(forKey: endpoint) }
            case .cancelled:
                _ = self?.lock.locked { self?.connections.removeValue(forKey: endpoint) }
            default: break
            }
        }
        c.start(queue: queue)
        receiveLoop(c, endpoint: endpoint)
    }

    private func receiveLoop(_ c: NWConnection, endpoint: NetEndpoint) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count <= UDPTransport.maxDatagramSize { self.inbox.push(([UInt8](data), endpoint)) }
            if error == nil { self.receiveLoop(c, endpoint: endpoint) }
        }
    }

    public func send(_ bytes: [UInt8], to: NetEndpoint) {
        guard bytes.count <= UDPTransport.maxDatagramSize, let c = lock.locked({ connections[to] }) else { return }
        c.send(content: Data(bytes), completion: .idempotent)
    }

    public func receive() -> [(bytes: [UInt8], from: NetEndpoint)] { inbox.drain().map { ($0.0, $0.1) } }

    public func close() {
        listener?.cancel()
        for c in lock.locked({ Array(connections.values) }) { c.cancel() }
        lock.locked { connections.removeAll() }
    }
}
#endif
