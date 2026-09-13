import Foundation
import SensoriumClient
import SensoriumCore

/// Fails every `send`, standing in for a machine that never answers -- the case
/// `sendPairIntent` must propagate rather than swallow, since the Code
/// screen turns that failure into "not reachable" copy.
private actor FailingSendTransport: SensoriumControlTransport {
    private(set) var closeCount = 0
    let deferredPackets = DeferredPacketQueue()

    func send(_ message: SensoriumMessage) async throws {
        throw ControlChannelError.closed
    }

    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        throw ControlChannelError.closed
    }

    func close() async {
        closeCount += 1
    }
}

@MainActor
func testClientSessionControllerPairIntentTests() async {
    do {
        // The Code screen's own send: exactly one pairIntent, the
        // device's claimed name, nothing else on the wire.
        let identity = try! DeviceIdentity.generate()
        let transport = ScriptedClientTransport(responses: [])
        let controller = ClientSessionController(transport: transport, identity: identity)

        try! await controller.sendPairIntent(deviceName: "MacBook")

        expect(
            await transport.sent == [.pairIntent(deviceName: "MacBook")],
            "sendPairIntent puts exactly one pairIntent, carrying the given name, on the wire"
        )

        print("PASS: sendPairIntent sends exactly one pairIntent carrying the device's name")
    }

    do {
        // An unreachable host must surface as a thrown error, not a
        // silently dropped message -- the Code screen's own closure
        // is what turns this into "not reachable" copy.
        let identity = try! DeviceIdentity.generate()
        let transport = FailingSendTransport()
        let controller = ClientSessionController(transport: transport, identity: identity)

        do {
            try await controller.sendPairIntent(deviceName: "MacBook")
            expect(false, "a transport that fails to send must not be reported as a successful pairIntent")
        } catch {
            expect(true, "sendPairIntent propagates a transport failure instead of swallowing it")
        }

        print("PASS: sendPairIntent propagates a transport failure to its caller")
    }
}
