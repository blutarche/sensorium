import Foundation
import SensoriumClient
import SensoriumCore

/// Counts `sign()` calls -- design §6.5's own point of a resume ticket: a
/// held ticket is a self-contained substitute for a fresh presence check,
/// so presenting one must never touch the credential at all. Ordinary
/// `SoftwarePresenceCredential`, never the Secure Enclave, wrapped rather
/// than modified so no production type carries test-only bookkeeping.
private actor CountingPresenceCredential: PresenceCredentialProviding {
    private let inner = SoftwarePresenceCredential()
    nonisolated let strength = PresenceCredentialStrength.softwarePresence
    private(set) var signCount = 0

    func register() async throws -> PresenceCredentialRegistration {
        try await inner.register()
    }

    func sign(challenge: Data) async throws -> Data {
        signCount += 1
        return try await inner.sign(challenge: challenge)
    }
}

/// Counts calls -- design §6.5's "never in a retry loop": a refused resume
/// ticket must end the run without a second connection attempt following it.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
func testHostScreenSessionFlowTests() async {
    do {
        // "no list means no Host screen items": nothing offered
        // leaves Virtual Display as the only row, selected.
        let state = ScreenMenuPlan.items(displays: [], selectedToken: nil)

        expect(
            state == [ScreenMenuItem(token: nil, title: "Virtual Display", isSelected: true)],
            "with no hostScreenList ever received, the Screen menu offers only Virtual display"
        )

        print("PASS: no host-screen offer means no Host screen row, only Virtual display")
    }

    do {
        // Every offered display becomes its own row, named and
        // selected exactly as the host described it.
        let builtin = HostScreenListEntry(
            opaqueToken: Data([0x01]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: "00000610-0000a038"
        )
        let external = HostScreenListEntry(
            opaqueToken: Data([0x02]), label: "External Display",
            logicalWidth: 2560, logicalHeight: 1440, backingScale: 1.0, isBuiltin: false,
            displayIdentity: "00000610-0000a189"
        )

        let items = ScreenMenuPlan.items(displays: [builtin, external], selectedToken: Data([0x02]))

        expect(
            items == [
                ScreenMenuItem(token: nil, title: "Virtual Display", isSelected: false),
                ScreenMenuItem(token: Data([0x01]), title: "Built-in Display", isSelected: false),
                ScreenMenuItem(token: Data([0x02]), title: "External Display", isSelected: true)
            ],
            "each offered display is its own row, named from the host's own label, and only the selected token's row is checked"
        )

        print("PASS: every offered display is its own Screen menu row, named and checked correctly")
    }

    do {
        // Every reason HostSessionController.swift can actually send
        // reads as a plain sentence, never a raw wire token.
        let knownReasons = [
            "canvas-session-active",
            "host-screen-not-allowed",
            "host-screen-presence-check-required",
            "host-screen-needs-rearming",
            "host-screen-credential-unknown",
            "host-screen-session-active"
        ]
        // The overlay's headline names the host above every reason line, so
        // no line names it again: "that machine" is the subject throughout, and
        // a long name is never repeated within four lines.
        for reason in knownReasons {
            let line = HostScreenRefusalCopy.line(reason: reason)
            expect(!line.contains(reason), "\(reason) reads as a sentence, not the raw wire token quoted back")
            expect(
                line.hasSuffix(".") && line.contains(" "),
                "\(reason) is a sentence, never a token -- got \(line)"
            )
        }
        expect(
            HostScreenRefusalCopy.line(reason: "a-future-reason")
                .contains("a\u{2011}future\u{2011}reason"),
            "an unknown reason is quoted verbatim rather than invented a cause for, with its own hyphens "
                + "replaced by non-breaking ones so the quoted token cannot wrap and split the quote pair "
                + "across lines"
        )
        expect(
            HostScreenRefusalCopy.line(reason: "a-future-reason")
                == "That machine gave a reason this version of Sensorium does not know: "
                    + "\u{201C}a\u{2011}future\u{2011}reason.\u{201D} Update both apps, then connect with a "
                    + "virtual display.",
            "an unknown reason's remedy never promises a fresh Host screen pick this build cannot honour, "
                + "since it does not know what went wrong, and US punctuation puts the period inside the "
                + "closing quote -- got: "
                + "\(HostScreenRefusalCopy.line(reason: "a-future-reason"))"
        )

        print("PASS: every named host-screen refusal reads as a plain sentence, and an unknown one is quoted rather than invented")
    }

    do {
        // "host-screen-display-unavailable" is this client's own --
        // never sent by the host -- and reads as a plain sentence,
        // not the default case's "a reason this version does not
        // know", since this build invented it and knows exactly what
        // it means.
        let line = HostScreenRefusalCopy.line(reason: "host-screen-display-unavailable")
        expect(!line.contains("host-screen-display-unavailable"), "the wire token never reaches the reader")
        expect(!line.contains("does not know"), "this build minted the reason itself, so it is not an unknown one")
        expect(line.localizedCaseInsensitiveContains("no longer available"), "says plainly that the screen is gone")
        expect(
            line == "The screen you chose is no longer available there. Connect with a virtual display, then "
                + "choose another host screen from the Screen menu.",
            "the one gone screen never rules out a different host screen that may still be available -- "
                + "got \(line)"
        )

        print("PASS: host-screen-display-unavailable reads as a plain sentence, not the unknown-reason default")
    }

    do {
        // "host-screen-resume-refused" -- design §6.5: the host's own
        // reason for a resume ticket it would not honour, distinct
        // from every other reason the same reply carries, so the
        // person is told to pick a host screen again rather than
        // left waiting on a redial that will never come.
        let line = HostScreenRefusalCopy.line(reason: "host-screen-resume-refused")
        expect(
            line == "The connection was interrupted and could not resume. Connect with a "
                + "virtual display, then choose a host screen from the Screen menu.",
            "host-screen-resume-refused never promises the one button on screen will choose a host screen "
                + "directly, since it only ever reconnects with a virtual display -- got \(line)"
        )

        print("PASS: host-screen-resume-refused steers the person to a fresh Host screen pick without repeating the host the headline names")
    }

    do {
        // The remaining named reasons, rewritten to plain sentence
        // case and to name the host's own toggle exactly.
        let canvasSessionActive = HostScreenRefusalCopy.line(reason: "canvas-session-active")
        expect(
            canvasSessionActive == "That machine was already showing this machine a virtual display. That session "
                + "has ended. Connect with a virtual display, then choose a host screen from the Screen menu.",
            "canvas-session-active must say the connection's own session ended, not just what it could not "
                + "do -- receiving this reason is what ends it -- got \(canvasSessionActive)"
        )

        // host-screen-session-active fires only on the same connection a
        // host-screen request already fixed -- HostSessionController's
        // `hostScreenSurface` and `connectionShape` are per-connection state
        // with no cross-connection path to this reason -- so it mirrors
        // canvas-session-active's own wording rather than the "earlier
        // connection" case, which cannot occur here.
        let hostScreenSessionActive = HostScreenRefusalCopy.line(reason: "host-screen-session-active")
        expect(
            hostScreenSessionActive == "That machine was already showing this machine a host screen. That session "
                + "has ended. Connect with a virtual display, then choose a host screen from the Screen menu.",
            "host-screen-session-active mirrors canvas-session-active's own wording in the opposite "
                + "direction, since both fire on the same connection -- got \(hostScreenSessionActive)"
        )

        let hostScreenNotAllowed = HostScreenRefusalCopy.line(reason: "host-screen-not-allowed")
        expect(
            hostScreenNotAllowed == "Sensorium Host on that machine has host screen turned off for this machine.",
            "host-screen-not-allowed says host screen is off for this machine, without claiming this machine "
                + "never had it -- pairing itself may have armed it, and the person at that machine turned it off -- "
                + "got \(hostScreenNotAllowed)"
        )

        let presenceCheckRequired = HostScreenRefusalCopy.line(reason: "host-screen-presence-check-required")
        expect(
            presenceCheckRequired == "That machine needed to ask and could not. Connect with "
                + "a virtual display, then choose a host screen from the Screen menu to try again.",
            "host-screen-presence-check-required must not imply a specific person declined, since the same "
                + "reason fires when no gate was configured or another prompt was already on screen -- "
                + "got \(presenceCheckRequired)"
        )

        let presenceDeclined = HostScreenRefusalCopy.line(reason: "host-screen-presence-declined")
        expect(
            presenceDeclined == "The person at that machine chose not to share its screen this time. Connect "
                + "with a virtual display, then choose a host screen from the Screen menu \u{2014} they will "
                + "be asked again.",
            "host-screen-presence-declined must say plainly that a person declined -- got \(presenceDeclined)"
        )

        let presenceUnanswered = HostScreenRefusalCopy.line(reason: "host-screen-presence-unanswered")
        expect(
            presenceUnanswered == "No one at that machine answered the request within thirty seconds. "
                + "Connect with a virtual display, then choose a host screen from the Screen menu to ask again.",
            "host-screen-presence-unanswered must say the window closed with no answer, not that anyone "
                + "declined -- got \(presenceUnanswered)"
        )

        print("PASS: canvas-session-active, host-screen-session-active, host-screen-not-allowed, "
            + "host-screen-presence-check-required, host-screen-presence-declined and "
            + "host-screen-presence-unanswered read as design specifies")
    }

    do {
        // Copy that names a button not on screen: the overlay only
        // ever offers to reconnect with a virtual display here, never
        // "Try again" or a direct return to a host screen.
        let retryNeedsPerson = HostScreenRefusalCopy.line(reason: "host-screen-retry-needs-person")
        expect(
            retryNeedsPerson == "The connection dropped. Showing a host screen again needs a "
                + "fresh confirmation on this machine. Connect with a virtual display, then choose a host screen "
                + "from the Screen menu.",
            "host-screen-retry-needs-person must say the check proves a person at the viewer, not at "
                + "the host -- got \(retryNeedsPerson)"
        )

        print("PASS: host-screen-retry-needs-person never promises a check the one button on screen cannot do")
    }

    do {
        // "host-screen-needs-rearming" is a host-side fix: the
        // device is armed and did register a credential, but the
        // host's arming record predates its strength snapshot, and
        // only turning the host's own toggle off and back on fixes
        // it -- pairing again changes nothing here.
        let needsRearming = HostScreenRefusalCopy.line(reason: "host-screen-needs-rearming")
        expect(
            needsRearming == "That machine needs \u{201C}Share host screen\u{201D} for this machine turned off and "
                + "back on. Do that in Sensorium Host there.",
            "host-screen-needs-rearming quotes the host's own toggle by its exact label -- got \(needsRearming)"
        )

        // The key belongs to this viewer and is registered with the
        // host, never the other way round, and the sentence has to
        // say plainly what pairing again is for: the host holds a
        // key this machine no longer has.
        let credentialUnknown = HostScreenRefusalCopy.line(reason: "host-screen-credential-unknown")
        expect(
            credentialUnknown == "That machine does not have this machine's current presence key. Pair with that "
                + "machine again to register it, then try the host screen again.",
            "host-screen-credential-unknown names what is missing and what to do about it, in that order, "
                + "without repeating the host's name the headline above already shows -- got \(credentialUnknown)"
        )

        print("PASS: host-screen-needs-rearming names the host's own toggle, and host-screen-credential-unknown says which machine is missing the key and what to do about it")
    }

    do {
        // Only the one reason pairing again can actually fix offers
        // it; every other reason, including needs-rearming's own
        // host-side fix, keeps its one button.
        expect(
            HostScreenRefusalCopy.offersPairAgain(reason: "host-screen-credential-unknown"),
            "a credential the host no longer recognizes can only be replaced by pairing again"
        )
        for reason in [
            "canvas-session-active", "host-screen-not-allowed", "host-screen-presence-check-required",
            "host-screen-presence-declined", "host-screen-presence-unanswered",
            "host-screen-needs-rearming", "host-screen-display-unavailable", "host-screen-retry-needs-person",
            "host-screen-resume-refused", "host-screen-session-active", "a-reason-this-build-has-never-seen"
        ] {
            expect(
                !HostScreenRefusalCopy.offersPairAgain(reason: reason),
                "\(reason) is not fixed by pairing again, so it offers no pairing shortcut, got true"
            )
        }

        print("PASS: offersPairAgain is true only for host-screen-credential-unknown")
    }

    do {
        // hostScreenOutcome classifies every session-time host-screen
        // reply, the same way secondDisplayOutcome already does for
        // the Displays menu's own live reply.
        let displays = [HostScreenListEntry(
            opaqueToken: Data([0xAA]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: "00000610-0000a038"
        )]
        let challenge = Data("a-challenge".utf8)
        expect(
            ClientSessionRunner.hostScreenOutcome(for: .hostScreenList(displays: displays, challenge: challenge))
                == .offered(displays: displays, challenge: challenge),
            "a hostScreenList reply is classified as the host's own offer, unchanged"
        )

        expect(
            ClientSessionRunner.hostScreenOutcome(for: .hostScreenRefused(reason: "host-screen-not-allowed"))
                == .refused(reason: "host-screen-not-allowed"),
            "a hostScreenRefused reply is classified as refused, carrying the host's own reason unchanged"
        )

        expect(
            ClientSessionRunner.hostScreenOutcome(for: .displayCount(2)) == nil,
            "a message unrelated to host screen classifies as nothing, the same as secondDisplayOutcome's own default"
        )

        print("PASS: hostScreenOutcome classifies every session-time host-screen reply, and nothing else")
    }

    do {
        // connect(target: .hostScreen) never sends canvasRequest --
        // design §9's "no mixed session": a connection that only ever
        // speaks the host-screen shape must never speak the other one,
        // not even by accident.
        let credential = SoftwarePresenceCredential()
        let displayIdentity = "00000610-0000a038"
        let entry = HostScreenListEntry(
            opaqueToken: Data([0x09]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let challenge = Data("host-screen-challenge".utf8)
        let geometry = SessionSurfaceGeometry(logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0)
        let resumeTicket = Data([0x01, 0x02])
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [entry], challenge: challenge),
            .hostScreenReady(geometry: geometry, resumeTicket: resumeTicket)
        ])
        let controller = ClientSessionController(transport: transport, credentialProvider: credential)

        let outcome = try! await controller.connect(
            deviceName: "Laptop",
            target: .hostScreen(displayIdentity: displayIdentity)
        )

        expect(
            outcome == .hostScreen(geometry: geometry, resumeTicket: resumeTicket),
            "a .hostScreen connect that reaches hostScreenReady returns the geometry and resume ticket it carried"
        )
        expect(
            await transport.sent.allSatisfy { if case .canvasRequest = $0 { return false } else { return true } },
            "a .hostScreen connect never sends canvasRequest"
        )

        print("PASS: a .hostScreen connect never sends canvasRequest")
    }

    do {
        // connect(target: .sessionCanvas) never sends hostScreenRequest
        // -- the same one-shape-per-connection rule, from the other
        // side.
        let transport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 55, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0)
        ])
        let controller = ClientSessionController(transport: transport)

        let outcome = try! await controller.connect(deviceName: "Laptop", target: .sessionCanvas)

        expect(
            outcome == .canvas(displayID: 55, hostScreenOffer: []),
            "a .sessionCanvas connect returns the canvas's own displayID"
        )
        expect(
            await transport.sent.allSatisfy { if case .hostScreenRequest = $0 { return false } else { return true } },
            "a .sessionCanvas connect never sends hostScreenRequest"
        )

        print("PASS: a .sessionCanvas connect never sends hostScreenRequest")
    }

    do {
        // A refused host-screen connect ends the connect with a thrown
        // error, carrying the host's own reason -- never a silent
        // fallback to a session canvas, since a failed presence check
        // is exactly when it is least clear who is at the viewer.
        let credential = SoftwarePresenceCredential()
        let transport = ScriptedClientTransport(responses: [
            .hostScreenRefused(reason: "host-screen-not-allowed")
        ])
        let controller = ClientSessionController(transport: transport, credentialProvider: credential)

        do {
            _ = try await controller.connect(
                deviceName: "Laptop",
                target: .hostScreen(displayIdentity: "00000610-0000a038")
            )
            expect(false, "a refused host-screen connect must throw, never return a substituted outcome")
        } catch ClientSessionError.hostScreenRefused(let reason) {
            expect(reason == "host-screen-not-allowed", "the thrown error carries the host's own refusal reason unchanged")
        } catch {
            expect(false, "a refused host-screen connect threw the wrong error type: \(error)")
        }
        expect(
            await transport.sent.allSatisfy { if case .canvasRequest = $0 { return false } else { return true } },
            "a refused host-screen connect never falls back to canvasRequest on the same connection"
        )

        print("PASS: a refused host-screen connect throws and never falls back to a session canvas")
    }

    do {
        // Two entries offering the same displayIdentity are refused,
        // not silently resolved to whichever one `first(where:)`
        // happens to find -- which of the two was meant is not this
        // client's to guess.
        let credential = SoftwarePresenceCredential()
        let displayIdentity = "00000610-0000a038"
        let first = HostScreenListEntry(
            opaqueToken: Data([0x01]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let second = HostScreenListEntry(
            opaqueToken: Data([0x02]), label: "Built-in Display (duplicate)",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [first, second], challenge: Data("a-challenge".utf8))
        ])
        let controller = ClientSessionController(transport: transport, credentialProvider: credential)

        do {
            _ = try await controller.connect(deviceName: "Laptop", target: .hostScreen(displayIdentity: displayIdentity))
            expect(false, "two entries sharing one displayIdentity must refuse, never pick one silently")
        } catch ClientSessionError.hostScreenRefused(let reason) {
            expect(reason == "host-screen-display-unavailable", "a duplicate identity refuses with the same reason a missing one does")
        } catch {
            expect(false, "a duplicate displayIdentity threw the wrong error type: \(error)")
        }
        expect(
            await transport.sent.allSatisfy { if case .hostScreenRequest = $0 { return false } else { return true } },
            "a duplicate identity never sends hostScreenRequest for either entry"
        )

        print("PASS: two entries sharing one displayIdentity refuse the connect rather than resolving to either one")
    }

    do {
        // A connect that presents a held resume ticket sends
        // `.resumeTicket`, carrying exactly those bytes, and never
        // signs -- design §6.5: the ticket is a self-contained
        // substitute for a fresh presence check, and this is the
        // ordinary, silent case a transport interruption resumes
        // through.
        let credential = CountingPresenceCredential()
        let displayIdentity = "00000610-0000a038"
        let entry = HostScreenListEntry(
            opaqueToken: Data([0x07]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let heldTicket = Data([0x11, 0x22, 0x33])
        let geometry = SessionSurfaceGeometry(logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0)
        let refreshedTicket = Data([0x44, 0x55])
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [entry], challenge: Data("a-challenge".utf8)),
            .hostScreenReady(geometry: geometry, resumeTicket: refreshedTicket)
        ])
        let controller = ClientSessionController(transport: transport, credentialProvider: credential)

        let outcome = try! await controller.connect(
            deviceName: "Laptop",
            target: .hostScreen(displayIdentity: displayIdentity),
            resumeTicket: heldTicket
        )

        expect(
            outcome == .hostScreen(geometry: geometry, resumeTicket: refreshedTicket),
            "a resumed connect returns the host's freshly minted ticket, not the one that was presented"
        )
        let sentRequest = await transport.sent.first { if case .hostScreenRequest = $0 { return true } else { return false } }
        guard case let .hostScreenRequest(_, presence) = sentRequest else {
            expect(false, "the connect never sent a hostScreenRequest at all")
            return
        }
        expect(presence == .resumeTicket(heldTicket), "the request presents exactly the held ticket's own bytes")
        expect(await credential.signCount == 0, "presenting a held ticket never signs the challenge")

        print("PASS: a connect given a held resume ticket presents it and never signs")
    }

    do {
        // A refused resume ticket on automatic redial stops the run
        // outright -- design §6.5's "automatic reconnection either
        // presents a valid ticket or stops," never a second attempt
        // that falls back to signing on the same run.
        let credential = CountingPresenceCredential()
        let displayIdentity = "00000610-0000a038"
        let entry = HostScreenListEntry(
            opaqueToken: Data([0x08]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let attempts = AttemptCounter()
        let events = RecordedReconnectEvents()
        let driver = ClientReconnectDriver(
            policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 3),
            runSession: {
                attempts.increment()
                let transport = ScriptedClientTransport(responses: [
                    .hostScreenList(displays: [entry], challenge: Data("a-challenge".utf8)),
                    .hostScreenRefused(reason: "host-screen-needs-rearming")
                ])
                let controller = ClientSessionController(transport: transport, credentialProvider: credential)
                _ = try await controller.connect(
                    deviceName: "Laptop",
                    target: .hostScreen(displayIdentity: displayIdentity),
                    resumeTicket: Data([0x99])
                )
            },
            sleep: { _ in
                expect(false, "a refused resume ticket must never wait for a retry")
            },
            onEvent: { events.append($0) }
        )

        let outcome = await driver.runUntilConnectedSessionEnds()

        expect(outcome == .stopped, "a refused resume ticket ends the run outright, got: \(outcome)")
        expect(attempts.value == 1, "no second connection attempt follows a refused resume ticket")
        expect(await credential.signCount == 0, "a refused resume ticket never falls back to a signed proof")
        expect(
            events.all == [.attemptFailed(.hostScreenRefused(reason: "host-screen-needs-rearming"))],
            "exactly one failure is reported, with no retrying event ever following it"
        )

        print("PASS: a refused resume ticket on automatic redial stops without a second attempt or a sign")
    }

    do {
        // A connect given no ticket -- a user-initiated pick --
        // always signs and sends no `resumeTicket`, even when the
        // caller could have held one for this exact display.
        // `ClientSessionHost.selectRealScreen` is what guarantees
        // `resumeTicket` is `nil` on that call; this confirms what
        // `connect()` itself does with that `nil`.
        let credential = CountingPresenceCredential()
        let displayIdentity = "00000610-0000a038"
        let entry = HostScreenListEntry(
            opaqueToken: Data([0x0A]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let geometry = SessionSurfaceGeometry(logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0)
        let mintedTicket = Data([0x66])
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [entry], challenge: Data("a-challenge".utf8)),
            .hostScreenReady(geometry: geometry, resumeTicket: mintedTicket)
        ])
        let controller = ClientSessionController(transport: transport, credentialProvider: credential)

        _ = try! await controller.connect(
            deviceName: "Laptop",
            target: .hostScreen(displayIdentity: displayIdentity)
        )

        expect(await credential.signCount == 1, "a connect given no ticket signs exactly once")
        let sentRequest = await transport.sent.first { if case .hostScreenRequest = $0 { return true } else { return false } }
        guard case let .hostScreenRequest(_, presence) = sentRequest else {
            expect(false, "the connect never sent a hostScreenRequest at all")
            return
        }
        if case .resumeTicket = presence {
            expect(false, "a connect given no ticket must never send .resumeTicket")
        } else {
            expect(true, "a connect given no ticket sends a signed proof, never a ticket")
        }

        print("PASS: a connect given no ticket always signs and never sends a resume ticket")
    }

    do {
        // A host-screen connect's own geometry, not the session-
        // canvas preset, is what a pointer event maps into -- a
        // real display is whatever size it already is, never
        // 1920x1200 by construction the way a session canvas always
        // is. Severe finding from the viewer-chain review: every
        // click on a display of any other size landed scaled by
        // 1920/actualWidth, and the true edges were unreachable.
        let sink = RecordingInputSink()
        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: sink
        )
        await viewport.canvasDidBecomeReady()

        // A host-screen connect's own reply carries this display's real
        // geometry -- reconfigured here exactly as `ClientSessionHost`
        // does it before returning control to anything that could deliver
        // a pointer event.
        await viewport.updateMapper(geometry: SessionSurfaceGeometry(logicalWidth: 2560, logicalHeight: 1440, backingScale: 2.0))
        await viewport.setViewportSize(width: 2560, height: 1440)
        let hostScreenCorner = await viewport.movePointer(x: 2560, y: 1440)
        expect(
            hostScreenCorner == .delivered(CanvasInputPoint(x: 2560, y: 1440)),
            "the far corner of a 2560x1440 real display maps to (2560, 1440), not the 1920x1200 preset -- got \(hostScreenCorner)"
        )

        // Returning to Virtual display restores the canvas preset --
        // design's "a session streams exactly one of two targets."
        await viewport.updateMapper(geometry: .sessionCanvasDefault)
        await viewport.setViewportSize(width: 1920, height: 1200)
        let canvasCorner = await viewport.movePointer(x: 1920, y: 1200)
        expect(
            canvasCorner == .delivered(CanvasInputPoint(x: 1920, y: 1200)),
            "returning to the virtual display maps the far corner back onto the 1920x1200 preset -- got \(canvasCorner)"
        )

        print("PASS: a host-screen connect's own geometry maps pointer input, and returning to Virtual display restores the preset")
    }

    do {
        // Design §6.5 "never in a retry loop": an automatic redial
        // holding no ticket for the target signs nothing and stops
        // outright -- the same `HostScreenResumeTicketRetention`
        // decision `ClientSessionHost.runOnce()` calls before ever
        // touching the credential, exercised through the driver so
        // the "no second attempt" half of the rule is proven too.
        let credential = CountingPresenceCredential()
        let displayIdentity = "00000610-0000a038"
        let attempts = AttemptCounter()
        let events = RecordedReconnectEvents()
        let driver = ClientReconnectDriver(
            policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 3),
            runSession: {
                attempts.increment()
                if HostScreenResumeTicketRetention.mustStopBeforeSigning(
                    target: .hostScreen(displayIdentity: displayIdentity),
                    ticketToPresent: nil,
                    isPersonInitiated: false
                ) {
                    throw ClientSessionError.hostScreenRefused("host-screen-retry-needs-person")
                }
                _ = try await credential.sign(challenge: Data())
            },
            sleep: { _ in
                expect(false, "an automatic redial with no ticket held must never wait for a retry")
            },
            onEvent: { events.append($0) }
        )

        let outcome = await driver.runUntilConnectedSessionEnds()

        expect(outcome == .stopped, "an automatic redial with no ticket held ends the run outright, got: \(outcome)")
        expect(attempts.value == 1, "no second connection attempt follows it")
        expect(await credential.signCount == 0, "an automatic redial with no ticket held never signs")
        expect(
            events.all == [.attemptFailed(.hostScreenRefused(reason: "host-screen-retry-needs-person"))],
            "exactly one failure is reported, with no retrying event ever following it"
        )

        print("PASS: an automatic redial with no ticket held signs nothing and stops without a second attempt")
    }

    do {
        // A host that fails verification -- a certificate pin or host
        // key mismatch -- must stop the retry loop exactly as a
        // refused host-screen connect already does: trying again
        // would only pin whatever answered, wrong reflex, so this is
        // terminal, not a backoff-and-redial candidate.
        let attempts = AttemptCounter()
        let events = RecordedReconnectEvents()
        let driver = ClientReconnectDriver(
            policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 0.5, multiplier: 1, maximumAttempts: 3),
            runSession: {
                attempts.increment()
                throw ClientSessionError.hostKeyMismatch
            },
            sleep: { _ in
                expect(false, "a host that fails verification must never wait for a retry")
            },
            onEvent: { events.append($0) }
        )

        let outcome = await driver.runUntilConnectedSessionEnds()

        expect(outcome == .stopped, "a host that fails verification ends the run outright, got: \(outcome)")
        expect(attempts.value == 1, "no second attempt follows a failed verification")
        expect(
            events.all == [.attemptFailed(.unverifiedHost)],
            "exactly one failure is reported, with no retrying event ever following it"
        )

        print("PASS: a host that fails verification stops the retry loop after exactly one attempt")
    }

    do {
        // `updateMapper(geometry:)` must land before `canvasDidBecomeReady()`
        // opens the `isCanvasReady` gate, in the same actor call --
        // `ClientViewportController` is reentrant across
        // `canvasDidBecomeReady()`'s own suspension inside a real
        // drawable-size round trip, so a `movePointer` queued during that
        // suspension already sees the gate open. Applying the geometry only
        // after `connect()` fully returns would leave exactly that gap open.
        let sink = GatedDrawableSizeSink()
        let displayIdentity = "00000610-0000a038"
        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: sink
        )
        // A real window has already reported its drawable size before any
        // connect -- `canvasDidBecomeReady()`'s own resend of it is what
        // suspends on the gated sink below. Double the real display's own
        // pixels, not a match for it, so the resend computes a scale other
        // than `StreamScalePolicy.defaultScale` and actually reaches the
        // sink regardless of which mapper -- the old geometry or the new --
        // is in effect at that moment.
        _ = await viewport.setDrawableSize(pixelWidth: 5120, pixelHeight: 2880)
        await viewport.setViewportSize(width: 2560, height: 1440)

        let geometry = SessionSurfaceGeometry(logicalWidth: 2560, logicalHeight: 1440, backingScale: 2.0)
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [
                HostScreenListEntry(
                    opaqueToken: Data([0x0B]), label: "Built-in Display",
                    logicalWidth: 2560, logicalHeight: 1440, backingScale: 2.0, isBuiltin: true,
                    displayIdentity: displayIdentity
                )
            ], challenge: Data("a-challenge".utf8)),
            .hostScreenReady(geometry: geometry, resumeTicket: Data([0x77]))
        ])
        let credential = CountingPresenceCredential()
        let controller = ClientSessionController(transport: transport, credentialProvider: credential)
        await controller.setCanvasObserver(viewport)

        let connectTask = Task {
            try await controller.connect(deviceName: "Laptop", target: .hostScreen(displayIdentity: displayIdentity))
        }
        await sink.waitUntilEntered()

        // `canvasDidBecomeReady()` is still suspended inside
        // `sendViewerDrawableSize` right now -- a pointer event delivered
        // this instant must already map through the new 2560x1440
        // geometry, not the 1920x1200 the mapper was constructed with.
        let corner = await viewport.movePointer(x: 2560, y: 1440)
        expect(
            corner == .delivered(CanvasInputPoint(x: 2560, y: 1440)),
            "a pointer event delivered while the connect is still suspended must map through the new geometry -- got \(corner)"
        )

        await sink.openGate()
        _ = try! await connectTask.value

        print("PASS: updateMapper lands before canvasDidBecomeReady opens the gate, closing a reentrant actor's own race")
    }

    do {
        // A transport whose own start() throws once (a host briefly
        // unreachable) and would then succeed, driven through the real
        // `ClientReconnectDriver`, must
        // never sign on the automatic redial that follows.
        // `ClientSessionHost`/`runOnce()` live in the `Sensorium`
        // executable target and cannot be constructed here; this
        // composes the same two pieces `runOnce()` composes --
        // `HostScreenConnectPlan`, computed first, and a
        // `transport.start()` that can fail and be retried after it
        // -- in the same order, to prove the flag's own consumption
        // is what closes the gap, not something about `runOnce()`
        // itself that a unit test elsewhere could not reach.
        let displayIdentity = "00000610-0000a038"
        let credential = CountingPresenceCredential()
        let attempts = AttemptCounter()
        let isPersonInitiated = UncheckedFlag()
        isPersonInitiated.set(true)
        let hasTransportStarted = UncheckedFlag()
        let driver = ClientReconnectDriver(
            policy: ReconnectPolicy(initialDelay: 0.01, maximumDelay: 0.01, multiplier: 1, maximumAttempts: 3),
            runSession: {
                attempts.increment()
                // Computed and consumed before the transport's own start(),
                // exactly where `runOnce()` now does it -- the fix under
                // test is that this line, not the throw below, is what
                // decides whether this attempt may sign.
                let plan = HostScreenConnectPlan.compute(
                    target: .hostScreen(displayIdentity: displayIdentity),
                    heldTicket: nil,
                    isPersonInitiated: isPersonInitiated.value
                )
                isPersonInitiated.set(false)
                if !hasTransportStarted.value {
                    hasTransportStarted.set(true)
                    throw ClientSessionError.notConnected
                }
                if plan.mustStopBeforeSigning {
                    throw ClientSessionError.hostScreenRefused("host-screen-retry-needs-person")
                }
                _ = try await credential.sign(challenge: Data())
            },
            sleep: { _ in }
        )

        let outcome = await driver.runUntilConnectedSessionEnds()

        expect(outcome == .stopped, "the automatic redial's own plan stops the run outright, got: \(outcome)")
        expect(attempts.value == 2, "the first attempt's own transport failure, then the automatic redial that stops -- no third attempt")
        expect(
            await credential.signCount == 0,
            "no attempt ever signs -- the first never reached the credential, the second's own plan stopped it first"
        )

        print("PASS: a transport that fails once and would then succeed never lets the automatic redial that follows sign")
    }

    do {
        // A host that recently saw activity puts up its own confirmation
        // prompt first -- a person there may take up to
        // `HostScreenPresenceRule.promptTimeout` to answer it, on top
        // of the viewer's own presence check and network transport. A
        // `.hostScreen` connect must default to `hostScreenGrant`, sized
        // for that wait, never `canvasCreation`, which waits on no other
        // person. Both targets share one small `SessionTimeouts` here so
        // the test proves which field each target actually reads, not
        // just that some deadline exists -- real sleeps kept short by
        // injecting the timeouts rather than waiting out the real
        // 45-second and 15-second defaults.
        let shortTimeouts = SessionTimeouts(handshake: 0.05, canvasCreation: 0.1, hostScreenGrant: 0.5)
        let perReplyDelay = Duration.milliseconds(150)

        let credential = SoftwarePresenceCredential()
        let displayIdentity = "00000610-0000a038"
        let entry = HostScreenListEntry(
            opaqueToken: Data([0x0C]), label: "Built-in Display",
            logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let geometry = SessionSurfaceGeometry(logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0)
        let resumeTicket = Data([0x0D])
        // Two replies (hostScreenList, then hostScreenReady) each wait
        // 150ms -- about 300ms in all, longer than a host-prompt-free
        // canvas connect ever takes, but well inside hostScreenGrant's 500ms.
        let hostScreenTransport = DelayedClientTransport(
            responses: [
                .hostScreenList(displays: [entry], challenge: Data("a-challenge".utf8)),
                .hostScreenReady(geometry: geometry, resumeTicket: resumeTicket)
            ],
            delay: perReplyDelay
        )
        let hostScreenController = ClientSessionController(transport: hostScreenTransport, credentialProvider: credential)

        let hostScreenOutcome = try! await hostScreenController.connect(
            deviceName: "Laptop",
            target: .hostScreen(displayIdentity: displayIdentity),
            timeouts: shortTimeouts
        )

        expect(
            hostScreenOutcome == .hostScreen(geometry: geometry, resumeTicket: resumeTicket),
            "a .hostScreen connect defaults to hostScreenGrant, not canvasCreation, so a host slow to answer because a "
                + "person there must approve it does not time out"
        )

        // The same delay applied to a single canvasReady reply -- about
        // 150ms, longer than shortTimeouts.canvasCreation's 100ms -- must
        // still time out: `.sessionCanvas` never picks up hostScreenGrant.
        let canvasTransport = DelayedClientTransport(
            responses: [
                .canvasReady(displayID: 61, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
            ],
            delay: perReplyDelay
        )
        let canvasController = ClientSessionController(transport: canvasTransport)

        do {
            _ = try await canvasController.connect(
                deviceName: "Laptop",
                target: .sessionCanvas,
                timeouts: shortTimeouts
            )
            expect(false, "a .sessionCanvas connect must still time out at canvasCreation, not inherit hostScreenGrant")
        } catch ClientSessionError.timedOut {
        } catch {
            expect(false, "a .sessionCanvas connect that exceeded canvasCreation reported the wrong error: \(error)")
        }

        print("PASS: a .hostScreen connect defaults to hostScreenGrant while .sessionCanvas still times out at canvasCreation")
    }

    do {
        // A drawable size reported before the connect even started is
        // resent once the connect's own geometry is known -- against that
        // geometry, not the 1920x1200 the controller was constructed with.
        // 3220x2100 is chosen so the two bases actually disagree:
        // `StreamScalePolicy.scale` quantizes it to 1.75x against a
        // 1920x1200 canvas and to 1.50x against this 2048x1152 display, so a
        // resend computed from the wrong mapper is not just stale, it is a
        // different number the host would apply differently too.
        let sink = RecordingInputSink()
        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: sink
        )
        let delivery = await viewport.setDrawableSize(pixelWidth: 3220, pixelHeight: 2100)
        expect(delivery == .droppedNotConnected, "a drawable size reported before any connect has nothing to send yet -- got \(delivery)")

        await viewport.updateMapper(geometry: SessionSurfaceGeometry(logicalWidth: 2048, logicalHeight: 1152, backingScale: 2.0))
        await viewport.canvasDidBecomeReady()

        let hostComputedScale = StreamScalePolicy.scale(
            drawablePixelWidth: 3220, drawablePixelHeight: 2100,
            canvasLogicalWidth: 2048, canvasLogicalHeight: 1152
        )
        expect(hostComputedScale == 1.5, "sanity check on the chosen numbers: the host's own math on a 2048x1152 display should read 1.5x, got \(String(describing: hostComputedScale))")

        let requested = await viewport.requestedStreamScale
        expect(requested == 1.5, "the resend on connect must derive its scale from the connect's own geometry, not the 1920x1200 the controller started with -- got \(requested)")

        let sent = await sink.drawableSizes
        guard case let .viewerDrawableSize(sentWidth, sentHeight, _, _) = sent.last else {
            expect(false, "canvasDidBecomeReady never resent the drawable size it was holding")
            print("PASS: a drawable size reported before connect resends against the connect's own geometry")
            return
        }
        expect(
            sentWidth == 3220 && sentHeight == 2100,
            "the resend must carry the real drawable pixels, not a rounded or substituted value -- got \(sentWidth)x\(sentHeight)"
        )

        print("PASS: a drawable size reported before connect resends against the connect's own geometry")
    }

    do {
        // A live host-screen session whose display mode changes mid-session
        // -- the one reconfiguration the v1 invariant allows -- must tell the
        // host the new scale its already-known drawable pixels derive
        // against the new geometry. `onHostScreenModeApplied` only ever
        // calls `updateMapper`, never `setDrawableSize` again, so the
        // re-derivation has to happen inside `updateMapper` itself.
        let sink = RecordingInputSink()
        let viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 2048, logicalHeight: 1152),
            pointerSink: sink
        )
        await viewport.canvasDidBecomeReady()
        let firstDelivery = await viewport.setDrawableSize(pixelWidth: 3220, pixelHeight: 2100)
        expect(firstDelivery == .sent(1.5), "this window's drawable, reported against the display's real 2048x1152, should read 1.5x -- got \(firstDelivery)")

        // The person picks a different resolution from the Display menu; the
        // host applies it and reports back new geometry, exactly what
        // `onHostScreenModeApplied` hands to `updateMapper` alone.
        await viewport.updateMapper(geometry: SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1200, backingScale: 2.0))

        let requestedAfterModeChange = await viewport.requestedStreamScale
        expect(
            requestedAfterModeChange == 1.75,
            "the same drawable pixels read as 1.75x against the new 1920x1200 mode, but the scale stayed stuck at the old mode's 1.5x -- got \(requestedAfterModeChange)"
        )

        let sentAfterModeChange = await sink.drawableSizes
        expect(
            sentAfterModeChange.count == 2,
            "a mode change that actually moves the quantized scale must resend the drawable size, not leave the host applying the old mode's scale -- got \(sentAfterModeChange.count) sends"
        )

        print("PASS: a live display-mode change re-derives and resends the scale against the new geometry")
    }
}
