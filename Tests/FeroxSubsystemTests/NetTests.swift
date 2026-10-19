import FeroxCore
/// Tests for the networking layer without real sockets: binary coding and bounded decoding, message
/// round trips and caps, sequence arithmetic, connection packet framing, reliable delivery over
/// the in-memory loopback network, and a client-server handshake.
import XCTest

@testable import FeroxNet

final class NetTests: XCTestCase {

    private let protocolID: UInt16 = 0xFE70

    /// True when `event` is a `.connected` server event.
    private func isConnected(_ event: NetEvent) -> Bool {
        if case .connected = event { return true }
        return false
    }

    /// Writes and reads back every primitive kind and checks the values survive unchanged.
    func testWriterAndReaderRoundTripPrimitives() throws {
        var w = NetWriter()
        w.write(UInt8(0xAB))
        w.write(true)
        w.write(UInt16(0xBEEF))
        w.write(UInt32(0xDEAD_BEEF))
        w.write(UInt64(1) << 40)
        w.write(Float(1.5))
        w.write(Double(-2.25))
        w.write("héllo")
        w.writeVarUInt(300)
        w.writeVarInt(-3)

        var r = NetReader(w.bytes)
        XCTAssertEqual(try r.readUInt8(), 0xAB)
        XCTAssertEqual(try r.readBool(), true)
        XCTAssertEqual(try r.readUInt16(), 0xBEEF)
        XCTAssertEqual(try r.readUInt32(), 0xDEAD_BEEF)
        XCTAssertEqual(try r.readUInt64(), UInt64(1) << 40)
        XCTAssertEqual(try r.readFloat(), 1.5)
        XCTAssertEqual(try r.readDouble(), -2.25)
        XCTAssertEqual(try r.readString(), "héllo")
        XCTAssertEqual(try r.readVarUInt(), 300)
        XCTAssertEqual(try r.readVarInt(), -3)
        XCTAssertTrue(r.isAtEnd)
    }

    /// Truncated, over-long and non-UTF-8 strings are rejected with the matching decode error.
    func testReaderRejectsMalformedStrings() {
        var truncated = NetReader([5, 0x61])
        XCTAssertThrowsError(try truncated.readString()) {
            XCTAssertEqual($0 as? NetDecodeError, .truncated)
        }

        var lengthPrefix = NetWriter()
        lengthPrefix.writeVarUInt(5000)
        var overlong = NetReader(lengthPrefix.bytes + [UInt8](repeating: 0x61, count: 5000))
        XCTAssertThrowsError(try overlong.readString()) {
            XCTAssertEqual($0 as? NetDecodeError, .lengthExceeded(5000, max: 4096))
        }

        var invalid = NetReader([1, 0xFF])
        XCTAssertThrowsError(try invalid.readString()) {
            XCTAssertEqual($0 as? NetDecodeError, .invalidValue("invalid UTF-8"))
        }
    }

    /// A snapshot with several objects encodes and decodes to an equal message.
    func testSnapshotRoundTripsObjectStates() throws {
        let objects = [
            ObjectState(netID: 7, position: Vec3(1, 2, 3), rotation: .identity, velocity: Vec3(0, -1, 0)),
            ObjectState(netID: 42, position: Vec3(-4, 0, 9), rotation: .identity),
        ]
        let message = SnapshotMessage(tick: 99, serverTime: 12.5, objects: objects)
        var w = NetWriter()
        message.encode(&w)

        var r = NetReader(w.bytes)
        let decoded = try SnapshotMessage(from: &r)
        XCTAssertEqual(decoded, message)
        XCTAssertTrue(r.isAtEnd)
    }

    /// Encoding caps a snapshot at 128 objects, and decoding rejects a forged count above that cap.
    func testSnapshotEncodingIsCappedAndForgedCountIsRejected() throws {
        let many = (0..<200).map { ObjectState(netID: UInt32($0), position: .zero, rotation: .identity) }
        var w = NetWriter()
        SnapshotMessage(tick: 1, serverTime: 0, objects: many).encode(&w)
        var r = NetReader(w.bytes)
        let decoded = try SnapshotMessage(from: &r)
        XCTAssertEqual(decoded.objects.count, SnapshotMessage.maxObjects)

        var forged = NetWriter()
        forged.write(UInt32(1))
        forged.write(Double(0))
        let forgedCount = SnapshotMessage.maxObjects + 1
        forged.writeVarUInt(UInt64(forgedCount))
        var forgedReader = NetReader(forged.bytes)
        XCTAssertThrowsError(try SnapshotMessage(from: &forgedReader)) {
            XCTAssertEqual($0 as? NetDecodeError, .lengthExceeded(forgedCount, max: SnapshotMessage.maxObjects))
        }
    }

    /// A full snapshot with worst-case net ids still fits in one message.
    func testFullSnapshotFitsMessageSize() {
        let objects = (0..<SnapshotMessage.maxObjects).map {
            ObjectState(
                netID: UInt32.max - UInt32($0), position: Vec3(1, 2, 3), rotation: .identity, velocity: Vec3(4, 5, 6))
        }
        var w = NetWriter()
        SnapshotMessage(tick: .max, serverTime: 1e9, objects: objects).encode(&w)
        XCTAssertLessThanOrEqual(w.bytes.count, NetConnection.maxMessageSize)
    }

