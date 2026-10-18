# Networking

Ferox's networking lives in the `FeroxNet` module. It provides a datagram transport abstraction, a reliability layer over unreliable datagrams, a client and server handshake, typed messages with bounds-checked encoding, and a client-side snapshot interpolator. A deterministic in-process network, `LoopbackNetwork`, lets tests exercise all of this without sockets.

The module is a set of building blocks, not a multiplayer framework. It is not connected to `Engine`, `World` or the scene system. A game that wants multiplayer must create the transport, server or client, drive them each frame, and map received messages onto its own entities. Nothing in it has been compiled or run, and no network traffic has been observed. Its security properties are narrower than a reader might assume, and this document says exactly what they are.

For the frame in which a game would poll the network, see [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md). For the security posture across the engine, see [26-Security.md](26-Security.md).

## Contents

1. [Status and scope](#1-status-and-scope)
2. [Transports](#2-transports)
3. [Connections and channels](#3-connections-and-channels)
4. [The handshake](#4-the-handshake)
5. [Servers and clients](#5-servers-and-clients)
6. [Messages and encoding](#6-messages-and-encoding)
7. [Replication](#7-replication)
8. [Limits](#8-limits)
9. [Security properties](#9-security-properties)
10. [Code examples](#10-code-examples)
11. [Limitations and missing features](#11-limitations-and-missing-features)
12. [Validation status](#12-validation-status)
13. [Related documents](#13-related-documents)

## 1. Status and scope

| Area | Status |
| --- | --- |
| `NetTransport` protocol and `NetEndpoint` | Implemented: `Transport.swift`. |
| `LoopbackNetwork` and `NetworkConditioner` (latency, jitter, loss, duplication) | Implemented. Deterministic with a seed. Platform independent. |
| `UDPTransport` (Network.framework) | Implemented, Apple platforms only. **Not run.** |
| Reliable, ordered, sequenced and unreliable channels | Implemented: `Connection.swift`. |
| Handshake (challenge-response) | Implemented: `Peers.swift`. |
| Typed messages and bounds-checked coding | Implemented: `NetCoding.swift`, `Replication.swift`. |
| Snapshot interpolation | Implemented: `SnapshotInterpolator`. |
| Encryption | **Not implemented** on any path. An optional DTLS wrapper exists for `UDPTransport` and is unverified. |
| Player authentication and accounts | **Not implemented.** |
| NAT traversal, relay, STUN | **Not implemented.** |
| Clock synchronisation | **Not implemented.** |
| Entity replication, prediction, lag compensation | **Not implemented.** |
| Integration with `Engine` | **Not implemented.** No engine code references `FeroxNet`. |
| Automated tests | None in `Tests/` exercise `FeroxNet`. |

## 2. Transports

`NetTransport` is a datagram interface with four members: `localEndpoint`, `send(_:to:)`, `receive()` and `close()`. `receive()` returns the datagrams that have arrived since the last call, and is called on the game thread. Datagrams may be lost, duplicated or reordered, and the layers above are built to tolerate that.

`NetEndpoint` is a host and port pair. Its `description` is `host:port`.

Two implementations exist:

- **`LoopbackTransport`** is created by `LoopbackNetwork.makeTransport(port:host:)`. Transports on the same `LoopbackNetwork` address each other by endpoint. Time is supplied by the caller through `advance(to:)` or `advance(by:)`, so tests are deterministic. The network applies a `NetworkConditioner` to every datagram: a base latency, a random jitter, a loss probability and a duplication probability, all driven by a seeded PRNG. `NetworkConditioner.poorWiFi` is a preset of 60 ms latency, 15 ms jitter, 3 % loss and 0.5 % duplication. Its doc comment in the source describes the link as about 120 ms ± 30 ms, which does not match the values, and the values are what the code uses. The preset is a configuration, not a measurement of any real link.
- **`UDPTransport`** is built on `NWListener` and `NWConnection`. A server listens on a port, with `init(listenOn:security:)`, and creates one connection per remote endpoint. A client connects to one server, with `init(connectingTo:security:)`. Both initialisers throw when the security configuration is invalid. Datagrams over 1400 bytes are dropped on both send and receive, and `maxDatagramSize` holds that value.

`TransportSecurity` chooses the encryption:

- **`.none`**, the default, is plain UDP. It is unencrypted and unauthenticated.
- **`.preSharedKey(identity:passphrase:)`** wraps every datagram in DTLS 1.2 with the TLS-PSK cipher suite `TLS_PSK_WITH_AES_128_GCM_SHA256`. Both ends derive a 32-byte key as HMAC-SHA256(passphrase, identity), so no certificate or private key ships with the game. Only peers that know the passphrase can complete the handshake, read traffic or inject packets.

`validate()` runs before any socket opens. It rejects an empty identity, an identity over `maximumIdentityLength` (128) bytes, and a passphrase under `minimumPassphraseLength` (16) bytes, by throwing `NetDecodeError.invalidValue`.

```swift
let security = TransportSecurity.preSharedKey(identity: "my-game-v1", passphrase: passphraseFromConfig)
let server = NetServer(transport: try UDPTransport(listenOn: 7777, security: security), registry: registry)
```

Keep these limits in mind:

- A passphrase compiled into every client is not a secret from players. PSK protects against eavesdroppers and spoofed packets on the network path, not against a modified client. Keep validating client messages against game rules.
- The setup follows Apple's TLS-PSK pattern, applied to DTLS. It has **not been tested on Apple hardware**. Developer-forum reports describe "bad record mac" handshake failures when the key bytes differ between peers. Check a handshake between two machines before relying on it.
- Do not commit the passphrase to the repository. Load it from configuration that is kept out of source control.

## 3. Connections and channels

`NetConnection` is one side of an established connection. It assigns sequence numbers to packets, records which packets have been acknowledged, retransmits reliable messages, and keeps the statistics in `NetStats`. The type is public, but the server and client create and drive it, and applications reach it through their `stats` members.

Each message is sent on one of three channels, `NetChannel`:

| Channel | Guarantee |
| --- | --- |
| `unreliable` | Fire and forget. May be lost, duplicated or reordered. Duplicates are removed at the packet level. |
| `unreliableSequenced` | Like unreliable, but a message that arrives after a newer one has already been delivered is discarded. Suited to state snapshots. |
| `reliableOrdered` | Delivered exactly once and in order. Retransmitted until acknowledged. |

Acknowledgements travel in every packet header, as the last received sequence number plus a 32-bit mask of the packets before it. Reliable messages are retransmitted after `max(0.1 s, 1.5 × RTT)`. Round-trip time is an exponential moving average, weighted 0.9 to 0.1. `estimatedLoss` is the fraction of packets not acknowledged within one second.

Each connection sends a keep-alive every 0.25 seconds when idle. It times out after 10 seconds without a received packet, by default.

`NetStats` holds the round-trip time, packet and byte counts, the number of retransmissions and the estimated loss. `NetServer.stats(_:)` and `NetClient.stats` expose it for diagnostics.

## 4. The handshake

The handshake is a request, a challenge, a response and an acceptance. Its purpose is to stop spoofed source addresses from creating connections, and to avoid allocating server state for an attacker who never answers.

1. **Connect request.** The client sends its protocol identifier, a protocol version and a random 64-bit client salt. The request is padded to 64 bytes.
2. **Challenge.** The server replies with the client salt and a random 64-bit server salt. No per-client state is created at this point. Challenges expire after five seconds.
3. **Challenge response.** The client sends `serverSalt ^ clientSalt`.
4. **Accept.** The server checks the value against `serverSalt ^ clientSalt`, creates the connection, and sends an accept packet that repeats the value.

The padding on the request means the server's reply is never larger than the request, which prevents the server being used to amplify traffic towards a spoofed address. A version mismatch, or a full server, receives a deny packet with a reason string.

The salts are drawn with `UInt64.random(in:)`, which uses Swift's system random number generator, documented by Swift as cryptographically secure. The source says the same.

Section 9 explains what this handshake does and does not protect.

## 5. Servers and clients

`NetServer` is the authoritative side. It is created with a transport, a `NetMessageRegistry` and a `NetConfig`. Each call to `update(now:)` receives datagrams, handles timeouts, flushes outgoing packets and returns the `NetEvent` values since the last call:

- `connected(ClientID)`
- `disconnected(ClientID, reason:)`
- `message(ClientID, any NetMessage)`

The server offers `send(_:to:channel:)`, `broadcast(_:channel:except:)`, `disconnect(_:reason:)`, `clientIDs` and `stats(_:)`. Messages default to the reliable channel.

`NetClient` connects to one server. `connect(to:now:)` starts the handshake, retrying the request every 0.25 seconds and giving up after five seconds. `update(now:)` returns `ClientEvent` values: `connected`, `connectionFailed(String)`, `disconnected(String)` and `message(any NetMessage)`. Its `state` moves between `disconnected`, `connecting` and `connected`. `disconnect()` sends a disconnect packet and resets the client.

`NetConfig` holds the tunable values:

| Property | Default | Meaning |
| --- | --- | --- |
| `protocolID` | `0xFE70` | Packets with another identifier are ignored. Use a value unique to your game. |
| `protocolVersion` | `1` | Clients with another version are denied. Bump it when messages change. |
| `maxClients` | 16 | Concurrent connections the server accepts. |
| `timeout` | 10 s | Silence after which a connection is dropped. |
| `connectAttemptInterval` | 0.25 s | Interval between client handshake packets. |
| `connectTimeout` | 5 s | Time the client waits before reporting failure. |
| `maxConnectRequestsPerSecond` | 10 | Requests per second accepted from one endpoint. |
| `maxPacketsPerSecond` | 300 | Packets per second accepted from one client. Excess packets are dropped. |

## 6. Messages and encoding

A message type conforms to `NetMessage`. It has a unique `messageID` (identifiers 0 to 999 are reserved for Ferox), an `encode(_:)` method and an `init(from:)` that throws.

`NetWriter` encodes little-endian fixed-width values, LEB128 variable-length integers, zig-zag signed integers, strings and byte blobs. It also writes quantised floats, which map a value in a range onto 16 bits. `NetReader` decodes them. Every read is bounds-checked. Lengths are capped, with `maxLength` of 4096 by default, and strings must be valid UTF-8. Non-finite floats and doubles are rejected. A malformed packet is dropped and logged; decoding is not supposed to trap.

`NetMessageRegistry` maps identifiers to decoders. `register(_:)` is a precondition failure if the identifier is already in use. A received message whose identifier is unknown is dropped with a warning on the server, or ignored on the client.

Each message's payload must be at most `NetConnection.maxMessageSize`, which is 1024 bytes. A larger message is rejected at the send call with a warning.

## 7. Replication

`Replication.swift` defines four built-in messages, registered together by `NetMessageRegistry.registerBuiltins()`:

| ID | Type | Direction and channel | Contents |
| --- | --- | --- | --- |
| 1 | `SnapshotMessage` | Server to client, meant for unreliable-sequenced. | A tick, a server time and up to 128 `ObjectState` values. Each object has a network ID, a position, a rotation and a velocity. |
| 2 | `SpawnMessage` | Server to client, reliable. | A network ID, a prefab name (up to 128 bytes), an owner and a despawn flag. |
| 3 | `InputMessage` | Client to server, unreliable. | A tick, a quantised move vector in [−1, 1] on each axis, and a 32-bit button mask. |
| 4 | `TextMessage` | Either way, reliable. | Text. The encoder writes at most 512 characters, and the decoder accepts at most 2048 bytes. |

`ObjectState` is transform data only. The module does not know what a prefab is, so `SpawnMessage` carries a name, and the game must map that name to something it can create.

`SnapshotInterpolator` runs on the client. It keeps up to 64 snapshots, ignores any that are not newer than the last one, and returns the state of each object at `serverTime − delay`, interpolating position and velocity linearly and rotation by slerp between the two snapshots that bracket that time. The default delay is 0.1 seconds. An object that is missing from the earlier snapshot takes its state from the later one, and an object missing from the later snapshot is not returned. If the requested time is past the newest snapshot, the interpolator extrapolates with the last velocity for at most `maxExtrapolation`, which defaults to 0.25 seconds.

The interpolator needs a server time. The module does not estimate the difference between the client's clock and the server's, so the game must supply one.

## 8. Limits

These values come from the source and set the practical size of what can be sent:

| Limit | Value |
| --- | --- |
| Datagram size on UDP | 1400 bytes (`UDPTransport.maxDatagramSize`) |
| Payload per packet | 1150 bytes (`NetConnection.maxPacketPayload`) |
| Bytes per message | 1024 bytes (`NetConnection.maxMessageSize`) |
| Reliable messages awaiting acknowledgement | 1024 (`maxPendingReliable`) |
| Objects per snapshot | 22 (`SnapshotMessage.maxObjects`); send more with `SnapshotMessage.split(tick:serverTime:objects:)` |
| Decoded string or blob length | 4096 by default (`NetReader.maxLength`) |

The per-message and per-snapshot limits interact. Each object in a snapshot takes about 41 bytes: a one-byte identifier for small IDs, 12 bytes of position, 16 of rotation and 12 of velocity. The header takes about 13 bytes. A 1024-byte message therefore holds roughly 24 objects. A snapshot with more objects than that is larger than the message limit, and `NetConnection.send` drops it with a warning. The 128-object cap in `SnapshotMessage` is not reachable with the default message size. This is worked out from the encoding, not measured.

## 9. Security properties

This section says precisely what the handshake protects against, and what it does not.

**What it does.** The challenge-response makes it hard for an attacker who cannot see traffic to create a connection from a spoofed address, because the attacker never receives the server salt. It also avoids state creation for unanswered requests, limits connection requests and packets per second, and expires challenges. Salts are drawn from a cryptographically secure source.

**What it does not do.** The connection token is `serverSalt ^ clientSalt`. The challenge packet sends both salts in cleartext, so anyone who observes the handshake can compute the token. The token is then written, in cleartext, into the header of every payload, keep-alive, disconnect and accept packet. Consequences:

- An observer on the path can read the token, inject packets that pass the token check, and disconnect either side with a forged disconnect packet.
- The token authenticates nothing about the player. The server assigns a `ClientID` sequentially. There are no accounts, keys or signatures.
- Packets are not encrypted. Messages, including any game state, are readable on the wire.
- Replay protection is limited to the 32-packet window of sequence numbers. A packet whose sequence number has already been seen is dropped, and a packet older than the window is dropped. A captured packet whose sequence number was never delivered, and which still falls inside the window, is accepted. Messages carry no nonce or timestamp, so there is no other replay protection.
- Game-level validation is entirely the game's job. The `InputMessage` documentation says the server treats input as untrusted and should clamp it. The module quantises and bounds the values it decodes, but does not check game rules.

Treat the transport as unencrypted and unauthenticated. The optional DTLS wrapper on `UDPTransport` is the only confidentiality mechanism in the module, and it is unverified. Do not send secrets, and do not trust client messages without checking them against game rules.

## 10. Code examples

A message type, its registration and a server loop:

```swift
struct MoveMessage: NetMessage {
    static let messageID: UInt16 = 100
    var x: Float
    init(x: Float) { self.x = x }
    init(from r: inout NetReader) throws { x = try r.readFloat() }
    func encode(_ w: inout NetWriter) { w.write(x) }
}

let registry = NetMessageRegistry()
registry.registerBuiltins()
registry.register(MoveMessage.self)

let server = NetServer(transport: try UDPTransport(listenOn: 7777), registry: registry)

func networkTick(now: Double) {
    for event in server.update(now: now) {
        switch event {
        case .connected(let id):
            print("\(id) connected")
        case .disconnected(let id, let reason):
            print("\(id) left: \(reason)")
        case .message(let id, let message):
            if let move = message as? MoveMessage { print("\(id) moved \(move.x)") }
        }
    }
}
```

A client that connects and sends a message:

```swift
let serverEndpoint = NetEndpoint(host: "203.0.113.5", port: 7777)
let client = NetClient(transport: try UDPTransport(connectingTo: serverEndpoint), registry: registry)
client.connect(to: serverEndpoint, now: now)

for event in client.update(now: now) {
    if case .connected = event { client.send(MoveMessage(x: 1)) }
}
```

Deterministic testing over a lossy in-process network, stepping time by hand:

```swift
let network = LoopbackNetwork(conditioner: .poorWiFi, seed: 42)
let serverSide = network.makeTransport(port: 7000)
let clientSide = network.makeTransport(port: 7001)
let server = NetServer(transport: serverSide, registry: registry)
let client = NetClient(transport: clientSide, registry: registry)
client.connect(to: serverSide.localEndpoint, now: network.now)

var t = 0.0
while t < 2.0 {
    t += 1.0 / 60
    network.advance(to: t)
    _ = server.update(now: t)
    _ = client.update(now: t)
}
```

Smoothing remote objects on the client:

```swift
var interpolator = SnapshotInterpolator(delay: 0.1)
// on each received snapshot:
// interpolator.add(snapshot)
let states = interpolator.sample(serverTime: estimatedServerTime)
for (netID, state) in states {
    print(netID, state.position)
}
```

## 11. Limitations and missing features

- **No encryption.** Packets are cleartext. The DTLS option on `UDPTransport` is unverified.
- **No authentication.** Clients have no identity beyond a server-assigned number. The token is visible to any observer.
- **No replay protection beyond the ack window.** See section 9.
- **No NAT traversal, relay or discovery.** A server must be reachable at a known address and port. Nothing finds servers or passes packets through a relay.
- **No clock synchronisation.** The client receives server times but cannot estimate its clock offset.
- **No engine integration.** No code in `Engine`, `World` or the scene system creates, polls or drives a network object. The game does this.
- **No entity replication.** The snapshot carries transforms. Spawns and despawns are messages with a prefab name. No code maps them to entities.
- **No prediction, reconciliation or lag compensation.** Clients render interpolated remote state only.
- **Snapshot size limit.** Snapshots larger than about 24 objects exceed the 1024-byte message limit and are dropped. Large worlds need the game to split snapshots itself.
- **No message fragmentation.** A message larger than 1024 bytes cannot be sent.
- **No congestion control or bandwidth budget.** Retransmission is timed, but nothing limits the send rate or prioritises objects.
- **No compression beyond quantisation.** Only `InputMessage` uses quantised values.
- **UDP is Apple-only.** `UDPTransport` requires Network.framework. The loopback transport is available everywhere.
- **Single-threaded use.** Servers and clients are driven from one thread. Only the UDP receive path runs on another queue, and it hands datagrams over through a thread-safe queue.

## 12. Validation status

This document was written from the source. No macOS machine or Swift toolchain was available while the engine was written. Nothing in `FeroxNet` has been compiled, and no packet has been sent over a socket or simulated through `LoopbackNetwork` in any run that this document reports. The latency and loss values in `NetworkConditioner.poorWiFi` are design presets, not measurements.

`Tests/FeroxSubsystemTests/NetTests.swift` covers the reader and writer, decoder bounds, snapshot limits and splitting, the message registry, sequence wrap-around, reliable delivery, duplicate and malformed packets, the loopback transport and a client–server handshake. Those tests have not yet been run on a toolchain. The UDP and DTLS paths are not tested and have not been tried on a device.

## 13. Related documents

- [03-Architecture.md](03-Architecture.md) for where `FeroxNet` sits in the module graph.
- [05-Engine-Lifecycle.md](05-Engine-Lifecycle.md) for the frame in which a game polls the network.
- [06-Scene-and-Entities.md](06-Scene-and-Entities.md) for the entities that replicated objects would map onto.
- [14-Input.md](14-Input.md) for the local input that a client would send as `InputMessage`.
- [20-Gameplay-API.md](20-Gameplay-API.md) for the `Game` hooks where a game would drive a server or client.
- [25-Platform-Support.md](25-Platform-Support.md) for which platforms have the UDP transport.
- [26-Security.md](26-Security.md) for the engine's security posture across all modules.
- [28-Limitations-and-Roadmap.md](28-Limitations-and-Roadmap.md) for planned networking work.
