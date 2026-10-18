import FeroxCore
import Foundation

/// Delivery guarantees per message.
public enum NetChannel: UInt8, Sendable, CaseIterable {
    /// Fire-and-forget; may be lost, duplicated or reordered (deduplicated by packet).
    case unreliable = 0
    /// Like unreliable, but older messages arriving after newer ones are dropped
    /// (good for state snapshots).
    case unreliableSequenced = 1
    /// Delivered exactly once, in order, retransmitted until acknowledged.
    case reliableOrdered = 2
}

/// Statistics for diagnostics overlays and tests.
public struct NetStats: Sendable, Hashable {
    public var rtt: Double = 0
    public var packetsSent = 0
    public var packetsReceived = 0
    public var packetsAcked = 0
    public var bytesSent = 0
    public var bytesReceived = 0
    public var retransmissions = 0
    /// Fraction of recent packets not acknowledged within one second.
    public var estimatedLoss: Double = 0
}

enum PacketType: UInt8 {
    case connectRequest = 0, challenge, challengeResponse, accept, deny, payload, disconnect, keepAlive
}

/// Wrap-around aware sequence comparison (RFC 1982 style, 16-bit).
@inline(__always) func sequenceGreater(_ a: UInt16, _ b: UInt16) -> Bool {
    (a > b && a &- b <= 32768) || (a < b && b &- a > 32768)
}

/// One side of an established connection: sequencing, acknowledgements, reliability,
/// ordering and keep-alives. Transport- and role-agnostic; used by `NetServer`/`NetClient`.
public final class NetConnection {
    public let endpoint: NetEndpoint
    public let token: UInt64
    public private(set) var stats = NetStats()
    public private(set) var lastReceiveTime: Double
    public var timeout: Double = 10
    public var keepAliveInterval: Double = 0.25
    /// Maximum outgoing bytes per packet (fits common MTUs with headers).
    public static let maxPacketPayload = 1150
    /// Maximum bytes of a single message.
    public static let maxMessageSize = 1024
    /// Reliable messages queued but not yet acknowledged (backpressure limit).
    public static let maxPendingReliable = 1024

    let protocolID: UInt16
    private var localSeq: UInt16 = 0
    private var remoteSeq: UInt16 = 0
    private var receivedBits: UInt32 = 0  // bit i = remoteSeq - 1 - i received
    private var hasRemoteSeq = false
    private var sentTimes: [UInt16: Double] = [:]
    private var packetMessages: [UInt16: [UInt16]] = [:]
    private var lastSend: Double = 0

    // Reliable send state
    private struct PendingReliable {
        var seq: UInt16
        var type: UInt16
        var payload: [UInt8]
        var lastSent: Double
    }
    private var nextReliableSeq: UInt16 = 0
    private var pending: [UInt16: PendingReliable] = [:]
    private var pendingOrder: [UInt16] = []

    // Reliable receive state
    private var expectedReliable: UInt16 = 0
    private var reorderBuffer: [UInt16: (UInt16, [UInt8])] = [:]

    // Unreliable send queue / sequenced receive state
    private var outgoingUnreliable: [(NetChannel, UInt16, [UInt8])] = []
    private var lastSequencedPacket: UInt16 = 0
    private var hasSequenced = false

    /// Messages received and ready for the application: (type, payload).
    private(set) var inbox: [(UInt16, [UInt8])] = []

    private var ackWindow: [(Double, Bool)] = []

    init(endpoint: NetEndpoint, token: UInt64, protocolID: UInt16, now: Double) {
        self.endpoint = endpoint
        self.token = token
        self.protocolID = protocolID
        lastReceiveTime = now
        lastSend = now
    }

    func timedOut(now: Double) -> Bool { now - lastReceiveTime > timeout }

    /// Queues a message.
    @discardableResult
    func send(type: UInt16, payload: [UInt8], channel: NetChannel) -> Bool {
        guard payload.count <= NetConnection.maxMessageSize else {
            Log.warning("Net", "Message \(type) of \(payload.count) bytes exceeds maxMessageSize; dropped")
            return false
        }
        switch channel {
        case .reliableOrdered:
            guard pending.count < NetConnection.maxPendingReliable else {
                Log.warning("Net", "Reliable send buffer full for \(endpoint); message dropped")
                return false
            }
            let s = nextReliableSeq
            nextReliableSeq &+= 1
            pending[s] = PendingReliable(seq: s, type: type, payload: payload, lastSent: -1)
            pendingOrder.append(s)
        case .unreliable, .unreliableSequenced:
            outgoingUnreliable.append((channel, type, payload))
        }
        return true
    }

    func takeInbox() -> [(UInt16, [UInt8])] {
        defer { inbox.removeAll(keepingCapacity: true) }
        return inbox
    }

