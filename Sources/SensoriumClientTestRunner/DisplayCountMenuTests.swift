import Foundation
import SensoriumClient
import SensoriumCore

/// docs/ux-spec.md's "Displays: 1 or 2" menu -- the pure plan
/// `ViewerMainMenuController` draws, and the refusal copy the window shows
/// when the host says no. Neither needs a menu bar or a window to verify.
@MainActor
func testDisplayCountMenuTests() async {
    do {
        let atOne = DisplayCountMenuPlan.items(selectedCount: 1)
        expect(atOne.map(\.title) == ["1 Display", "2 Displays"], "exactly the two rows docs/ux-spec.md names, in that order")
        expect(atOne.first { $0.count == 1 }?.isSelected == true, "the session's own current count is the one checked")
        expect(atOne.first { $0.count == 2 }?.isSelected == false, "and the other row is not")

        let atTwo = DisplayCountMenuPlan.items(selectedCount: 2)
        expect(atTwo.first { $0.count == 1 }?.isSelected == false, "the checkmark moves with the session's own state")
        expect(atTwo.first { $0.count == 2 }?.isSelected == true, "to whichever count is actually selected")

        expect(atOne.allSatisfy(\.isEnabled), "both rows are pickable by default, outside a host-screen session")

        print("PASS: the Displays menu offers exactly 1 and 2, checking whichever the session actually holds")
    }

    do {
        // A host-screen session disables both rows -- the host's own
        // mixed-session gate refuses a second display there, so the
        // menu offers nothing but a guaranteed refusal unless it is
        // disabled instead.
        let disabled = DisplayCountMenuPlan.items(selectedCount: 1, isEnabled: false)
        expect(disabled.allSatisfy { !$0.isEnabled }, "every row is disabled during a host-screen session")
        expect(
            disabled.first { $0.count == 1 }?.isSelected == true,
            "disabling the menu never changes which row is checked"
        )

        print("PASS: the Displays menu is disabled, not hidden, during a host-screen session")
    }

    do {
        // docs/ux-spec.md: "a refusal must be said in the window in plain
        // words with its reason" -- named reasons only; an unknown one is
        // quoted rather than translated, the same discipline
        // `ViewerSessionFailureCopy.canvasRefusalLine` already follows.
        expect(
            DisplayCountRefusalCopy.line(reason: "host-screen-session-active").localizedCaseInsensitiveContains("host screen"),
            "a host-screen session's own refusal says why in words a person reads, not the wire token"
        )
        expect(
            DisplayCountRefusalCopy.line(reason: "host-screen-session-active", hostLabel: "mac-mini")
                == "Could not add a second display: mac-mini is showing this machine a host screen, and a "
                    + "host screen allows only one display.",
            "the host-screen refusal names the machine showing the host screen, not just \"this connection\""
        )
        expect(
            DisplayCountRefusalCopy.line(reason: "display-count-exceeds-host-limit").localizedCaseInsensitiveContains("allow"),
            "the operator's own cap is explained as the other machine's own limit, not this machine's failure"
        )
        // This banner offers only a dismiss (\u{2715}) -- `ViewerTransientNoticeView`
        // has no second button -- so its remedy must point at the Displays
        // menu itself, never at a "Try again" the banner cannot offer.
        expect(
            DisplayCountRefusalCopy.line(reason: CanvasRefusalReason.creationInProgress)
                .localizedCaseInsensitiveContains("choose again from the displays menu"),
            "the single-flight creation gate's own refusal points at the Displays menu, the banner's only real remedy"
        )
        // HostSessionController's own catch-all for an admission failure
        // outside the creation gate (a genuine setup failure, not a busy
        // gate) -- a plain sentence of its own, not the raw wire token
        // quoted verbatim by the default case below.
        let changeFailed = DisplayCountRefusalCopy.line(reason: "display-count-change-failed")
        expect(
            changeFailed.localizedCaseInsensitiveContains("choose again from the displays menu"),
            "the host's own setup failure is explained as the other machine's own problem, with the Displays menu as the way to retry"
        )
        expect(
            !changeFailed.contains("display-count-change-failed"),
            "and reads as words for a person, not the wire token quoted at them"
        )
        let unknown = DisplayCountRefusalCopy.line(reason: "a-reason-this-build-has-never-seen")
        expect(
            unknown.contains("a\u{2011}reason\u{2011}this\u{2011}build\u{2011}has\u{2011}never\u{2011}seen"),
            "an unrecognised reason is quoted verbatim rather than silently dropped, with its own hyphens "
                + "replaced by non-breaking ones so the quoted token cannot wrap and split the quote pair "
                + "across lines"
        )
        expect(
            !unknown.isEmpty && unknown != "a-reason-this-build-has-never-seen",
            "and quoted inside a real sentence, not shown bare as if it were already words for a person"
        )
        expect(
            unknown.contains("second display:"),
            "the unrecognised-reason notice uses the same colon after \"second display\" as every other one"
        )
        expect(
            unknown == "Could not add a second display: the other machine gave a reason this version of "
                + "Sensorium does not know: \u{201C}a\u{2011}reason\u{2011}this\u{2011}build\u{2011}has\u{2011}"
                + "never\u{2011}seen.\u{201D} Update both apps, then try again.",
            "US punctuation puts the period inside the closing quote, and the notice ends with the one "
                + "step that can fix a token this build does not know -- got: \(unknown)"
        )

        expect(
            DisplayCountRefusalCopy.line(reason: "display-count-exceeds-host-limit", hostLabel: "mini")
                == "Could not add a second display: mini allows only one display, and that limit cannot be "
                    + "changed from this machine.",
            "the operator's own machine is named, not called \"the other machine\", when the caller has its label, "
                + "and the notice says the limit is not this machine's to change, since Sensorium Host has no "
                + "setting for it either"
        )
        expect(
            !DisplayCountRefusalCopy.line(reason: "display-count-exceeds-host-limit", hostLabel: "mini").contains("the other machine"),
            "and the generic phrase does not linger once a real label is given"
        )
        expect(
            DisplayCountRefusalCopy.line(reason: "display-count-exceeds-host-limit").contains("the other machine"),
            "leaving the label out still reads as a full sentence, for a caller with none to give"
        )

        print("PASS: every named Displays refusal reads as a plain sentence, and an unknown one is quoted rather than invented")
    }
}

