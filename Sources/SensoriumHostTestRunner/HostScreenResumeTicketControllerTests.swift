import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// `HostSessionController`'s own use of `HostScreenResumeTicketStore`:
/// design §6.5's "a grant belongs to a host-screen session, not a transport
/// connection" means the store has to be the *same instance* handed to a
/// second, later `HostSessionController` -- standing in here for the
/// controller a real reconnect gets from `HostConnectionSessionFactory` --
/// for a resume to mean anything. `HostScreenResumeTicketStoreTests.swift`
/// covers the store's own decision exhaustively; this file covers only that
/// the controller is wired to it correctly.
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

@MainActor
private func offerAndExtractToken(_ controller: HostSessionController) -> Data {
    guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(), let entry = displays.first else {
        expect(false, "the fixture's offer names at least one display")
        return Data()
    }
    return entry.opaqueToken
}

/// A fresh controller, authenticated as `identity`, wired identically to
/// `HostScreenSessionControllerAdmissionTests.swift`'s own admissible
/// fixture except for the resume-ticket store, which every caller supplies
/// explicitly -- standing in for a second connection from the same device
/// after the first one dropped.
@MainActor
private func makeReconnectableController(
    identity: DeviceIdentity,
    display: DisplaySnapshot,
    arming: HostScreenArming,
    resumeTicketStore: (any HostScreenResumeTicketStoring)?,
    presenceGate: (any HostScreenPresenceGating)? = nil,
    presenceSignal: any HostLocalActivitySignal = AlwaysIdleSignal(),
    liveSessionRegistry: (any HostScreenLiveSessionRegistering)? = nil
) -> HostSessionController {
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [identity.publicKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenResumeTicketStore: resumeTicketStore,
        hostScreenLiveSessionRegistry: liveSessionRegistry,
        hostScreenLocalActivitySignal: presenceSignal,
        hostScreenPresenceGate: presenceGate
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
    ))
    return controller
}

private final class AlwaysIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

private final class RecentlyActiveSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(0)
    }
}

private final class CountingPresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    private(set) var calls = 0

    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome {
        calls += 1
        return .proceed
    }
}

/// A controllable clock: advanced explicitly rather than racing the real
/// five-minute grace window, the same seam `HostScreenResumeTicketStoreTests.swift`
/// already uses for the store's own tests.
private final class FakeClock {
    var seconds: Double = 1_000
    func now() -> Double { seconds }
    func advance(by delta: Double) { seconds += delta }
}