    /// Builds the packets to transmit now (payloads, retransmissions, keep-alives).
    func flush(now: Double) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        let resendAfter = max(0.1, stats.rtt * 1.5)
        var reliableToSend: [PendingReliable] = []
        for s in pendingOrder {
            guard let p = pending[s] else { continue }
            if p.lastSent < 0 || now - p.lastSent >= resendAfter {
                if p.lastSent >= 0 { stats.retransmissions += 1 }
                reliableToSend.append(p)
            }
        }
        var unreliable = outgoingUnreliable
        outgoingUnreliable.removeAll(keepingCapacity: true)
        while !reliableToSend.isEmpty || !unreliable.isEmpty || (now - lastSend >= keepAliveInterval && packets.isEmpty) {
            var w = NetWriter(capacity: 1200)
            let seq = localSeq
            localSeq &+= 1
            writeHeader(&w, type: (reliableToSend.isEmpty && unreliable.isEmpty) ? .keepAlive : .payload, seq: seq)
            var contained: [UInt16] = []
            while let p = reliableToSend.first, w.bytes.count + p.payload.count + 8 <= NetConnection.maxPacketPayload {
                w.write(NetChannel.reliableOrdered.rawValue)
                w.write(p.type)
                w.write(p.seq)
                w.write(p.payload)
                contained.append(p.seq)
                pending[p.seq]?.lastSent = now
                reliableToSend.removeFirst()
            }
            while let u = unreliable.first, w.bytes.count + u.2.count + 6 <= NetConnection.maxPacketPayload {
                w.write(u.0.rawValue)
                w.write(u.1)
                w.write(u.2)
                unreliable.removeFirst()
            }
            if !contained.isEmpty { packetMessages[seq] = contained }
            sentTimes[seq] = now
            ackWindow.append((now, false))
            packets.append(w.bytes)
            stats.packetsSent += 1
            stats.bytesSent += w.bytes.count
            lastSend = now
            if contained.isEmpty && w.bytes.count <= 21 && (!reliableToSend.isEmpty || !unreliable.isEmpty) {
                // A single message larger than the packet budget cannot be sent; drop it.
                if !reliableToSend.isEmpty { reliableToSend.removeFirst() }
                if !unreliable.isEmpty { unreliable.removeFirst() }
            }
        }
        // Forget very old send times and update the loss estimate.
        if sentTimes.count > 2048 {
            for k in sentTimes.keys where now - (sentTimes[k] ?? now) > 5 { sentTimes[k] = nil; packetMessages[k] = nil }
        }
        ackWindow.removeAll { now - $0.0 > 3 }
        let old = ackWindow.filter { now - $0.0 > 1 }
        if !old.isEmpty { stats.estimatedLoss = Double(old.filter { !$0.1 }.count) / Double(old.count) }
        return packets
    }

    func writeHeader(_ w: inout NetWriter, type: PacketType, seq: UInt16) {
        w.write(protocolID)
        w.write(type.rawValue)
        w.write(token)
        w.write(seq)
        w.write(remoteSeq)
        w.write(receivedBits)
    }

    /// Processes a payload/keep-alive packet body (after protocol id and type).
    func receive(_ r: inout NetReader, now: Double) throws {
        guard try r.readUInt64() == token else { throw NetDecodeError.invalidValue("token mismatch") }
        let seq = try r.readUInt16()
        let ack = try r.readUInt16()
        let ackBits = try r.readUInt32()
        lastReceiveTime = now
        stats.packetsReceived += 1
        stats.bytesReceived += r.bytes.count

        // Duplicate packet detection and ack bookkeeping.
        if !hasRemoteSeq {
            hasRemoteSeq = true
            remoteSeq = seq
            receivedBits = 0
        } else if sequenceGreater(seq, remoteSeq) {
            let shift = Int(seq &- remoteSeq)
            receivedBits = shift >= 32 ? 0 : (receivedBits << UInt32(shift)) | (1 << UInt32(shift - 1))
            remoteSeq = seq
        } else {
            let diff = Int(remoteSeq &- seq)
            if diff == 0 { return }  // duplicate
            if diff <= 32 {
                let bit: UInt32 = 1 << UInt32(diff - 1)
                if receivedBits & bit != 0 { return }  // duplicate
                receivedBits |= bit
            } else {
                return  // too old
            }
        }
        processAcks(ack: ack, bits: ackBits, now: now)
        let isNewest = seq == remoteSeq

        // Messages
        while !r.isAtEnd {
            guard let channel = NetChannel(rawValue: try r.readUInt8()) else { throw NetDecodeError.invalidValue("channel") }
            let type = try r.readUInt16()
            switch channel {
            case .reliableOrdered:
                let mseq = try r.readUInt16()
                let payload = try r.readBytes(max: NetConnection.maxMessageSize)
                if mseq == expectedReliable {
                    inbox.append((type, payload))
                    expectedReliable &+= 1
                    while let next = reorderBuffer.removeValue(forKey: expectedReliable) {
                        inbox.append(next)
                        expectedReliable &+= 1
                    }
                } else if sequenceGreater(mseq, expectedReliable) {
                    guard reorderBuffer.count < NetConnection.maxPendingReliable else { continue }
                    reorderBuffer[mseq] = (type, payload)
                }
            case .unreliable:
                inbox.append((type, try r.readBytes(max: NetConnection.maxMessageSize)))
            case .unreliableSequenced:
                let payload = try r.readBytes(max: NetConnection.maxMessageSize)
                if isNewest || !hasSequenced || sequenceGreater(seq, lastSequencedPacket) {
                    inbox.append((type, payload))
                    lastSequencedPacket = seq
                    hasSequenced = true
                }
            }
        }
    }

    private func processAcks(ack: UInt16, bits: UInt32, now: Double) {
        func acked(_ s: UInt16) {
            if let t = sentTimes.removeValue(forKey: s) {
                let sample = now - t
                stats.rtt = stats.rtt == 0 ? sample : stats.rtt * 0.9 + sample * 0.1
                stats.packetsAcked += 1
                if let i = ackWindow.firstIndex(where: { abs($0.0 - t) < 1e-9 && !$0.1 }) { ackWindow[i].1 = true }
            }
            if let msgs = packetMessages.removeValue(forKey: s) {
                for m in msgs { pending[m] = nil }
                pendingOrder.removeAll { pending[$0] == nil }
            }
        }
        acked(ack)
        for i in 0..<32 where bits & (1 << UInt32(i)) != 0 { acked(ack &- UInt16(i + 1)) }
    }

    /// Number of reliable messages still awaiting acknowledgement.
    public var pendingReliableCount: Int { pending.count }
}