/// The reconciliation a "Displays" refusal owes the session's own windows
/// -- `ClientSessionHost` is `private` to the executable target and cannot
/// be reached from here, so `SecondDisplayRefusalReconciliation` is the
/// pure seam that carries the decision where a test can reach it.
@MainActor
func testSecondDisplayRefusalReconciliationTests() async {
    do {
        let outcome = SecondDisplayRefusalReconciliation.outcome(hostWindowExists: true, runnerHasSecondaryWindow: true)
        expect(
            outcome.shouldCloseSecondWindow,
            "a refusal that finds a second window already open (a reconnect-time restore finding one "
                + "leftover from before the drop) must close it rather than leave it dimmed forever"
        )
        expect(outcome.publishedDisplayCount == 1, "the Displays menu is republished at 1 once the refusal is dealt with")
    }

    do {
        let outcome = SecondDisplayRefusalReconciliation.outcome(hostWindowExists: false, runnerHasSecondaryWindow: false)
        expect(
            !outcome.shouldCloseSecondWindow,
            "a refusal that finds no second window (a reconnect-time restore with none leftover) has nothing to close"
        )
        expect(outcome.publishedDisplayCount == 1, "the Displays menu still republishes at 1")
    }

    do {
        // A live increase refused before any window was ever opened --
        // `attachSecondDisplay` only builds `windows[1]` on
        // `onSecondDisplayReady`, never before, so this refusal always
        // finds `hostWindowExists == false`, the same shape as the case
        // above reached by a different path.
        let outcome = SecondDisplayRefusalReconciliation.outcome(hostWindowExists: false, runnerHasSecondaryWindow: false)
        expect(
            !outcome.shouldCloseSecondWindow,
            "a live increase refused before a window ever existed has nothing to close either"
        )
    }

    do {
        // A reconnect rebuilds `ClientSessionRunner` fresh
        // (`Sources/Sensorium/main.swift`'s `runOnce()`), so it starts with
        // no secondary attached even when `windows[1]` still holds one
        // leftover from before the drop. A refusal that arrives during
        // that reconnect's own re-ask must still close the leftover
        // window -- the decision must not follow `runnerHasSecondaryWindow`
        // here, only `hostWindowExists`. Reading the close decision from
        // `runner.detachSecondDisplay()`'s return value instead would find
        // exactly `nil` in this shape, and leave the window open, orphaned,
        // forever.
        let outcome = SecondDisplayRefusalReconciliation.outcome(hostWindowExists: true, runnerHasSecondaryWindow: false)
        expect(
            outcome.shouldCloseSecondWindow,
            "a leftover host-level window closes on refusal even when the fresh runner that received it never held one"
        )
    }

    print("PASS: a Displays refusal closes a leftover second window when one exists, and always republishes 1")
}
