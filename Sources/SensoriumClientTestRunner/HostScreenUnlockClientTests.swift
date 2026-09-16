#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SensoriumClient
import SensoriumCore

/// The viewer's half of the host-screen unlock: how the runner reads the host's
/// lock and unlock traffic, the bytes a typed password becomes, the rule for
/// offering the prompt, and the sentence each outcome shows. None of it needs a
/// live connection or a window.
@MainActor
func testHostScreenUnlockClientTests() async {
    do {
        // A lock-state report is read as one, either way
        expect(
            ClientSessionRunner.hostScreenUnlockInbound(for: .hostScreenLockState(locked: true))
                == .lockState(locked: true),
            "a locked report arriving mid-session is read as one"
        )
        expect(
            ClientSessionRunner.hostScreenUnlockInbound(for: .hostScreenLockState(locked: false))
                == .lockState(locked: false),
            "and so is an unlocked report"
        )
        print("PASS: the viewer reads the host's lock-state report as itself")
    }

    do {
        // Every unlock answer is read as itself, carrying the outcome
        let outcomes: [HostScreenUnlockOutcome] = [
            .tooManyAttempts,
            .unlocked, .wrongPassword, .screenSharingUnavailable,
            .notLocked, .notAuthorized, .passwordTooLong, .failed(reason: "some-token")
        ]
        for outcome in outcomes {
            expect(
                ClientSessionRunner.hostScreenUnlockInbound(for: .hostScreenUnlockResult(outcome))
                    == .result(outcome),
                "an unlock answer arriving mid-session is read as one, carrying its outcome -- \(outcome)"
            )
        }
        print("PASS: the viewer reads each host unlock answer as itself, carrying its outcome")
    }

    do {
        // The host's unlock challenge is read as one, carrying its bytes, so
        // the receive loop can hand it to the submission waiting to sign it.
        expect(
            ClientSessionRunner.hostScreenUnlockInbound(for: .hostScreenUnlockChallenge(challenge: Data([0x07])))
                == .challenge(challenge: Data([0x07])),
            "the host's unlock challenge is read as one, carrying its bytes"
        )
        print("PASS: the viewer reads the host's unlock challenge as itself, carrying its bytes")
    }

    do {
        // Nothing else on the wire is mistaken for lock traffic
        expect(
            ClientSessionRunner.hostScreenUnlockInbound(for: .goodbye(reason: "whatever")) == nil,
            "a message that is not lock traffic is not read as any"
        )
        expect(
            ClientSessionRunner.hostScreenUnlockInbound(for: .hostScreenUnlockRequest(password: Data([1, 2, 3]))) == nil,
            "and the viewer's own outbound request is not read back as an inbound answer"
        )
        print("PASS: the viewer mistakes nothing else on the wire for lock traffic")
    }

    do {
        // The prompt is offered exactly when the screen is locked
        expect(
            HostScreenUnlockCopy.shouldOfferUnlockPrompt(locked: true),
            "a locked host screen is when the unlock prompt belongs on screen"
        )
        expect(
            !HostScreenUnlockCopy.shouldOfferUnlockPrompt(locked: false),
            "and an unlocked one is when it does not"
        )
        print("PASS: the viewer offers the unlock prompt exactly while the host screen is locked")
    }

    do {
        // A typed password becomes exactly its UTF-8 bytes, nothing added
        let typed = "p\u{00E4}ss w0rd"
        let bytes = HostScreenUnlockCopy.passwordBytes(from: typed)
        expect(
            bytes == Data(typed.utf8),
            "the bytes sent are exactly the password's UTF-8, with no terminator or framing this side adds"
        )
        expect(
            HostScreenUnlockCopy.passwordBytes(from: "").isEmpty,
            "and an empty field is empty bytes, not a byte of padding"
        )
        print("PASS: a typed password becomes exactly its UTF-8 bytes")
    }

    do {
        // Every outcome reads as a sentence, never a wire token
        let everyOutcome: [HostScreenUnlockOutcome] = [
            .unlocked, .wrongPassword, .screenSharingUnavailable,
            .notLocked, .notAuthorized, .tooManyAttempts, .passwordTooLong,
            .presenceRequired, .failed(reason: "aes-key-derivation-failed")
        ]
        let lines = everyOutcome.map { HostScreenUnlockCopy.noticeLine(for: $0) }
        for line in lines {
            expect(line.hasSuffix("."), "each notice is a full sentence -- got: \(line)")
            expect(
                !line.contains("wrong-password") && !line.contains("not-authorized")
                    && !line.contains("screen-sharing-unavailable") && !line.contains("too-many-attempts"),
                "no notice shows a wire token to a person -- got: \(line)"
            )
            expect(
                !line.contains("device"),
                "a paired machine is called a machine, never a device -- got: \(line)"
            )
            expect(
                !line.contains("host screen"),
                "a locked login window belongs to the host machine, not to one of its screens -- got: \(line)"
            )
        }
        expect(
            !HostScreenUnlockCopy.noticeLine(for: .tooManyAttempts).lowercased().contains("reconnect"),
            "the too-many-attempts notice never tells the person to reconnect -- reconnecting does not help"
        )
        expect(
            HostScreenUnlockCopy.noticeLine(for: .tooManyAttempts)
                != HostScreenUnlockCopy.noticeLine(for: .wrongPassword),
            "being out of attempts does not read the same as one wrong password"
        )
        expect(
            HostScreenUnlockCopy.noticeLine(for: .wrongPassword)
                != HostScreenUnlockCopy.noticeLine(for: .unlocked),
            "a wrong password and a success do not read the same"
        )
        expect(
            !HostScreenUnlockCopy.noticeLine(for: .failed(reason: "aes-key-derivation-failed"))
                .contains("aes-key-derivation-failed"),
            "the failed case's internal reason is a log token, never shown to a person"
        )
        print("PASS: every host unlock outcome reads as a sentence, never a wire token")
    }

    do {
        // A submit that never reached the host speaks its own notice; only a
        // submit that armed and sent stays silent for the host's own answer.
        expect(
            HostScreenUnlockCopy.submitNotice(for: .armed) == nil,
            "an armed submit shows no notice of its own -- the host's answer comes next"
        )
        expect(
            HostScreenUnlockCopy.submitNotice(for: .presenceFailed) == HostScreenUnlockCopy.presenceCancelledNotice,
            "a cancelled presence check surfaces the presence-cancelled notice"
        )
        expect(
            HostScreenUnlockCopy.submitNotice(for: .challengeTimedOut) == HostScreenUnlockCopy.challengeTimedOutNotice,
            "a challenge that never arrived surfaces the timed-out notice"
        )
        expect(
            HostScreenUnlockCopy.submitNotice(for: .couldNotSend) == HostScreenUnlockCopy.couldNotSendNotice,
            "a submit that could not be sent surfaces the couldn't-send notice"
        )
        // A rejected concurrent submit surfaces no notice: the still-pending
        // first submit owns the prompt, and telling the person nothing new
        // leaves that submit's in-flight state (its disabled prompt) untouched.
        expect(
            HostScreenUnlockCopy.submitNotice(for: .alreadyInFlight) == nil,
            "a submit rejected because one is already in flight shows no notice of its own"
        )
        // A viewer-side presence cancel and a host-side arm refusal are
        // different situations and must not read the same.
        expect(
            HostScreenUnlockCopy.presenceCancelledNotice != HostScreenUnlockCopy.noticeLine(for: .presenceRequired),
            "the viewer's own presence-cancelled notice does not read like the host's presence-required refusal"
        )
        for line in [
            HostScreenUnlockCopy.presenceCancelledNotice,
            HostScreenUnlockCopy.challengeTimedOutNotice
        ] {
            expect(line.hasSuffix("."), "each submit notice is a full sentence -- got: \(line)")
            expect(
                !line.contains("presence-required") && !line.contains("challenge") && !line.contains("in-flight"),
                "no submit notice shows a wire token to a person -- got: \(line)"
            )
        }
        print("PASS: each unlock-submit result reads as its own sentence, distinct from the host's presence-required refusal")
    }

#if canImport(AppKit)
    do {
        // The presence-cancelled notice reaches the eye through the same
        // showResult an outcome notice does, so a still-locked lock report
        // after it leaves it standing to be read.
        let panel = ViewerUnlockPanelView()
        panel.show()
        panel.showResult(HostScreenUnlockCopy.presenceCancelledNotice)
        expect(
            panel.noticeText == HostScreenUnlockCopy.presenceCancelledNotice,
            "a cancelled presence check renders its notice on the prompt"
        )
        print("PASS: the presence-cancelled notice renders on the prompt")
    }
#endif

#if canImport(AppKit)
    do {
        // The reported bug: the host writes an unlock result, then a fresh
        // lock-state report; on a still-locked screen that re-offers the
        // prompt in the same round trip. The re-offer must not wipe the
        // notice the result just set, or the person sees no answer at all.
        let panel = ViewerUnlockPanelView()
        let wrongPassword = HostScreenUnlockCopy.noticeLine(for: .wrongPassword)

        panel.show()
        expect(!panel.isHidden, "the prompt is on screen once offered")
        expect(panel.noticeText.isEmpty, "a first-time offer starts with no notice")

        panel.showResult(wrongPassword)
        expect(panel.noticeText == wrongPassword, "an unlock result puts its notice on the prompt")

        panel.show()
        expect(!panel.isHidden, "the still-locked screen keeps the prompt up")
        expect(
            panel.noticeText == wrongPassword,
            "offering an already-visible prompt again leaves its notice standing -- got: \(panel.noticeText)"
        )

        panel.hide()
        panel.show()
        expect(panel.noticeText.isEmpty, "a fresh offer from hidden still starts clean")

        print("PASS: re-offering a visible unlock prompt keeps the result notice, and a fresh offer starts clean")
    }
#endif

#if canImport(AppKit)
    do {
        // Return-to-submit is the field's own, not a global button key
        // equivalent. A "\r" key equivalent on the Unlock button runs before
        // keyDown for every bare Return in the window; while a locked host
        // screen is live the focus stays on the canvas, so such a Return would
        // fire Unlock instead of reaching the host.
        let panel = ViewerUnlockPanelView()
        let button = panel.subviews.compactMap { $0 as? NSButton }.first
        let field = panel.subviews.compactMap { $0 as? NSSecureTextField }.first
        expect(button != nil, "the panel has its Unlock button")
        expect(field != nil, "the panel has its secure field")
        expect(
            button?.keyEquivalent == "",
            "the Unlock button carries no global Return key equivalent -- got: \(button?.keyEquivalent ?? "<nil>")"
        )
        expect(field?.target != nil, "the secure field submits through its own target")
        expect(field?.action != nil, "the secure field submits through its own action, so Return in it still works")
        print("PASS: Return-to-submit is bound to the field, not a global button key equivalent")
    }

    do {
        // An empty field submits nothing: the host would only answer that the
        // password was wrong, so the round trip and that notice are spared.
        let panel = ViewerUnlockPanelView()
        let field = panel.subviews.compactMap { $0 as? NSSecureTextField }.first
        expect(field != nil, "the panel has its secure field")

        var submissions: [Data] = []
        panel.onSubmit = { submissions.append($0) }

        field?.stringValue = ""
        panel.submit()
        expect(submissions.isEmpty, "submitting an empty field sends nothing -- got: \(submissions)")

        field?.stringValue = "hunter2"
        panel.submit()
        expect(
            submissions == [Data("hunter2".utf8)],
            "a non-empty field still submits exactly its bytes -- got: \(submissions)"
        )
        expect(field?.stringValue == "", "and the field is cleared once a real submission is on its way")
        print("PASS: an empty field submits nothing; a non-empty field still submits its bytes")
    }

    do {
        // A dropped unlock send is surfaced, not swallowed. The runner reports
        // whether the request left, and false becomes this plain notice -- a
        // silently dropped send would leave the person with a cleared field and
        // no word of what happened.
        // The runner's own do/catch is exercised in a live session, not here:
        // its connection is a socket-bound NetworkControlConnection with no unit
        // seam. What is reachable is the copy and how it reaches the eye, both
        // through the same showResult the window's send-failure path calls.
        expect(
            HostScreenUnlockCopy.couldNotSendNotice.hasSuffix(".")
                && !HostScreenUnlockCopy.couldNotSendNotice.contains("closed"),
            "the couldn't-send notice is a sentence, naming no wire error -- got: \(HostScreenUnlockCopy.couldNotSendNotice)"
        )
        let panel = ViewerUnlockPanelView()
        panel.showResult(HostScreenUnlockCopy.couldNotSendNotice)
        expect(
            panel.noticeText == HostScreenUnlockCopy.couldNotSendNotice,
            "the couldn't-send copy renders as the prompt's notice, like any other result"
        )
        print("PASS: the couldn't-send notice is a plain sentence and renders on the prompt")
    }

    do {
        // A submit disables the field and the Unlock button until it
        // resolves, so a person cannot fire a second submit into the host round
        // trip and the multi-second presence prompt that follow.
        let panel = ViewerUnlockPanelView()
        panel.show()
        expect(panel.isAcceptingInput, "a freshly offered prompt accepts input")

        let field = panel.subviews.compactMap { $0 as? NSSecureTextField }.first
        field?.stringValue = "hunter2"
        panel.submit()
        expect(!panel.isAcceptingInput, "a submit in flight disables the field and the Unlock button")

        panel.showResult(HostScreenUnlockCopy.noticeLine(for: .wrongPassword))
        expect(panel.isAcceptingInput, "the prompt accepts input again once the submit resolves")

        // An empty submit is a no-op and must not disable the prompt.
        panel.show()
        field?.stringValue = ""
        panel.submit()
        expect(panel.isAcceptingInput, "an empty submit sends nothing and leaves the prompt usable")
        print("PASS: a submit disables the prompt until it resolves; an empty submit leaves it usable")
    }

    do {
        // EVERY terminal resolution of an in-flight submit re-enables
        // the prompt, so a person can always retry. Each failure branch --
        // presence cancelled, challenge timed out, send failure, and any host
        // unlock outcome -- reaches the panel through showResult, and each must
        // leave the field and Unlock button usable again.
        let resolutions: [String] = [
            HostScreenUnlockCopy.presenceCancelledNotice,
            HostScreenUnlockCopy.challengeTimedOutNotice,
            HostScreenUnlockCopy.couldNotSendNotice,
            HostScreenUnlockCopy.noticeLine(for: .wrongPassword),
            HostScreenUnlockCopy.noticeLine(for: .notAuthorized),
            HostScreenUnlockCopy.noticeLine(for: .failed(reason: "some-token"))
        ]
        for notice in resolutions {
            let panel = ViewerUnlockPanelView()
            panel.show()
            let field = panel.subviews.compactMap { $0 as? NSSecureTextField }.first
            field?.stringValue = "hunter2"
            panel.submit()
            expect(!panel.isAcceptingInput, "the submit disables the prompt before resolving")
            panel.showResult(notice)
            expect(panel.isAcceptingInput, "resolving with a notice re-enables the prompt -- \(notice)")
        }
        print("PASS: every notice-carrying resolution of an in-flight submit re-enables the prompt")
    }

    do {
        // A rejected concurrent submit (.alreadyInFlight) must
        // NOT touch the prompt -- the still-pending first submit owns it and
        // will re-enable on its own resolution. It surfaces no notice, so
        // nothing calls showResult and the disabled state stands.
        let panel = ViewerUnlockPanelView()
        panel.show()
        let field = panel.subviews.compactMap { $0 as? NSSecureTextField }.first
        field?.stringValue = "hunter2"
        panel.submit()
        expect(!panel.isAcceptingInput, "the first submit disables the prompt")
        expect(
            HostScreenUnlockCopy.submitNotice(for: .alreadyInFlight) == nil,
            "a rejected concurrent submit surfaces no notice, so nothing re-enables the prompt"
        )
        expect(!panel.isAcceptingInput, "so the prompt stays disabled, owned by the still-pending first submit")
        print("PASS: a rejected concurrent submit leaves the owning submit's disabled prompt alone")
    }
#endif
}
