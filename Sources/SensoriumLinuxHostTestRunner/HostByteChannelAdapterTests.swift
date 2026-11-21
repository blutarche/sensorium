#if os(Linux)
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumHost
import SensoriumLinuxHost

/// A host session reads and writes the viewer's stream through
/// `HostByteChannel`; the Linux server's channel is that stream.
func testTheServerChannelCarriesAHostSessionsBytes() async throws {
    let identity = try HostTLSIdentity.generate(commonName: "Sensorium Host")
    let (server, collector) = try runningServer(identity: identity)
    defer { server.stop() }
    let client = OpenSSLQUICConnection(
        host: "127.0.0.1",
        port: server.boundPort,
        tlsCertificateHash: identity.certificateHash
    )
    try await client.start(timeout: 10)
    let channel: any HostByteChannel = try await collector.next(timeout: 5)
    channel.start()
    try require(channel.peerAddress == nil, "the server names no peer address, so a session logs none")

    let hello = SensoriumTransportPacket.unrecognized(tag: 0x40, payload: Data("hello host".utf8))
    try await client.send(hello)
    let header = try await withDeadline(10, "reading the header") { try await channel.receiveBytes(count: 5) }
    let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
    let payload = try await withDeadline(10, "reading the payload") { try await channel.receiveBytes(count: length) }
    let received = try SensoriumTransportPacketCodec.decode(header + payload)
    try require(received == hello, "the session read what the viewer sent")

    let reply = SensoriumTransportPacket.unrecognized(tag: 0x41, payload: Data("hello viewer".utf8))
    try await channel.sendBytes(try SensoriumTransportPacketCodec.encode(reply))
    let answered = try await withDeadline(10, "the viewer reading the reply") { try await client.receiveWirePacket() }
    try require(answered == reply, "the viewer read what the session sent")

    channel.cancel()
    await client.close()
}
#endif