    /// split keeps every object, in order, across messages within the cap.
    func testSnapshotSplitCoversAllObjects() {
        let objects = (0..<50).map { ObjectState(netID: UInt32($0), position: .zero, rotation: .identity) }
        let parts = SnapshotMessage.split(tick: 7, serverTime: 1, objects: objects)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.objects.count <= SnapshotMessage.maxObjects && $0.tick == 7 })
        XCTAssertEqual(parts.flatMap(\.objects), objects)
        XCTAssertEqual(SnapshotMessage.split(tick: 0, serverTime: 0, objects: []).count, 1)
    }

    /// Text messages are truncated to 512 characters on encode, and decoding rejects text over 2048 bytes.
    func testTextMessageIsTruncatedOnEncodeAndBoundedOnDecode() throws {
        var w = NetWriter()
        TextMessage(String(repeating: "a", count: 600)).encode(&w)
        var r = NetReader(w.bytes)
        XCTAssertEqual(try TextMessage(from: &r).text.count, 512)

        var forged = NetWriter()
        forged.write(String(repeating: "b", count: 3000))
        var forgedReader = NetReader(forged.bytes)
        XCTAssertThrowsError(try TextMessage(from: &forgedReader)) {
            XCTAssertEqual($0 as? NetDecodeError, .lengthExceeded(3000, max: 2048))
        }
    }

    /// The registry decodes registered message ids and reports unknown ids as errors.
    func testRegistryDecodesRegisteredTypesAndRejectsUnknownIDs() throws {
        let registry = NetMessageRegistry()
        registry.register(SnapshotMessage.self)
        registry.register(TextMessage.self)
        XCTAssertTrue(registry.isRegistered(SnapshotMessage.messageID))
        XCTAssertFalse(registry.isRegistered(999))

        var w = NetWriter()
        TextMessage("hello").encode(&w)
        var r = NetReader(w.bytes)
        let decoded = try registry.decode(id: TextMessage.messageID, &r)
        XCTAssertEqual((decoded as? TextMessage)?.text, "hello")

        var empty = NetReader([])
        XCTAssertThrowsError(try registry.decode(id: 999, &empty)) {
            XCTAssertEqual($0 as? NetDecodeError, .unknownMessage(999))
        }
    }

    /// Sequence comparison treats numbers just above the previous value as newer, including across the 16-bit wrap.
    func testSequenceComparisonHandlesWraparound() {
        XCTAssertTrue(sequenceGreater(1, 0))
        XCTAssertFalse(sequenceGreater(0, 1))
        XCTAssertFalse(sequenceGreater(5, 5))
        XCTAssertTrue(sequenceGreater(0, 65535))
        XCTAssertFalse(sequenceGreater(65535, 0))
        XCTAssertTrue(sequenceGreater(100, 40000))
    }

    /// A reliable message flushed into a packet is delivered intact to a peer connection with the same token.
    func testFlushedReliableMessageIsDeliveredToPeer() throws {
        let endpoint = NetEndpoint(host: "peer", port: 1)
        let sender = NetConnection(endpoint: endpoint, token: 0xABCD, protocolID: protocolID, now: 0)
        let receiver = NetConnection(endpoint: endpoint, token: 0xABCD, protocolID: protocolID, now: 0)
        XCTAssertTrue(sender.send(type: 7, payload: [1, 2, 3], channel: .reliableOrdered))

        let packet = try XCTUnwrap(sender.flush(now: 0).first)
        XCTAssertEqual(packet[0], 0x70)
        XCTAssertEqual(packet[2], PacketType.payload.rawValue)
        var reader = NetReader(Array(packet.dropFirst(3)))
        try receiver.receive(&reader, now: 0)

        let inbox = receiver.takeInbox()
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.first?.0, 7)
        XCTAssertEqual(inbox.first?.1, [1, 2, 3])
    }

    /// A duplicated packet is delivered once, while packets with a foreign token or an unknown channel are rejected.
    func testDuplicatePacketIsIgnoredAndMalformedPacketsAreRejected() throws {
        let endpoint = NetEndpoint(host: "peer", port: 1)
        let sender = NetConnection(endpoint: endpoint, token: 0xABCD, protocolID: protocolID, now: 0)
        let receiver = NetConnection(endpoint: endpoint, token: 0xABCD, protocolID: protocolID, now: 0)
        sender.send(type: 7, payload: [9], channel: .reliableOrdered)
        let packet = try XCTUnwrap(sender.flush(now: 0).first)

        var first = NetReader(Array(packet.dropFirst(3)))
        try receiver.receive(&first, now: 0)
        var duplicate = NetReader(Array(packet.dropFirst(3)))
        try receiver.receive(&duplicate, now: 0)
        XCTAssertEqual(receiver.takeInbox().count, 1)

        let stranger = NetConnection(endpoint: endpoint, token: 0x1234, protocolID: protocolID, now: 0)
        var wrongToken = NetReader(Array(packet.dropFirst(3)))
        XCTAssertThrowsError(try stranger.receive(&wrongToken, now: 0)) {
            XCTAssertEqual($0 as? NetDecodeError, .invalidValue("token mismatch"))
        }

        var forged = NetWriter()
        forged.write(UInt64(0xABCD))
        forged.write(UInt16(1))
        forged.write(UInt16(0))
        forged.write(UInt32(0))
        forged.write(UInt8(9))
        var unknownChannel = NetReader(forged.bytes)
        XCTAssertThrowsError(try receiver.receive(&unknownChannel, now: 0)) {
            XCTAssertEqual($0 as? NetDecodeError, .invalidValue("channel"))
        }
    }

    /// Messages above the size limit are refused, and the reliable buffer stops accepting messages when full.
    func testSendRejectsOversizedMessagesAndCapsReliableBuffer() {
        let endpoint = NetEndpoint(host: "peer", port: 1)
        let connection = NetConnection(endpoint: endpoint, token: 1, protocolID: protocolID, now: 0)
        let oversized = [UInt8](repeating: 0, count: NetConnection.maxMessageSize + 1)
        XCTAssertFalse(connection.send(type: 1, payload: oversized, channel: .reliableOrdered))
        XCTAssertEqual(connection.pendingReliableCount, 0)

        for _ in 0..<(NetConnection.maxPendingReliable + 10) {
            connection.send(type: 2, payload: [0], channel: .reliableOrdered)
        }
        XCTAssertEqual(connection.pendingReliableCount, NetConnection.maxPendingReliable)
    }

    /// A loopback datagram is only delivered once simulated time reaches the configured latency.
    func testLoopbackDeliversDatagramOnlyAfterLatency() {
        let network = LoopbackNetwork(conditioner: NetworkConditioner(latency: 0.1))
        let a = network.makeTransport(port: 1)
        let b = network.makeTransport(port: 2)
        a.send([1, 2, 3], to: b.localEndpoint)

        network.advance(to: 0.05)
        XCTAssertTrue(b.receive().isEmpty)
        network.advance(to: 0.1)
        let received = b.receive()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.bytes, [1, 2, 3])
        XCTAssertEqual(received.first?.from, a.localEndpoint)
    }

    /// A fully lossy link drops every datagram and records the drops.
    func testFullyLossyLoopbackDropsEveryDatagram() {
        let network = LoopbackNetwork(conditioner: NetworkConditioner(loss: 1))
        let a = network.makeTransport(port: 1)
        let b = network.makeTransport(port: 2)
        for _ in 0..<5 {
            a.send([0], to: b.localEndpoint)
        }
        network.advance(by: 1)
        XCTAssertTrue(b.receive().isEmpty)
        XCTAssertEqual(network.sentCount, 5)
        XCTAssertEqual(network.droppedCount, 5)
    }

    /// A client connects to a server over loopback and a text message sent by the client reaches the server.
    func testClientServerHandshakeDeliversMessage() {
        let network = LoopbackNetwork()
        let registry = NetMessageRegistry()
        registry.register(TextMessage.self)
        let serverTransport = network.makeTransport(port: 7777)
        let clientTransport = network.makeTransport(port: 7778)
        let server = NetServer(transport: serverTransport, registry: registry)
        let client = NetClient(transport: clientTransport, registry: registry)
        client.connect(to: serverTransport.localEndpoint, now: 0)

        var serverEvents: [NetEvent] = []
        var time = 0.0
        func pump(_ steps: Int) {
            for _ in 0..<steps {
                time += 0.05
                network.advance(to: time)
                serverEvents += server.update(now: time)
                _ = client.update(now: time)
            }
        }

        pump(40)
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(serverEvents.contains(where: { self.isConnected($0) }))

        client.send(TextMessage("hi"))
        pump(10)
        let texts = serverEvents.compactMap { event -> String? in
            if case .message(_, let message) = event { return (message as? TextMessage)?.text }
            return nil
        }
        XCTAssertEqual(texts, ["hi"])
    }

    /// Plain UDP needs no validation; a PSK needs a 1–128 byte identity and a passphrase of at least 16 bytes.
    func testTransportSecurityValidation() throws {
        XCTAssertNoThrow(try TransportSecurity.none.validate())
        XCTAssertFalse(TransportSecurity.none.isEncrypted)

        let good = TransportSecurity.preSharedKey(identity: "game-v1", passphrase: String(repeating: "k", count: 16))
        XCTAssertNoThrow(try good.validate())
        XCTAssertTrue(good.isEncrypted)

        let short = TransportSecurity.preSharedKey(identity: "game-v1", passphrase: String(repeating: "k", count: 15))
        XCTAssertThrowsError(try short.validate())
        let noIdentity = TransportSecurity.preSharedKey(identity: "", passphrase: String(repeating: "k", count: 32))
        XCTAssertThrowsError(try noIdentity.validate())
        let longIdentity = TransportSecurity.preSharedKey(
            identity: String(repeating: "i", count: TransportSecurity.maximumIdentityLength + 1),
            passphrase: String(repeating: "k", count: 32))
        XCTAssertThrowsError(try longIdentity.validate())
    }
}
