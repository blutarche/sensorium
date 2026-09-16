import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Design §9: "no mixed session." A connection is one shape for its whole
/// life -- the first admitted `canvasRequest` or `hostScreenRequest` fixes
/// it, and a request of the other kind refuses from then on, with its own
/// reason, never a silent no-op. `HostSessionController.connectionShape`
/// is the enforcement; this file proves both orders, that a refused
/// second-kind request leaves the first surface untouched, and that the
/// shape resets at `goodbye`.
@MainActor
private func hostScreenTestDisplay(id: UInt32 = 7) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
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

private final class AlwaysApprovingVerifier: HostScreenPresenceProofVerifying, @unchecked Sendable {
    func verify(proof: HostScreenPresenceProof, devicePublicKey: Data, minimumStrength: HostScreenCredentialStrength?, challenge: Data) -> Bool {
        true
    }
}

private final class AlwaysIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

@MainActor
private func offerAndExtractToken(_ controller: HostSessionController) -> Data {
    guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(), let entry = displays.first else {
        expect(false, "the fixture's offer names at least one display")
        return Data()
    }
    return entry.opaqueToken
}

@MainActor
func runHostScreenMixedSessionTests() async {
    do {
        // Canvas first, then a host-screen request refuses
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel MacBook Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let injectorFactory = FakeInputInjectorFactory()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .unconfined,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: AlwaysApprovingVerifier(),
            hostScreenLocalActivitySignal: AlwaysIdleSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))

        let ready = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        guard case .canvasReady = ready else {
            expect(false, "the first request, a canvas one, is admitted normally")
            return
        }

        let token = offerAndExtractToken(controller)
        let hostScreenResponse = try! controller.handle(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            hostScreenResponse == .hostScreenRefused(reason: "canvas-session-active"),
            "a host-screen request on a connection a canvas request already committed refuses with its own, named reason"
        )

        // The first surface is untouched: input against it still works
        // exactly as it did before the refused request.
        _ = try! controller.handle(.input(.pointerMoved(x: 960, y: 600), surfaceID: nil))
        expect(
            injectorFactory.injector.events.contains(.pointerMoved(x: 960, y: 600)),
            "the canvas surface the first request created keeps working after the second, refused request"
        )

        print("PASS: a host-screen request refuses on a connection a canvas request already committed, and the canvas surface it created is untouched")
    }

    do {
        // Host screen first, then a canvas request refuses
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel MacBook Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let injectorFactory = FakeInputInjectorFactory()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: AlwaysApprovingVerifier(),
            hostScreenLocalActivitySignal: AlwaysIdleSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))

        let token = offerAndExtractToken(controller)
        let hostScreenReady = try! controller.handle(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        guard case .hostScreenReady = hostScreenReady else {
            expect(false, "the first request, a host-screen one, is admitted normally")
            return
        }

        let canvasResponse = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(
            canvasResponse == .canvasRefused(reason: "host-screen-session-active", surfaceID: nil),
            "a canvas request on a connection a host-screen request already committed refuses with its own, named reason"
        )

        // The first surface is untouched: input against the real display
        // still routes exactly as it did before the refused request.
        _ = try! controller.handle(.input(.pointerMoved(x: 100, y: 100), surfaceID: nil))
        expect(
            injectorFactory.injector.events.contains(.pointerMoved(x: 100, y: 100)),
            "the host-screen surface the first request created keeps working after the second, refused request"
        )

        print("PASS: a canvas request refuses on a connection a host-screen request already committed, and the host-screen surface it created is untouched")
    }

    do {
        // Host screen, then a second host-screen request on the
        // same connection refuses -- even for a different, also-
        // armed display -- rather than silently overwriting the
        // live surface.
        let identity = try! DeviceIdentity.generate()
        let firstDisplay = hostScreenTestDisplay(id: 7)
        let secondDisplay = DisplaySnapshot(
            id: 8,
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
            vendorNumber: 4268,
            modelNumber: 41198
        )
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel MacBook Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let injectorFactory = FakeInputInjectorFactory()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [firstDisplay, secondDisplay] },
            hostScreenPresenceProofVerifier: AlwaysApprovingVerifier(),
            hostScreenLocalActivitySignal: AlwaysIdleSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))

        guard case let .hostScreenList(firstDisplays, _) = try! controller.offerHostScreenList(),
              let firstEntry = firstDisplays.first(where: { $0.displayIdentity == HostScreenDisplayIdentity(firstDisplay).wireStableIdentifier }) else {
            expect(false, "the fixture's offer names the first display")
            return
        }
        let hostScreenReady = try! controller.handle(.hostScreenRequest(
            token: firstEntry.opaqueToken,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        guard case .hostScreenReady = hostScreenReady else {
            expect(false, "the first request, a host-screen one, is admitted normally")
            return
        }

        // A fresh offer, minting a token for the second, also-armed
        // display -- proving this refuses even a well-formed request
        // naming a display the device really is armed for, not just a
        // malformed or unknown one.
        guard case let .hostScreenList(secondDisplays, _) = try! controller.offerHostScreenList(),
              let secondEntry = secondDisplays.first(where: { $0.displayIdentity == HostScreenDisplayIdentity(secondDisplay).wireStableIdentifier }) else {
            expect(false, "the fixture's second offer names the second display")
            return
        }
        let secondResponse = try! controller.handle(.hostScreenRequest(
            token: secondEntry.opaqueToken,
            presence: .signed(credentialID: Data([0x03]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x04]))
        ))
        expect(
            secondResponse == .hostScreenRefused(reason: "host-screen-session-active"),
            "a second host-screen request on a connection already live with one refuses with its own, named reason, never silently retargeting the surface"
        )

        // The first surface is untouched: input against it still routes
        // exactly as it did before the refused second request.
        _ = try! controller.handle(.input(.pointerMoved(x: 100, y: 100), surfaceID: nil))
        expect(
            injectorFactory.injector.events.contains(.pointerMoved(x: 100, y: 100)),
            "the first host-screen surface keeps working after the second, refused request"
        )

        print("PASS: a second host-screen request on a connection already live with one refuses rather than overwriting the surface with a different display")
    }

    do {
        // The shape resets at goodbye
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Probe",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .unconfined,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: AlwaysApprovingVerifier(),
            hostScreenLocalActivitySignal: AlwaysIdleSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))

        let firstReady = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        guard case .canvasReady = firstReady else {
            expect(false, "the first session's canvas request is admitted")
            return
        }
        _ = try! controller.handle(.goodbye(reason: "test teardown"))

        let token = offerAndExtractToken(controller)
        let secondReady = try! controller.handle(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        guard case .hostScreenReady = secondReady else {
            expect(false, "a fresh session after goodbye starts with no shape fixed, so the opposite kind is admitted")
            return
        }

        print("PASS: goodbye resets the connection's shape, so a later session on the same connection may be the other kind")
    }
}