@MainActor
func runHostScreenResumeTicketControllerTests() async {
    do {
        // A transport interruption resumes silently, with no signed proof and no verifier configured
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let store = HostScreenResumeTicketStore()

        let firstConnection = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store
        )
        let firstToken = offerAndExtractToken(firstConnection)
        guard case let .hostScreenReady(_, mintedTicket) = try! firstConnection.handle(.hostScreenRequest(
            token: firstToken,
            resumeTicket: nil
        )) else {
            expect(false, "the first connection's own admission, with a verifier that approves, must succeed")
            return
        }

        // The transport drops and a brand-new HostSessionController is
        // built for the reconnect -- exactly what `HostConnectionSessionFactory`
        // hands a fresh connection -- sharing only the same resume-ticket
        // store. No presence-proof verifier is configured at all this time:
        // if the resume ticket path ever fell through to that verifier, this
        // would refuse, proving the two proof shapes are genuinely
        // independent, not the same check reached two ways. The host was
        // recently active (`RecentlyActiveSignal`), which alone would force
        // `HostScreenPresenceRule.assess` to `.mustAsk`, so the gate below
        // staying uncalled proves the resume ticket skips that rule rather
        // than passing it by coincidence.
        let presenceGate = CountingPresenceGate()
        let secondConnection = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store,
            presenceGate: presenceGate, presenceSignal: RecentlyActiveSignal()
        )
        let secondToken = offerAndExtractToken(secondConnection)
        let resumed = try! secondConnection.handle(.hostScreenRequest(
            token: secondToken, resumeTicket: mintedTicket
        ))
        guard case let .hostScreenReady(geometry, _) = resumed else {
            expect(false, "a valid resume ticket admits the reconnected session with no signed proof and no verifier configured")
            return
        }
        expect(
            geometry == SessionSurfaceGeometry(logicalWidth: 2560, logicalHeight: 1440, backingScale: 2.0),
            "the resumed session still carries the real display's own geometry"
        )
        expect(
            presenceGate.calls == 0,
            "a valid resume ticket resumes silently without invoking the host presence gate, even though the host was recently active and would otherwise be asked"
        )

        print("PASS: a transport interruption resumes silently on a new connection, asking neither the credential verifier nor the presence gate")
    }

    do {
        // A ticket this device was never minted refuses like an unverified credential
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Probe",
                armedAt: Date()
            )
        ])
        let store = HostScreenResumeTicketStore()
        let controller = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store
        )
        let token = offerAndExtractToken(controller)
        let response = try! controller.handle(.hostScreenRequest(
            token: token, resumeTicket: Data([0xDE, 0xAD, 0xBE, 0xEF])
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "a resume ticket this store never minted refuses on its own reason, distinct from a signed proof's credential reasons, which describe a wholly different proof this ticket never touches"
        )

        print("PASS: an unknown resume ticket refuses the whole request, video included, with its own reason")
    }

    do {
        // No resume-ticket store configured refuses every resume, honestly
        // The same "nothing approximates a check that does not exist"
        // precedent set for a missing presence-proof verifier.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Probe",
                armedAt: Date()
            )
        ])
        let controller = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: nil
        )
        let token = offerAndExtractToken(controller)
        let response = try! controller.handle(.hostScreenRequest(
            token: token, resumeTicket: Data([0x01])
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "with no resume-ticket store configured, every resume attempt refuses on its own reason -- production is honest about validating nothing until one is wired in"
        )

        print("PASS: with no resume-ticket store configured, every resume attempt is refused rather than approximated")
    }

    do {
        // An expired ticket refuses on its own reason, never the
        // .signed path's credential reasons.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)

        let firstConnection = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store
        )
        let firstToken = offerAndExtractToken(firstConnection)
        guard case let .hostScreenReady(_, mintedTicket) = try! firstConnection.handle(.hostScreenRequest(
            token: firstToken,
            resumeTicket: nil
        )) else {
            expect(false, "the first connection's own admission, with a verifier that approves, must succeed")
            return
        }

        // Past the twelve-hour ceiling, which -- unlike the five-minute
        // grace window -- never refreshes, so this is genuinely expired
        // rather than merely idle.
        clock.advance(by: HostScreenResumeTicketStore.ceilingSeconds + 1)

        let secondConnection = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store
        )
        let secondToken = offerAndExtractToken(secondConnection)
        let response = try! secondConnection.handle(.hostScreenRequest(
            token: secondToken, resumeTicket: mintedTicket
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "a ticket past its own twelve-hour ceiling refuses on its own reason, never the .signed path's credential-unknown or needs-rearming"
        )

        print("PASS: an expired resume ticket refuses on its own reason")
    }

    do {
        // A ticket minted for a different display refuses on its
        // own reason, never the .signed path's credential reasons.
        let identity = try! DeviceIdentity.generate()
        let mintedDisplay = hostScreenTestDisplay(id: 7)
        // `HostScreenDisplayIdentity` is derived from vendor/model number,
        // not `id` (design §5.4: stable across a replug, when `id` is not)
        // -- `hostScreenTestDisplay(id:)` alone leaves that pair unchanged,
        // so this display needs its own to actually be a different
        // identity, not just a different live `id` for the same one.
        let otherDisplay = DisplaySnapshot(
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
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let store = HostScreenResumeTicketStore()

        @MainActor
        func makeControllerForBothDisplays() -> HostSessionController {
            let controller = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                approvedPublicKeys: [identity.publicKey],
                requireAuthentication: true,
                inputInjectorFactory: FakeInputInjectorFactory(),
                keyConfinement: .hostScreen,
                hostScreenArmingProvider: { arming },
                hostScreenCurrentDisplaysProvider: { [mintedDisplay, otherDisplay] },
                hostScreenResumeTicketStore: store,
                hostScreenLocalActivitySignal: AlwaysIdleSignal()
            )
            let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
                hostCertificateHash: nil
            )
            _ = try! controller.handle(.authenticatedHello(
                protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
            ))
            return controller
        }

        let firstConnection = makeControllerForBothDisplays()
        guard case let .hostScreenList(displays) = try! firstConnection.offerHostScreenList(),
              let mintedEntry = displays.first(where: { $0.displayIdentity == HostScreenDisplayIdentity(mintedDisplay).wireStableIdentifier }) else {
            expect(false, "the fixture offers the minted display among its entries")
            return
        }
        guard case let .hostScreenReady(_, mintedTicket) = try! firstConnection.handle(.hostScreenRequest(
            token: mintedEntry.opaqueToken,
            resumeTicket: nil
        )) else {
            expect(false, "admission against the minted display, with a verifier that approves, must succeed")
            return
        }

        let secondConnection = makeControllerForBothDisplays()
        guard case let .hostScreenList(secondDisplays) = try! secondConnection.offerHostScreenList(),
              let otherEntry = secondDisplays.first(where: { $0.displayIdentity == HostScreenDisplayIdentity(otherDisplay).wireStableIdentifier }) else {
            expect(false, "the second connection's own offer names the other display too")
            return
        }
        let response = try! secondConnection.handle(.hostScreenRequest(
            token: otherEntry.opaqueToken, resumeTicket: mintedTicket
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "a ticket minted for one display, presented against a request for a different one, refuses on its own reason, never the .signed path's credential reasons"
        )

        print("PASS: a resume ticket minted for a different display refuses on its own reason")
    }

    do {
        // A request carrying no ticket at all is an ordinary first
        // request: an armed device is admitted, and the resume path's
        // own refusal reason never appears.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Probe",
                armedAt: Date()
            )
        ])
        let controller = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: HostScreenResumeTicketStore()
        )
        let token = offerAndExtractToken(controller)
        let response = try! controller.handle(.hostScreenRequest(
            token: token, resumeTicket: nil
        ))
        guard case .hostScreenReady = response else {
            expect(false, "an armed device's first request, carrying no ticket, is admitted -- got \(response)")
            return
        }

        print("PASS: a request carrying no resume ticket is an ordinary admitted first request")
    }

    do {
        // A deliberate Stop ends the grant, not just the connection
        // CLAUDE.md: "a control that stops it immediately". A ticket that
        // outlived Stop would let the viewer's own automatic redial resume the
        // very session a person just ended, with no second presence check.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let store = HostScreenResumeTicketStore()

        let stoppedConnection = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store
        )
        let stoppedToken = offerAndExtractToken(stoppedConnection)
        guard case let .hostScreenReady(_, mintedTicket) = try! stoppedConnection.handle(.hostScreenRequest(
            token: stoppedToken,
            resumeTicket: nil
        )) else {
            expect(false, "the stopped session's own admission, with a verifier that approves, must succeed")
            return
        }

        _ = try! stoppedConnection.handle(.goodbye(reason: GoodbyeReason.stoppedByHost))

        let redial = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store,
            presenceGate: CountingPresenceGate()
        )
        let redialToken = offerAndExtractToken(redial)
        let refused = try! redial.handle(.hostScreenRequest(
            token: redialToken, resumeTicket: mintedTicket
        ))
        expect(
            refused == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "a ticket minted before a deliberate Stop resumes nothing afterwards, so a redial that never saw the goodbye is refused anyway"
        )

        print("PASS: a deliberate Stop invalidates the stopped device's resume tickets, so a redial presenting one is refused")
    }

    do {
        // The same, driven the way a person drives it: Stop on the
        // live session, through the coordinator production attaches.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let store = HostScreenResumeTicketStore()
        let liveController = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store
        )
        let liveToken = offerAndExtractToken(liveController)
        guard case let .hostScreenReady(_, liveTicket) = try! liveController.handle(.hostScreenRequest(
            token: liveToken,
            resumeTicket: nil
        )) else {
            expect(false, "the live session's own admission, with a verifier that approves, must succeed")
            return
        }
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let networkSession = HostNetworkSession(connection: channel, controller: liveController)
        let coordinator = HostSessionCoordinator(
            controller: liveController,
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
        )
        networkSession.attach(coordinator: coordinator)

        networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        let afterStop = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store,
            presenceGate: CountingPresenceGate()
        )
        let afterStopToken = offerAndExtractToken(afterStop)
        let refusedAfterStop = try! afterStop.handle(.hostScreenRequest(
            token: afterStopToken, resumeTicket: liveTicket
        ))
        expect(
            refusedAfterStop == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "Stop pressed on the live session invalidates its ticket through the coordinator production attaches, not only through a bare goodbye"
        )

        print("PASS: Stop on a live host-screen session invalidates its resume ticket end to end")
    }

    do {
        // The one-live-session-per-device registry and the resume path meet: a
        // reconnect after a dropped session is exactly a second connection for a
        // device whose first entry is now stale, so the registry must let a
        // resume replace a dead session tap-free while still refusing a resume
        // that would run alongside a first session genuinely still live.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Kestrel Laptop Pro",
                armedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ])
        let store = HostScreenResumeTicketStore()
        let registry = HostScreenLiveSessionRegistry()

        var firstConnection: HostSessionController? = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store,
            liveSessionRegistry: registry
        )
        let firstToken = offerAndExtractToken(firstConnection!)
        guard case let .hostScreenReady(_, mintedTicket) = try! firstConnection!.handle(.hostScreenRequest(
            token: firstToken,
            resumeTicket: nil
        )) else {
            expect(false, "the first connection's own admission must succeed")
            return
        }

        // While the first session is genuinely still live, a resume for the same
        // device is a second concurrent session, refused with the registry's own
        // reason -- not the resume path's, since the ticket itself is valid.
        let whileLive = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store,
            liveSessionRegistry: registry
        )
        let whileLiveToken = offerAndExtractToken(whileLive)
        expect(
            try! whileLive.handle(.hostScreenRequest(token: whileLiveToken, resumeTicket: mintedTicket))
                == .hostScreenRefused(reason: "host-screen-already-live"),
            "a resume that would run alongside a first session still live is refused as a second concurrent session"
        )

        // The first session's connection drops without a goodbye ever reaching
        // its controller (a hard transport loss): releasing its only strong
        // reference frees it, so the registry's liveness check reads its entry as
        // dead. A reconnect for the same device then resumes tap-free.
        firstConnection = nil
        let reconnect = makeReconnectableController(
            identity: identity, display: display, arming: arming, resumeTicketStore: store,
            liveSessionRegistry: registry
        )
        let reconnectToken = offerAndExtractToken(reconnect)
        guard case .hostScreenReady = try! reconnect.handle(.hostScreenRequest(
            token: reconnectToken, resumeTicket: mintedTicket
        )) else {
            expect(false, "a reconnect replacing a dead session resumes tap-free through the shared registry")
            return
        }

        print("PASS: the live-session registry refuses a resume alongside a live session yet lets a reconnect replace a dead one tap-free")
    }
}
