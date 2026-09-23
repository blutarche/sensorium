import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Controllable stand-in for a presence-credential verifier, so the gating
/// logic around one can be driven independently of the real verifier.
private final class FakeHostScreenPresenceProofVerifier: HostScreenPresenceProofVerifying, @unchecked Sendable {
    var result = true
    private(set) var calls: [(proof: HostScreenPresenceProof, devicePublicKey: Data, minimumStrength: HostScreenCredentialStrength?)] = []

    func verify(
        proof: HostScreenPresenceProof, devicePublicKey: Data, minimumStrength: HostScreenCredentialStrength?, challenge: Data
    ) -> Bool {
        calls.append((proof, devicePublicKey, minimumStrength))
        return result
    }
}

private final class FakeHostScreenLocalActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    var reading: HostLocalActivityReading = .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    func currentReading() -> HostLocalActivityReading { reading }
}

/// Stands in for `HostScreenPresenceGate`: proves what `HostSessionController`
/// itself does with a `.mustAsk` assessment when a gate is configured --
/// asks it, exactly once, naming the arming record's own device and display,
/// and honors whatever it answers -- independent of `HostScreenPresenceGate`'s
/// own exclusivity and timeout logic, which `HostScreenPresenceGateTests.swift`
/// covers on its own.
private final class FakeHostScreenPresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    var outcome: HostScreenPresenceOutcome = .proceed
    private(set) var calls: [HostScreenBadgeContent] = []

    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome {
        calls.append(content)
        return outcome
    }
}

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

/// One controller wired for a full, real (fake-backed) host-screen
/// admission: armed for `deviceKey`, one eligible display live, idle well
/// past the threshold, and a verifier that approves by default. Every test starts here and breaks exactly one
/// thing.
@MainActor
private func makeAdmissibleFixture() -> (
    controller: HostSessionController,
    deviceKey: Data,
    display: DisplaySnapshot,
    verifier: FakeHostScreenPresenceProofVerifier,
    signal: FakeHostScreenLocalActivitySignal,
    injectorFactory: FakeInputInjectorFactory
) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let display = hostScreenTestDisplay()
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel Laptop Pro",
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date(),
            // This fixture exists to exercise the presence rule and gate;
            // the ask-first setting itself defaults off (HostScreenArmingTests.swift
            // covers that default), so it is turned on explicitly here to
            // keep exercising the mechanics this fixture is for.
            asksWhenSomeoneIsUsingThisMachine: true
        )
    ])
    let verifier = FakeHostScreenPresenceProofVerifier()
    let signal = FakeHostScreenLocalActivitySignal()
    let adapter = FakeVirtualDisplayAdapter()
    let session = VirtualDisplaySession(adapter: adapter)
    // Retained rather than passed inline, so refusal tests can assert
    // nothing was ever built or asked of the display, not just read the
    // controller's source and trust the claim.
    let injectorFactory = FakeInputInjectorFactory()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(session),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: injectorFactory,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceProofVerifier: verifier,
        hostScreenLocalActivitySignal: signal
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    return (controller, deviceKey, display, verifier, signal, injectorFactory)
}

/// The same admissible setup `makeAdmissibleFixture` builds, with a
/// `FakeHostScreenPresenceGate` wired in too -- kept separate rather than
/// added as another optional parameter there, since every other existing
/// call site deliberately wants no gate configured (today's "refuses
/// outright" behaviour, still the default with none wired in).
@MainActor
private func makeAdmissibleFixtureWithGate() -> (
    controller: HostSessionController,
    display: DisplaySnapshot,
    signal: FakeHostScreenLocalActivitySignal,
    gate: FakeHostScreenPresenceGate,
    verifier: FakeHostScreenPresenceProofVerifier
) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let display = hostScreenTestDisplay()
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel Laptop Pro",
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date(),
            // Same reasoning as makeAdmissibleFixture: this fixture exists
            // to exercise the gate itself, so the ask-first setting it
            // depends on is turned on explicitly rather than left at its
            // off-by-default value.
            asksWhenSomeoneIsUsingThisMachine: true
        )
    ])
    let verifier = FakeHostScreenPresenceProofVerifier()
    let signal = FakeHostScreenLocalActivitySignal()
    let gate = FakeHostScreenPresenceGate()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceProofVerifier: verifier,
        hostScreenLocalActivitySignal: signal,
        hostScreenPresenceGate: gate
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    return (controller, display, signal, gate, verifier)
}

