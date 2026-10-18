import FeroxCore
import Foundation

#if canImport(Network)
import CryptoKit
import Network
import Security
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
    /// A typical poor Wi-Fi link: 60 ms ± 15 ms each way (≈ 120 ms round trip), 3 % loss.
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

/// Encryption for `UDPTransport`.
///
/// `.none` sends plain UDP: unencrypted and unauthenticated. `.preSharedKey` wraps every
/// datagram in DTLS 1.2 with a TLS-PSK cipher suite (`TLS_PSK_WITH_AES_128_GCM_SHA256`):
/// server and clients derive the same key from a shared passphrase, so no certificate or
/// private key ships with the game. Only peers that know the passphrase can complete the
/// handshake, read traffic or inject packets. This is the pattern of Apple's TLS-PSK
/// sample code ("Building a custom peer-to-peer protocol"), applied to DTLS.
///
/// A passphrase compiled into every client is not a secret from players: PSK protects
/// against eavesdroppers and spoofed packets on the network path, not against a modified
/// client. Keep validating client messages against game rules either way.
public enum TransportSecurity: Sendable, Hashable {
    case none
    /// DTLS-PSK. `identity` names the key (sent in clear during the handshake) and must
    /// match on both ends; `passphrase` must be at least `minimumPassphraseLength` bytes.
    case preSharedKey(identity: String, passphrase: String)

    public static let minimumPassphraseLength = 16
    public static let maximumIdentityLength = 128

    /// Checks the configuration before any socket is opened.
    public func validate() throws {
        guard case let .preSharedKey(identity, passphrase) = self else { return }
        guard !identity.isEmpty, identity.utf8.count <= Self.maximumIdentityLength else {
            throw NetDecodeError.invalidValue("PSK identity must be 1–\(Self.maximumIdentityLength) bytes")
        }
        guard passphrase.utf8.count >= Self.minimumPassphraseLength else {
            throw NetDecodeError.invalidValue("PSK passphrase must be at least \(Self.minimumPassphraseLength) bytes")
        }
    }

    public var isEncrypted: Bool { self != .none }
}

#if canImport(Network)
/// UDP transport using Network.framework.
///
/// Server mode listens on a port and creates a connection per remote endpoint; client
/// mode connects to one server. Received datagrams are queued and drained on the game
/// thread by `receive()`. Datagrams larger than `maxDatagramSize` are dropped.
///
/// Transport security: `TransportSecurity.none` is plain UDP, unencrypted and
/// unauthenticated. For real deployments pass `.preSharedKey`, which wraps traffic in
/// DTLS-PSK, and keep game-level validation regardless (see Docs/23-Networking.md).
public final class UDPTransport: NetTransport, @unchecked Sendable {
    public private(set) var localEndpoint: NetEndpoint
    public static let maxDatagramSize = 1400
    private let queue = DispatchQueue(label: "dev.ferox.net.udp")
    private var listener: NWListener?
    private var connections: [NetEndpoint: NWConnection] = [:]
    private let inbox = ThreadSafeQueue<([UInt8], NetEndpoint)>()
    private let lock = NSLock()
    private let parameters: NWParameters

    /// Builds the Network.framework parameters for `security`.
    static func makeParameters(_ security: TransportSecurity) throws -> NWParameters {
        try security.validate()
        guard case let .preSharedKey(identity, passphrase) = security else { return .udp }
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        // The key is HMAC-SHA256(passphrase, identity): 32 raw bytes, identical on both ends.
        let key = SymmetricKey(data: Data(passphrase.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: key)
        let psk = code.withUnsafeBytes { DispatchData(bytes: $0) }
        let id = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, psk as __DispatchData, id as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }
        // TLS-PSK suites are TLS 1.2 suites, so pin DTLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(sec, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .DTLSv12)
        return NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
    }

    /// Creates a server transport listening on `port` (0 = ephemeral).
    public init(listenOn port: UInt16, security: TransportSecurity = .none) throws {
        parameters = try Self.makeParameters(security)
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

    /// Creates a client transport connected to `server`. Throws only for an invalid
    /// `security` configuration; connection failures are logged when they happen.
    public init(connectingTo server: NetEndpoint, security: TransportSecurity = .none) throws {
        parameters = try Self.makeParameters(security)
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
