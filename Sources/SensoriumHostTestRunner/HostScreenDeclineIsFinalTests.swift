import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

private final class DeclineTestActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    var reading: HostLocalActivityReading = .idleFor(0)
    func currentReading() -> HostLocalActivityReading { reading }
}

private final class DeclineTestPresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    var outcome: HostScreenPresenceOutcome = .refused(reason: HostScreenPresenceRule.declinedReason)
    private(set) var askCount = 0

    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome {
        askCount += 1
        return outcome
    }
}

@MainActor
private func declineTestDisplay() -> DisplaySnapshot {
    DisplaySnapshot(
        id: 7,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

/// One connection, armed with asking first switched on, and a person at the
/// host who is there to be asked.
@MainActor
private func makeDecliningFixture() -> (
    controller: HostSessionController,
    gate: DeclineTestPresenceGate,
    token: Data
) {
    let identity = try! DeviceIdentity.generate()
    let display = declineTestDisplay()
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: identity.publicKey,
            deviceName: "Kestrel Laptop Pro",
            armedAt: Date(),
            asksWhenSomeoneIsUsingThisMachine: true
        )
    ])
    let gate = DeclineTestPresenceGate()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [identity.publicKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceActivitySignal: DeclineTestActivitySignal(),
        hostScreenPresenceGate: gate
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1,
        deviceName: "Probe",
        publicKey: identity.publicKey,
        signature: try! identity.sign(SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "Probe",
            publicKey: identity.publicKey,
            hostCertificateHash: nil
        ))
    ))
    guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(),
          let entry = displays.first else {
        expect(false, "the fixture's offer names the one display it has")
        return (controller, gate, Data())
    }
    return (controller, gate, entry.opaqueToken)
}

/// An answer the person at the host gave is an answer, not a round in a
/// contest: without this, a viewer could resend `hostScreenRequest` on the
/// same connection as fast as the prompt can be dismissed, and the person
/// at the host would be asked again every time until they gave in.
@MainActor
func runHostScreenDeclineIsFinalTests() async {
    do {
        let fixture = makeDecliningFixture()
        let declined = try! fixture.controller.handle(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            declined == .hostScreenRefused(reason: "host-screen-presence-declined"),
            "the first request is refused with the decline's own reason -- got \(String(describing: declined))"
        )
        expect(fixture.gate.askCount == 1, "and the person at this machine was asked once")

        // Even if the gate would now say yes, it is never reached: the
        // answer already given stands for the life of this connection.
        fixture.gate.outcome = .proceed
        let again = try! fixture.controller.handle(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            again == .hostScreenRefused(reason: "host-screen-presence-declined"),
            "a second request on the same connection is refused with the same reason -- got \(String(describing: again))"
        )
        expect(
            fixture.gate.askCount == 1,
            "and asks nobody again -- got \(fixture.gate.askCount) prompts"
        )

        print("PASS: a declined host-screen request is final for that connection, and never prompts the person at the host again")
    }

    do {
        // A prompt nobody answered is the same: the person at the host may
        // not even be there, and asking again is exactly what a viewer
        // hammering the connection wants.
        let fixture = makeDecliningFixture()
        fixture.gate.outcome = .refused(reason: HostScreenPresenceRule.unansweredReason)
        let unanswered = try! fixture.controller.handle(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            unanswered == .hostScreenRefused(reason: "host-screen-presence-unanswered"),
            "the first request is refused as unanswered -- got \(String(describing: unanswered))"
        )
        fixture.gate.outcome = .proceed
        let again = try! fixture.controller.handle(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            again == .hostScreenRefused(reason: "host-screen-presence-unanswered")
                && fixture.gate.askCount == 1,
            "and a second request on the same connection is refused the same way, with no new prompt -- got \(String(describing: again)) after \(fixture.gate.askCount) prompts"
        )

        print("PASS: an unanswered host-screen prompt is final for that connection too")
    }

    do {
        // A refusal for want of a gate is not an answer anybody gave, and a
        // gate busy with another connection is somebody else's prompt: both
        // must stay retryable, or one unrelated peer could wedge this
        // connection for its whole life.
        let identity = try! DeviceIdentity.generate()
        let display = declineTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(),
                asksWhenSomeoneIsUsingThisMachine: true
            )
        ])
        let signal = DeclineTestActivitySignal()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceActivitySignal: signal
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Probe",
            publicKey: identity.publicKey,
            signature: try! identity.sign(SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1,
                deviceName: "Probe",
                publicKey: identity.publicKey,
                hostCertificateHash: nil
            ))
        ))
        guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(),
              let entry = displays.first else {
            expect(false, "the no-gate fixture's offer names the one display it has")
            return
        }
        let refused = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil))
        expect(
            refused == .hostScreenRefused(reason: "host-screen-presence-check-required"),
            "with no gate to ask, the request is refused for want of one -- got \(String(describing: refused))"
        )
        // The person at this machine stops using it, so the same connection
        // asking again is now admissible and must be admitted.
        signal.reading = .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
        let retried = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil))
        expect(
            { if case .hostScreenReady = retried { return true } else { return false } }(),
            "a refusal nobody answered leaves the connection able to try again -- got \(String(describing: retried))"
        )

        print("PASS: a refusal for want of a gate is retryable on the same connection, unlike an answer a person gave")
    }
}