/// A refusal must build no injector and hand it no work: `factory` was
/// never asked to `make` one, and the pre-built fake it would have handed
/// back never received an event either.
@MainActor
private func expectNoInjectorWasBuilt(_ factory: FakeInputInjectorFactory, _ context: String) {
    expect(factory.requestedDisplayIDs.isEmpty, "\(context): a refusal must construct zero injectors")
    expect(factory.injector.events.isEmpty, "\(context): a refusal must request nothing of the display")
}

@MainActor
private func offerAndExtractToken(_ controller: HostSessionController) -> Data {
    guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(), let entry = displays.first else {
        expect(false, "the admissible fixture's offer names at least one display")
        return Data()
    }
    return entry.opaqueToken
}

@MainActor
func runHostScreenSessionControllerAdmissionTests() async {
    do {
        // The happy path: every obligation held
        let fixture = makeAdmissibleFixture()
        let token = offerAndExtractToken(fixture.controller)
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        guard case let .hostScreenReady(geometry, resumeTicket) = response else {
            expect(false, "every obligation held, so the request is admitted")
            return
        }
        expect(
            geometry == SessionSurfaceGeometry(logicalWidth: 2560, logicalHeight: 1440, backingScale: 2.0),
            "the ready reply carries the real display's own geometry, backing scale included"
        )
        expect(!resumeTicket.isEmpty, "a fresh resume ticket is minted on admission")
        expect(
            fixture.verifier.calls.last?.devicePublicKey == fixture.deviceKey,
            "the verifier is asked about the authenticated device's own key, never anything the wire could name"
        )
        expect(
            fixture.verifier.calls.last?.minimumStrength == .hardwareBound,
            "the minimum strength checked comes from the arming record, not from the proof, which has no field for one"
        )

        print("PASS: a request meeting every obligation is admitted, carrying the real display's geometry and a fresh resume ticket")
    }

    do {
        // Refusal never degrades: unarmed
        // A device with no arming record at all -- `offerHostScreenList`
        // itself already refuses it, so it never receives a token to send
        // back in the first place. Confirms the same at `hostScreenRequest`
        // directly, with a token that was never legitimately minted for it.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let verifier = FakeHostScreenPresenceProofVerifier()
        let signal = FakeHostScreenLocalActivitySignal()
        let injectorFactory = FakeInputInjectorFactory()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { HostScreenArming() },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: verifier,
            hostScreenLocalActivitySignal: signal
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        let offer = try! controller.offerHostScreenList()
        expect(offer == .hostScreenRefused(reason: "host-screen-not-allowed"), "an unarmed device's offer is refused outright, never an empty-but-valid list")

        let response = try! controller.handle(.hostScreenRequest(
            token: Data([0x01]), presence: .signed(credentialID: Data([0x02]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x03]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-not-allowed"),
            "an unarmed device's request refuses outright"
        )
        expectNoInjectorWasBuilt(injectorFactory, "unarmed device")

        print("PASS: an unarmed device is refused at both the offer and the request, and creates no injector")
    }

    do {
        // Refusal never degrades: unverified proof
        let fixture = makeAdmissibleFixture()
        let token = offerAndExtractToken(fixture.controller)
        fixture.verifier.result = false
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "a proof the verifier rejects refuses the whole request, video included -- never a reduced or view-only session"
        )
        expectNoInjectorWasBuilt(fixture.injectorFactory, "unverified proof")

        print("PASS: an unverified signed proof refuses with host-screen-credential-unknown, not a degraded session")
    }

    do {
        // Refusal never degrades: no verifier configured at all
        // The honest default: nothing is registered, so nothing can ever
        // verify, so every proof refuses -- not an approximation of a real
        // check, which is the state of the world until a real verifier is configured.
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Probe",
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
            hostScreenLocalActivitySignal: FakeHostScreenLocalActivitySignal()
            // hostScreenPresenceProofVerifier deliberately omitted.
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        let token = offerAndExtractToken(controller)
        let response = try! controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "with no verifier configured at all, an armed device with an otherwise-admissible request is still refused -- production is honest about verifying nothing until a real one exists"
        )
        expectNoInjectorWasBuilt(injectorFactory, "no verifier configured")

        print("PASS: with no presence-proof verifier configured, every proof is refused even for an otherwise fully admissible request")
    }

    do {
        // Refusal never degrades: presence check required
        let fixture = makeAdmissibleFixture()
        let token = offerAndExtractToken(fixture.controller)
        fixture.signal.reading = .idleFor(0)
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-presence-check-required"),
            "somebody at the host (idle time well under the threshold) refuses the request rather than silently proceeding without asking"
        )
        expectNoInjectorWasBuilt(fixture.injectorFactory, "presence check required")

        print("PASS: a request that would require asking the person at the host refuses rather than silently proceeding")
    }

    do {
        // Refusal never degrades: unavailable idle signal
        // design SS6.2: unknown is not absent.
        let fixture = makeAdmissibleFixture()
        let token = offerAndExtractToken(fixture.controller)
        fixture.signal.reading = .unavailable
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-presence-check-required"),
            "an idle reading that could not be taken is never treated as nobody being home"
        )
        expectNoInjectorWasBuilt(fixture.injectorFactory, "unreadable idle signal")

        print("PASS: an unreadable idle signal refuses the same way a present person does, never as absence")
    }

    do {
        // A configured gate is asked, and an approval admits
        let fixture = makeAdmissibleFixtureWithGate()
        let token = offerAndExtractToken(fixture.controller)
        fixture.signal.reading = .idleFor(0)
        fixture.gate.outcome = .proceed
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            { if case .hostScreenReady = response { return true } else { return false } }(),
            "a request that would otherwise require asking is admitted once a configured gate approves it"
        )
        expect(fixture.gate.calls.count == 1, "the gate is asked exactly once")
        expect(
            fixture.gate.calls.first == HostScreenBadgeContent(
                deviceName: "Kestrel Laptop Pro",
                displayLabel: HostScreenArmingPresentation.displayLabel(for: fixture.display)
            ),
            "the gate is asked about the arming record's own device name and the same display label the badge and session log use, never a value read back from the connection's own claim"
        )
        expect(
            fixture.controller.hostScreenLastPresencePromptContent == fixture.gate.calls.first,
            "the controller records the same content it asked the gate with, for a coordinator to log that a person at this machine was asked at all"
        )

        print("PASS: a request needing to ask is admitted on the gate's approval, and the gate is asked with the armed device and display")
    }

    do {
        // A declined answer carries its own wire reason, distinct
        // from an unanswered prompt or "nothing to ask with"
        let fixture = makeAdmissibleFixtureWithGate()
        let token = offerAndExtractToken(fixture.controller)
        fixture.signal.reading = .idleFor(0)
        fixture.gate.outcome = .refused(reason: HostScreenPresenceRule.declinedReason)
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-presence-declined"),
            "a person's own decline reaches the wire as its own reason, not folded into the generic presence-check reason -- got \(String(describing: response))"
        )

        print("PASS: a declined answer refuses on the wire with host-screen-presence-declined")
    }

    do {
        // An unanswered prompt carries its own wire reason too
        let fixture = makeAdmissibleFixtureWithGate()
        let token = offerAndExtractToken(fixture.controller)
        fixture.signal.reading = .idleFor(0)
        fixture.gate.outcome = .refused(reason: HostScreenPresenceRule.unansweredReason)
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-presence-unanswered"),
            "a prompt's own thirty-second timeout reaches the wire as its own reason, distinct from a decline -- got \(String(describing: response))"
        )

        print("PASS: an unanswered prompt refuses on the wire with host-screen-presence-unanswered")
    }

    do {
        // Every other cause a gate can refuse for -- exclusivity, or
        // no gate configured at all -- keeps the one existing reason
        let fixture = makeAdmissibleFixtureWithGate()
        let token = offerAndExtractToken(fixture.controller)
        fixture.signal.reading = .idleFor(0)
        fixture.gate.outcome = .refused(reason: HostScreenPresenceGate.alreadyAskingReason)
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-presence-check-required"),
            "a gate refusing because another prompt was already showing keeps the wire's one existing presence-check reason -- got \(String(describing: response))"
        )

        print("PASS: a gate's own exclusivity refusal still refuses on the wire with host-screen-presence-check-required")
    }

    do {
        // A configured gate is never asked when idle time already
        // clears the threshold -- asking is only for .mustAsk
        let fixture = makeAdmissibleFixtureWithGate()
        let token = offerAndExtractToken(fixture.controller)
        // The fixture's own default reading already clears the threshold.
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            { if case .hostScreenReady = response { return true } else { return false } }(),
            "idle time well past the threshold admits without asking"
        )
        expect(fixture.gate.calls.isEmpty, "a configured gate is never asked when the idle signal alone already clears the threshold")
        expect(
            fixture.controller.hostScreenLastPresencePromptContent == nil,
            "no prompt content is recorded for a request that never needed to ask"
        )

        print("PASS: a configured gate is left untouched when idle time alone already admits the request")
    }

    do {
        // A failed presence-credential proof must never pop the
        // host prompt. Design §6.1 orders the signature
        // check (#5) before the host-presence rule (#6) -- a paired
        // device with a valid arming record and a legitimately-
        // minted token, but no live human at the viewer, must not
        // interrupt the person at the host for a connection that
        // can never succeed regardless of their answer.
        let fixture = makeAdmissibleFixtureWithGate()
        let token = offerAndExtractToken(fixture.controller)
        fixture.signal.reading = .idleFor(0) // forces .mustAsk
        fixture.verifier.result = false // the presence-credential proof itself fails
        fixture.gate.outcome = .proceed // if the gate were ever asked, it would approve
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(fixture.gate.calls.isEmpty, "a failed presence-credential proof must never reach the gate -- no prompt is shown to the person at the host for a connection the proof alone already dooms")
        expect(
            response == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "the refusal reason names the failed proof, unaffected by whether a gate was configured or what it would have answered"
        )

        print("PASS: a failed presence proof refuses before the gate is asked, whatever the idle time or the gate would say")
    }

    do {
        // Refusal never degrades: unminted token
        let fixture = makeAdmissibleFixture()
        _ = offerAndExtractToken(fixture.controller) // mints, but is never used
        let response = try! fixture.controller.handle(.hostScreenRequest(
            token: Data([0xFF, 0xFF]), presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-not-allowed"),
            "a token this session never minted refuses, the same as an unarmed device"
        )
        expectNoInjectorWasBuilt(fixture.injectorFactory, "unminted token")

        print("PASS: a token this session never minted is refused, indistinguishable from an unarmed device")
    }

    do {
        // The challenge is single-use
        // The first attempt here is deliberately made to fail (the fixture's
        // verifier flipped to refusing) rather than admitted: an admitted
        // first attempt would leave this connection's own live-surface
        // guard (`HostScreenMixedSessionTests.swift`'s own "second host-
        // screen request refuses" case) to refuse any second request
        // outright, masking whatever the challenge's own single-use
        // bookkeeping would have said. A failed first attempt keeps this
        // test isolated to that bookkeeping.
        let fixture = makeAdmissibleFixture()
        let token = offerAndExtractToken(fixture.controller)
        fixture.verifier.result = false
        let firstAttempt = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            firstAttempt == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "a failing verifier refuses the first attempt, admitting nothing"
        )

        // The challenge this offer minted was consumed by the first
        // attempt, whether or not it was going to succeed. The token
        // itself survives a failed presence check -- only a fresh offer
        // wipes it -- so this replay, with the verifier flipped back to
        // approving, still reaches the challenge check and finds none left.
        fixture.verifier.result = true
        let replay = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            replay == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "a second attempt over an already-consumed challenge still refuses, even with the verifier now approving"
        )
        expect(
            fixture.verifier.calls.count == 1,
            "the verifier is never even asked on the replay -- the missing challenge refuses first"
        )

        print("PASS: a challenge does not survive one use, successful or not, so a later attempt over it still refuses")
    }

    do {
        // Two offers, the same display: different tokens, the same
        // displayIdentity -- a token is per-connection by design,
        // but a viewer needs a stable way to say "that one again."
        let fixture = makeAdmissibleFixture()
        func nextEntry() -> HostScreenListEntry? {
            guard case let .hostScreenList(displays, _) = try! fixture.controller.offerHostScreenList(), let entry = displays.first else {
                expect(false, "the admissible fixture's offer names at least one display")
                return nil
            }
            return entry
        }
        guard let first = nextEntry(), let second = nextEntry() else {
            return
        }
        expect(first.opaqueToken != second.opaqueToken, "each offer mints its own one-shot token")
        expect(
            first.displayIdentity == second.displayIdentity,
            "the same physical display reports the same displayIdentity across two separate offers"
        )
        expect(!first.displayIdentity.isEmpty, "displayIdentity is never an empty placeholder")

        print("PASS: two consecutive offers of the same display mint different tokens but report the same displayIdentity")
    }

    do {
        // Input bounds come from the real display's geometry
        let fixture = makeAdmissibleFixture()
        let token = offerAndExtractToken(fixture.controller)
        _ = try! fixture.controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        // The fixture's display is 2560x1440 logical.
        _ = try! fixture.controller.handle(.input(.pointerMoved(x: 2560, y: 1440), surfaceID: nil))
        do {
            _ = try fixture.controller.handle(.input(.pointerMoved(x: 2561, y: 100), surfaceID: nil))
            expect(false, "a point outside the real display's bounds must be rejected")
        } catch HostSessionControllerError.invalidInput {
        } catch {
            expect(false, "an out-of-bounds host-screen point reports invalidInput, not \(error)")
        }

        print("PASS: host-screen input is validated against the real display's own geometry, not a compiled-in default")
    }

    do {
        // A second hello on an already-authenticated connection is a
        // protocol violation, session-fatal: a connection is one
        // shape for its whole life, and the viewer always opens a
        // fresh connection to change target, never repeats a hello
        // on this one.
        let fixture = makeAdmissibleFixture()
        do {
            _ = try fixture.controller.handle(.hello(protocolVersion: 1, deviceName: "Probe"))
            expect(false, "a second hello on an already-authenticated connection must throw")
        } catch HostSessionControllerError.helloAlreadyAccepted {
            expect(
                HostSessionControllerError.helloAlreadyAccepted.isSessionFatal,
                "a repeat hello is session-fatal -- HostNetworkSession drops the connection rather than continuing it"
            )
        } catch {
            expect(false, "a second hello reports helloAlreadyAccepted, not \(error)")
        }

        print("PASS: a second .hello on an already-authenticated connection throws the session-fatal helloAlreadyAccepted, not a silent no-op")
    }

    do {
        // The same guard catches a repeat .authenticatedHello, not
        // just a repeat .hello -- since e00cd28 a fresh
        // authenticatedHello pushes a fresh offer with fresh
        // tokens and challenge, which a repeat must never reach.
        let identity = try! DeviceIdentity.generate()
        let fixture = makeAdmissibleFixture()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        do {
            _ = try fixture.controller.handle(.authenticatedHello(
                protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
            ))
            expect(false, "a second authenticatedHello on an already-authenticated connection must throw")
        } catch HostSessionControllerError.helloAlreadyAccepted {
        } catch {
            expect(false, "a second authenticatedHello reports helloAlreadyAccepted, not \(error)")
        }

        print("PASS: a second .authenticatedHello on an already-authenticated connection throws helloAlreadyAccepted rather than re-authenticating and pushing a fresh offer")
    }

    do {
        // Two eligible displays macOS gave the identical name read as
        // themselves in the viewer's own Screen menu, not both as the
        // generic "External Display" -- and stay unique when they
        // collide, exactly as the arming rows already do.
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let firstMonitor = DisplaySnapshot(
            id: 21, pixelWidth: 2560, pixelHeight: 1440, modeWidth: 2560, modeHeight: 1440,
            modePixelWidth: 2560, modePixelHeight: 1440, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            online: true, builtin: false, main: false, vendorNumber: 0x15, modelNumber: 0x28,
            name: "LS27A800U"
        )
        let secondMonitor = DisplaySnapshot(
            id: 22, pixelWidth: 2560, pixelHeight: 1440, modeWidth: 2560, modeHeight: 1440,
            modePixelWidth: 2560, modePixelHeight: 1440, bounds: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
            online: true, builtin: false, main: false, vendorNumber: 0x16, modelNumber: 0x29,
            name: "LS27A800U"
        )
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let verifier = FakeHostScreenPresenceProofVerifier()
        let signal = FakeHostScreenLocalActivitySignal()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [firstMonitor, secondMonitor] },
            hostScreenPresenceProofVerifier: verifier,
            hostScreenLocalActivitySignal: signal
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList() else {
            expect(false, "an armed device with two eligible displays is offered a list, not a refusal")
            return
        }
        expect(
            displays.map(\.label) == ["LS27A800U", "LS27A800U (2)"],
            "the wire offer's own labels are told apart by offer order, matching the arming row's sentence"
        )

        print("PASS: offerHostScreenList suffixes a same-name display collision on the wire, just as the arming rows do")
    }

    do {
        // Per-machine "ask me first," off: a device armed without the
        // flag is admitted even with somebody right there, the gate is
        // never touched, and the session log says why.
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date(),
                asksWhenSomeoneIsUsingThisMachine: false
            )
        ])
        let verifier = FakeHostScreenPresenceProofVerifier()
        let signal = FakeHostScreenLocalActivitySignal()
        signal.reading = .idleFor(0) // somebody is right there
        let gate = FakeHostScreenPresenceGate()
        var loggedLines: [String] = []
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: verifier,
            hostScreenLocalActivitySignal: signal,
            hostScreenPresenceGate: gate,
            log: { loggedLines.append($0) }
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        let token = offerAndExtractToken(controller)
        let response = try! controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            { if case .hostScreenReady = response { return true } else { return false } }(),
            "a device armed with the ask-first flag off is admitted even with recent local input"
        )
        expect(gate.calls.isEmpty, "the gate is never asked when the armed device's own flag is off")
        expect(
            controller.hostScreenLastPresencePromptContent == nil,
            "no prompt content is recorded for a request that never needed to ask"
        )
        expect(
            loggedLines.contains { $0.contains("Kestrel Laptop Pro") && $0.contains("armed without asking first") },
            "the session log says this device is armed without asking first, so an owner reading the log knows why no prompt fired -- got \(loggedLines)"
        )

        print("PASS: a device armed with ask-first off is admitted without a prompt whatever the idle signal says, and logged")
    }

    do {
        // Per-machine "ask me first," on: unchanged behaviour -- the
        // gate is still asked with somebody right there.
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date(),
                asksWhenSomeoneIsUsingThisMachine: true
            )
        ])
        let verifier = FakeHostScreenPresenceProofVerifier()
        let signal = FakeHostScreenLocalActivitySignal()
        signal.reading = .idleFor(0)
        let gate = FakeHostScreenPresenceGate()
        gate.outcome = .proceed
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: verifier,
            hostScreenLocalActivitySignal: signal,
            hostScreenPresenceGate: gate
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        let token = offerAndExtractToken(controller)
        let response = try! controller.handle(.hostScreenRequest(
            token: token, presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            { if case .hostScreenReady = response { return true } else { return false } }(),
            "a device armed with the ask-first flag on is still admitted once the gate approves"
        )
        expect(gate.calls.count == 1, "the flag on keeps today's behaviour -- the gate is asked exactly once")

        print("PASS: a device armed with the ask-first flag on still asks the gate")
    }

    do {
        // A gap between what this machine has and what it can actually hand
        // over must never be silent: `offerHostScreenList` logs one line
        // per display it left out, naming the display and the exact
        // reason, and one "offered" line naming what it did include. A
        // canvas Sensorium created is not a gap and is not logged: it was
        // never a candidate.
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey

        let eligible = hostScreenTestDisplay(id: 1)
        let offlineDisplay = DisplaySnapshot(
            id: 2, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: false,
            builtin: false, main: false, vendorNumber: 0x10, modelNumber: 0x10
        )
        let sensoriumCanvasDisplay = DisplaySnapshot(
            id: 3, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: CanvasDisplayIdentity.vendorID, modelNumber: 0x20
        )
        let asleepDisplay = DisplaySnapshot(
            id: 4, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true, asleep: true,
            builtin: false, main: false, vendorNumber: 0x30, modelNumber: 0x30
        )
        let mirroredDisplay = DisplaySnapshot(
            id: 5, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true, mirrorsDisplay: 1,
            builtin: false, main: false, vendorNumber: 0x40, modelNumber: 0x40
        )

        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        var loggedLines: [String] = []
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: {
                [eligible, offlineDisplay, sensoriumCanvasDisplay, asleepDisplay, mirroredDisplay]
            },
            log: { loggedLines.append($0) }
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList() else {
            expect(false, "an armed device with one shareable display still receives hostScreenList")
            return
        }
        expect(displays.count == 1, "only the one display that can actually be captured is offered")

        let eligibleLabel = HostScreenArmingPresentation.displayLabel(for: eligible)
        expect(
            loggedLines.contains("Sensorium host: did not offer host screen \"External Display\" to Kestrel Laptop Pro: not online"),
            "a display CoreGraphics reports not online is logged with that exact reason -- got: \(loggedLines)"
        )
        expect(
            loggedLines.contains("Sensorium host: did not offer host screen \"External Display\" to Kestrel Laptop Pro: asleep"),
            "a display asleep right now is logged as asleep -- got: \(loggedLines)"
        )
        expect(
            loggedLines.contains("Sensorium host: did not offer host screen \"External Display\" to Kestrel Laptop Pro: mirrored"),
            "a display showing another display's picture is logged as mirrored -- got: \(loggedLines)"
        )
        expect(
            !loggedLines.contains { $0.contains("created by Sensorium") },
            "a canvas Sensorium created is not reported as a missing display -- got: \(loggedLines)"
        )
        expect(
            loggedLines.contains("Sensorium host: offered 1 host screens to Kestrel Laptop Pro: \(eligibleLabel)"),
            "what was actually offered is logged too, naming the device and the offered labels -- got: \(loggedLines)"
        )
        expect(loggedLines.count == 4, "exactly one line per unshareable display plus one offered line, no more -- got: \(loggedLines)")

        print("PASS: offerHostScreenList logs why each display it could not share was left out, and what it offered instead")
    }

    do {
        // A display that is asleep right now must not be offered, and the
        // gap is logged as asleep, not conflated with a display that is not
        // there at all.
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let awakeAtStart = hostScreenTestDisplay()
        let asleepNow = DisplaySnapshot(
            id: awakeAtStart.id, pixelWidth: awakeAtStart.pixelWidth, pixelHeight: awakeAtStart.pixelHeight,
            modeWidth: awakeAtStart.modeWidth, modeHeight: awakeAtStart.modeHeight,
            modePixelWidth: awakeAtStart.modePixelWidth, modePixelHeight: awakeAtStart.modePixelHeight,
            bounds: awakeAtStart.bounds, online: true, asleep: true,
            builtin: awakeAtStart.builtin, main: awakeAtStart.main,
            vendorNumber: awakeAtStart.vendorNumber, modelNumber: awakeAtStart.modelNumber
        )
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        var loggedLines: [String] = []
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [asleepNow] },
            log: { loggedLines.append($0) }
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        let offer = try! controller.offerHostScreenList()
        if case .hostScreenList(let displays, _) = offer {
            expect(displays.isEmpty, "a display asleep right now is offered to no one, whatever it was at host start -- got: \(displays.count)")
        }
        expect(
            loggedLines == [
                "Sensorium host: did not offer host screen \"External Display\" to Kestrel Laptop Pro: asleep"
            ],
            "a display asleep only at offer time is logged as asleep, not as absent or not present at start -- got: \(loggedLines)"
        )

        print("PASS: a display awake at host start but asleep at offer time is not offered, and the gap reads asleep")
    }

    do {
        // The mirror image of the case above: nothing armed fails, so
        // nothing is logged as missing, only the one offered line.
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let display = hostScreenTestDisplay()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        var loggedLines: [String] = []
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            log: { loggedLines.append($0) }
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        _ = try! controller.offerHostScreenList()
        expect(
            loggedLines == ["Sensorium host: offered 1 host screens to Kestrel Laptop Pro: External Display"],
            "a display offered cleanly logs nothing but the one offered line -- got: \(loggedLines)"
        )

        print("PASS: an offer with no gaps logs only the offered line, nothing about a missing display")
    }

    do {
        // Arming is per machine, not per display: an armed machine is
        // offered whatever this machine has at session time, including a
        // monitor attached after this host started, and never a canvas
        // Sensorium created.
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let monitor = hostScreenTestDisplay(id: 11)
        let canvas = DisplaySnapshot(
            id: 12, pixelWidth: 1920, pixelHeight: 1200, modeWidth: 1920, modeHeight: 1200,
            modePixelWidth: 1920, modePixelHeight: 1200, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
            online: true, builtin: false, main: false,
            vendorNumber: CanvasDisplayIdentity.vendorID, modelNumber: 0x1234
        )
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel Laptop Pro",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [monitor, canvas] }
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList() else {
            expect(false, "an armed machine is offered this machine's current displays, not refused")
            return
        }
        expect(
            displays.map(\.displayIdentity) == [HostScreenDisplayIdentity(monitor).wireStableIdentifier],
            "the one online display Sensorium did not create is offered, and the canvas is not -- got: \(displays.map(\.label))"
        )

        print("PASS: an armed machine is offered every online display Sensorium did not create, and never a canvas")
    }

    do {
        // Clipboard admission opens only at the point a host-screen session
        // is fully granted, and closes the moment it starts ending.
        let signed = HostScreenPresenceProof.signed(
            credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02])
        )

        let granted = makeAdmissibleFixture()
        expect(
            !granted.controller.isClipboardAdmissible,
            "an authenticated connection that has not been granted a host screen is not admissible for clipboard"
        )
        let token = offerAndExtractToken(granted.controller)
        expect(
            !granted.controller.isClipboardAdmissible,
            "an offer alone grants nothing"
        )
        guard case .hostScreenReady = try! granted.controller.handle(.hostScreenRequest(token: token, presence: signed)) else {
            expect(false, "the admissible fixture's request is admitted")
            return
        }
        expect(
            granted.controller.isClipboardAdmissible,
            "a fully granted host-screen session is admissible for clipboard"
        )
        expect(
            !granted.controller.isSessionAuthenticatedAndActive,
            "without widening the canvas-only gate"
        )
        granted.controller.noteSessionEnding()
        expect(
            !granted.controller.isClipboardAdmissible,
            "a host-screen session that has started ending is no longer admissible"
        )
        _ = try! granted.controller.handle(.goodbye(reason: "client-disconnected"))
        expect(
            !granted.controller.isClipboardAdmissible,
            "nor after its goodbye"
        )

        let unverified = makeAdmissibleFixture()
        unverified.verifier.result = false
        _ = try! unverified.controller.handle(.hostScreenRequest(
            token: offerAndExtractToken(unverified.controller), presence: signed
        ))
        expect(
            !unverified.controller.isClipboardAdmissible,
            "a request whose presence proof fails is never admissible for clipboard"
        )

        for refusal in [HostScreenPresenceRule.declinedReason, HostScreenPresenceRule.unansweredReason] {
            let asked = makeAdmissibleFixtureWithGate()
            asked.signal.reading = .idleFor(0)
            asked.gate.outcome = .refused(reason: refusal)
            _ = try! asked.controller.handle(.hostScreenRequest(
                token: offerAndExtractToken(asked.controller), presence: signed
            ))
            expect(
                !asked.controller.isClipboardAdmissible,
                "a request the person at this machine did not agree to (\(refusal)) is never admissible for clipboard"
            )
        }

        let approved = makeAdmissibleFixtureWithGate()
        approved.signal.reading = .idleFor(0)
        approved.gate.outcome = .proceed
        _ = try! approved.controller.handle(.hostScreenRequest(
            token: offerAndExtractToken(approved.controller), presence: signed
        ))
        expect(
            approved.controller.isClipboardAdmissible,
            "a request the person at this machine agreed to is admissible for clipboard"
        )

        print("PASS: clipboard admission for host screen opens only once the session is fully granted and closes as it ends")
    }

    do {
        // A session canvas follows the same rule: admission opens with the
        // live canvas and closes the moment the session starts ending, not
        // once its goodbye teardown has finished.
        let identity = try! DeviceIdentity.generate()
        let controller = HostSessionController(
            sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()) },
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Laptop",
            publicKey: identity.publicKey,
            signature: try! identity.sign(transcript)
        ))
        expect(!controller.isClipboardAdmissible, "an authenticated connection with no canvas is not admissible for clipboard")
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(controller.isClipboardAdmissible, "an authenticated session with a live canvas is admissible for clipboard")
        controller.noteSessionEnding()
        expect(
            !controller.isClipboardAdmissible,
            "a canvas session that has started ending is no longer admissible, before its goodbye teardown runs"
        )
        _ = try! controller.handle(.goodbye(reason: "client-disconnected"))
        expect(!controller.isClipboardAdmissible, "nor after its goodbye")

        print("PASS: clipboard admission for a session canvas closes as the session starts ending")
    }
}
