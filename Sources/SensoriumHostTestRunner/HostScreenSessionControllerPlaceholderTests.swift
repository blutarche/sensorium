import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// A `HostSessionController` built with no arming, selection-guard,
/// presence-rule, or presence-proof-verifier providers still refuses every
/// host-screen request. This file covers that: refusing honestly when the
/// arming, display, and verifier machinery genuinely is not there.
@MainActor
func runHostScreenSessionControllerPlaceholderTests() async {
    do {
        let identity = try! DeviceIdentity.generate()
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(session),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined
        )

        // Before authentication, a hostScreenRequest reveals nothing about
        // host-screen support -- it is refused the same way any other
        // authenticated-only message is, not with the host-screen-specific
        // reason.
        do {
            _ = try controller.handle(
                .hostScreenRequest(token: Data([0x01]), resumeTicket: Data([0x02]))
            )
            expect(false, "an unauthenticated hostScreenRequest must throw")
        } catch HostSessionControllerError.authenticationRequired {
        } catch {
            expect(false, "an unauthenticated hostScreenRequest reports authenticationRequired, not \(error)")
        }

        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
            hostCertificateHash: nil
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))

        // Authenticated, every hostScreenRequest is still refused with the
        // exact reason design §2.3 names for a viewer that is not armed
        // for -- this controller was built with no arming provider at
        // all, so every device really is unarmed from its point of view,
        // the same honest refusal a real unarmed device gets from a fully
        // wired controller (`HostScreenSessionControllerAdmissionTests.swift`).
        let response = try! controller.handle(
            .hostScreenRequest(token: Data([0x01]), resumeTicket: Data([0x02]))
        )
        expect(
            response == .hostScreenRefused(reason: "host-screen-not-allowed"),
            "an authenticated hostScreenRequest is refused with host-screen-not-allowed when no arming provider was ever given to this controller"
        )

        // The three host-to-client-only host-screen messages are rejected
        // if ever received, the same as timeSyncReply/telemetry/canvasRefused.
        for message: SensoriumMessage in [
            .hostScreenList(displays: []),
            .hostScreenReady(
                geometry: SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1200, backingScale: 2.0),
                resumeTicket: Data([0x01])
            ),
            .hostScreenRefused(reason: "test")
        ] {
            do {
                _ = try controller.handle(message)
                expect(false, "\(message) sent to the host, which never expects to receive it, must throw")
            } catch HostSessionControllerError.unexpectedMessage {
            } catch {
                expect(false, "\(message) reports unexpectedMessage, not \(error)")
            }
        }

        print("PASS: a controller with no host-screen providers refuses every request and rejects the host-to-client-only messages")
    }
}
