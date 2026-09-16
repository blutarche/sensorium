import AppKit
import CoreGraphics
import Foundation
import SensoriumHost

/// `HostScreenPresencePromptWindowController`'s own copy and controls --
/// design §6.2's host-screen presence prompt, exercised without ever calling
/// `ask()` (which blocks on a real modal session), the same "construct, then
/// read fields back with `Mirror`" approach `HostSetupTailscaleButtonTests`
/// already uses for a window this package builds but a test must never show.
@MainActor
func runHostScreenPresencePromptTests() async {
    func field<T>(_ name: String, of controller: HostScreenPresencePromptWindowController, as type: T.Type) -> T {
        for child in Mirror(reflecting: controller).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("HostScreenPresencePromptWindowController no longer has a stored property named \(name) of type \(T.self)")
    }

    do {
        // Eyebrow: names which app is asking, and asks for a real
        // screen -- "Screen Sharing Request" collides with macOS's
        // own Screen Sharing feature, which this is not.
        let eyebrow = CanvasHostTestHooks.presencePromptEyebrowText(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        expect(
            eyebrow == "SENSORIUM HOST \u{00B7} HOST SCREEN REQUEST",
            "the eyebrow names the app asking and what it asks for -- a host screen, not macOS's own Screen "
                + "Sharing feature -- got: \(eyebrow)"
        )

        print("PASS: the presence prompt's eyebrow reads Sensorium Host · Host Screen Request")
    }

    do {
        // Eyebrow colour: a request is not a failure -- the gold
        // a missing permission gets would say the wrong thing here.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let eyebrow: NSTextField = field("eyebrow", of: controller, as: NSTextField.self)
        let color = eyebrow.attributedStringValue.attribute(
            .foregroundColor, at: 0, effectiveRange: nil
        ) as? NSColor
        expect(
            color == CanvasDesign.muted2.nsColor,
            "a host-screen request is a normal ask, not an alert -- it keeps the neutral grey eyebrow colour every "
                + "other status line uses, not the gold a missing permission or a failure gets -- got: \(String(describing: color))"
        )

        print("PASS: the presence prompt's eyebrow is the neutral grey, not gold")
    }

    do {
        // Subtitle: what Allow actually does and why this machine is
        // asking -- never a passive status line that leaves both
        // unsaid.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let subtitle: NSTextField = field("subtitle", of: controller, as: NSTextField.self)
        expect(
            subtitle.stringValue == "If you allow, Kestrel Laptop Pro sees and controls \u{201C}\u{2060}Built-in Display\u{201D} "
                + "until you click Stop on the badge that stays on screen, or it disconnects. You\u{2019}re asked because "
                + "this machine was used in the last "
                + "few minutes.",
            "the subtitle names what Allow does (this device sees and controls the display until Stop on the "
                + "badge, or disconnect) and why this machine is asking (recent local use), not just that it is sharing "
                + "something -- got: \(subtitle.stringValue)"
        )

        print("PASS: the presence prompt's subtitle names what Allow does and why the prompt appeared")
    }

    do {
        // A display label containing its own commas must not be read
        // as more clauses of the surrounding sentence.
        let longLabel = "LG UltraFine 5K Display, connected over Thunderbolt 3 (Left of Built-in Display)"
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: longLabel)
        )
        let subtitle: NSTextField = field("subtitle", of: controller, as: NSTextField.self)
        expect(
            subtitle.stringValue == "If you allow, Kestrel Laptop Pro sees and controls \u{201C}\u{2060}\(longLabel)\u{201D} "
                + "until you click Stop on the badge that stays on screen, or it disconnects. You\u{2019}re asked because "
                + "this machine was used in the last "
                + "few minutes.",
            "curly quotes around the label mark where it starts and ends, so its own commas and parentheses are "
                + "never mistaken for more clauses of the surrounding sentence -- got: \(subtitle.stringValue)"
        )

        print("PASS: the presence prompt's subtitle quotes a display label that carries its own commas")
    }

    do {
        // Countdown: a live "Don't Allow will be chosen automatically in M:SS."
        // line, not a static sentence that never moves, and one that
        // names who acts at zero.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let timeoutLine: NSTextField = field("timeoutLine", of: controller, as: NSTextField.self)
        expect(
            timeoutLine.stringValue == "Don\u{2019}t Allow will be chosen automatically in 0:30.",
            "freshly constructed, the whole thirty-second window is still ahead, so the line reads its start value -- got: \(timeoutLine.stringValue)"
        )

        print("PASS: the presence prompt starts its countdown line at the design's own thirty-second window")
    }

    do {
        // Buttons: "Don't Allow", never "Refuse" -- the same verb the
        // affirmative button already uses, not a mismatched pair.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let allowButton: NSButton = field("allowButton", of: controller, as: NSButton.self)
        let refuseButton: NSButton = field("refuseButton", of: controller, as: NSButton.self)
        expect(allowButton.attributedTitle.string == "Allow", "the affirmative button still reads Allow")
        expect(
            refuseButton.attributedTitle.string == "Don\u{2019}t Allow",
            "the negative button reads Don\u{2019}t Allow, not Refuse -- the same verb as the affirmative button"
        )

        print("PASS: the presence prompt's buttons read Allow and Don't Allow")
    }

    do {
        // Don't Allow is the window's default and its only filled
        // button: Return triggers it, its layer carries the design's
        // accent fill, and Allow is a plain bordered button with no
        // fill of its own -- one emphasised button, not two, so a
        // failed or unanswered check is never one accidental
        // keystroke from granting anything.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let allowButton: NSButton = field("allowButton", of: controller, as: NSButton.self)
        let refuseButton: NSButton = field("refuseButton", of: controller, as: NSButton.self)
        expect(
            refuseButton.keyEquivalent == "\r",
            "Don't Allow is the safe default -- Return chooses it, matching the design's own \"a failed, "
                + "cancelled, or unanswered check refuses the whole session\""
        )
        expect(
            allowButton.keyEquivalent.isEmpty,
            "Allow carries no keyEquivalent -- granting a host screen always takes a deliberate click, never a keystroke"
        )
        expect(
            refuseButton.layer?.backgroundColor == CanvasDesign.accent.cgColor,
            "Don't Allow is the single filled button, in the design's own accent colour, not the red \"bad\" "
                + "colour a refusal action might suggest -- got \(String(describing: refuseButton.layer?.backgroundColor))"
        )
        expect(
            allowButton.layer?.backgroundColor == nil,
            "Allow carries no fill of its own -- got \(String(describing: allowButton.layer?.backgroundColor))"
        )
        expect(
            allowButton.isBordered,
            "Allow is a plain, natively bordered button, not one of this window's custom layer-drawn buttons"
        )
        expect(
            !refuseButton.isBordered,
            "Don't Allow stays a custom, layer-drawn filled button"
        )
        expect(
            allowButton.layer?.borderWidth == 1 && allowButton.layer?.borderColor == CanvasDesign.line2.cgColor,
            "with no fill of its own, Allow carries a hairline border in the launcher's own inactive-row stroke "
                + "colour, so it still reads as a button beside the filled Don\u{2019}t Allow -- got width "
                + "\(String(describing: allowButton.layer?.borderWidth)), colour \(String(describing: allowButton.layer?.borderColor))"
        )

        print("PASS: Don't Allow is the presence prompt's single filled default button, and Allow is a plain bordered button with no fill")
    }

    do {
        // Subtitle must never cap out at a fixed line count: a long
        // display label already pushes the new, longer subtitle past
        // three lines, and `maximumNumberOfLines` does not just clip
        // the drawn text -- it caps what NSTextField reports for its
        // own intrinsic height, which is what the window's own
        // Auto Layout-driven auto-grow sizes against. A capped label
        // silently drops its own trailing sentence instead of ever
        // asking for the room to show it.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let subtitle: NSTextField = field("subtitle", of: controller, as: NSTextField.self)
        expect(
            subtitle.maximumNumberOfLines == 0,
            "the subtitle carries no line cap, so a long display label can push it past three lines and the "
                + "window still grows to show all of it -- got maximumNumberOfLines == \(subtitle.maximumNumberOfLines)"
        )

        print("PASS: the presence prompt's subtitle has no line cap to silently drop text behind")
    }

    do {
        // Headline must never cap out either: a very long device name
        // pushes it past three lines the same way a long display
        // label pushes the subtitle, and both fields need a
        // `preferredMaxLayoutWidth` for Auto Layout to report the
        // right intrinsic height on the first layout pass.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let headline: NSTextField = field("headline", of: controller, as: NSTextField.self)
        let subtitle: NSTextField = field("subtitle", of: controller, as: NSTextField.self)
        expect(
            headline.stringValue == "Kestrel Laptop Pro wants to see and control a display of this machine",
            "the headline asks for one display, the same thing the subtitle names, not this machine's whole screen "
                + "-- got: \(headline.stringValue)"
        )
        expect(
            headline.maximumNumberOfLines == 0,
            "the headline carries no line cap, so a long device name can push it past three lines and the "
                + "window still grows to show all of it -- got maximumNumberOfLines == \(headline.maximumNumberOfLines)"
        )
        expect(
            headline.preferredMaxLayoutWidth > 0 && headline.preferredMaxLayoutWidth == subtitle.preferredMaxLayoutWidth,
            "both wrapping fields are pinned to the same text width, so Auto Layout can compute their intrinsic "
                + "height correctly before any constraint from outerStack has resolved -- got headline "
                + "\(headline.preferredMaxLayoutWidth), subtitle \(subtitle.preferredMaxLayoutWidth)"
        )

        print("PASS: the presence prompt's headline has no line cap either, and both wrapping fields share a preferredMaxLayoutWidth")
    }

    do {
        // The text stack must fill the outer stack's own width, so a
        // short headline's text block starts at the same left edge as
        // a long one's -- not narrower, which the outer stack's own
        // trailing alignment then pushes rightward.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let window: NSPanel = field("window", of: controller, as: NSPanel.self)
        guard let contentView = window.contentView,
              let outerStack = contentView.subviews.first as? NSStackView,
              let textStack = outerStack.arrangedSubviews.first as? NSStackView
        else {
            fatalError("expected the presence prompt's content view to hold outerStack, and outerStack's first arranged subview to be textStack")
        }
        contentView.layoutSubtreeIfNeeded()
        let textStackLeading = contentView.convert(textStack.frame.origin, from: outerStack).x
        let outerStackLeading = outerStack.frame.minX
        expect(
            abs(textStackLeading - outerStackLeading) < 0.5,
            "the text stack's leading edge matches the outer stack's own leading edge for a short headline -- "
                + "got text stack at \(textStackLeading), outer stack at \(outerStackLeading)"
        )

        print("PASS: the presence prompt's text stack starts at the outer stack's own leading edge, even with a short headline")
    }

    do {
        // Countdown face: the sans body face at the secondary colour,
        // not the mono face headline and body already avoid here --
        // only the digits themselves earn a tabular figure so the
        // line's width does not jump as they tick over.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let timeoutLine: NSTextField = field("timeoutLine", of: controller, as: NSTextField.self)
        let attributed = timeoutLine.attributedStringValue
        let string = attributed.string as NSString
        let digitRange = string.range(of: "0:30")
        expect(digitRange.location != NSNotFound, "the countdown's own text still reads its start value -- got: \(attributed.string)")
        let wordFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        expect(
            wordFont == CanvasDesign.font(.primary, size: 12),
            "the sentence itself is the sans body face, not the mono face headline and body already avoid here -- got \(String(describing: wordFont))"
        )
        let minutesFont = attributed.attribute(.font, at: digitRange.location, effectiveRange: nil) as? NSFont
        expect(
            minutesFont == NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            "the minutes digit carries tabular figures -- got \(String(describing: minutesFont))"
        )
        let secondsFont = attributed.attribute(.font, at: digitRange.location + 2, effectiveRange: nil) as? NSFont
        expect(
            secondsFont == NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            "the seconds digits carry tabular figures too -- got \(String(describing: secondsFont))"
        )
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        expect(
            color == CanvasDesign.muted.nsColor,
            "the countdown stays the secondary colour -- got \(String(describing: color))"
        )

        print("PASS: the presence prompt's countdown reads in the sans body face at the secondary colour, with tabular digits")
    }

    do {
        // Button order: macOS's own permission alerts put the default
        // button at the row's right edge, not the left -- Allow reads
        // first, Don't Allow sits at the edge a person's eye and Return
        // both land on.
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        let allowButton: NSButton = field("allowButton", of: controller, as: NSButton.self)
        let refuseButton: NSButton = field("refuseButton", of: controller, as: NSButton.self)
        let window: NSPanel = field("window", of: controller, as: NSPanel.self)
        guard let contentView = window.contentView,
              let outerStack = contentView.subviews.first as? NSStackView,
              let buttonRow = outerStack.arrangedSubviews.last as? NSStackView
        else {
            fatalError("expected the presence prompt's content view to hold outerStack, and outerStack's last arranged subview to be buttonRow")
        }
        expect(
            buttonRow.arrangedSubviews as? [NSButton] == [allowButton, refuseButton],
            "Allow sits left, Don't Allow sits at the row's right edge -- the same edge macOS's own alerts put their default button at"
        )

        print("PASS: the presence prompt's button row reads Allow then Don't Allow, matching macOS's own alert layout")
    }

    do {
        // The prompt must actually reach the window server, not merely
        // block correctly inside `RunLoopPresenceWaiting.wait` while never
        // appearing anywhere a person could see or click it. `sensoriumd`
        // runs at activation policy `.accessory` and
        // is never made the active app, and an `NSPanel`'s own
        // `hidesOnDeactivate` defaults to `true` -- which hides an
        // inactive app's windows the moment they are ordered front,
        // exactly `HostScreenBadge` already works around. This test
        // never activates this process either, the same as
        // production, and deactivates it first in case an earlier
        // test in this run left it active.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.hide(nil)
        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        waiting.wait(until: Date().addingTimeInterval(0.2)) { false }
        expect(!app.isActive, "this process must be inactive before this test means anything -- production's own accessory app is never active either")

        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display")
        )
        controller.show()
        waiting.wait(until: Date().addingTimeInterval(0.3)) { false }

        let onScreenTitles = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowName as String] as? String }
        controller.hide()

        expect(
            onScreenTitles.contains("Screen Sharing Request"),
            "the presence prompt reaches the window server without this process ever becoming the active app -- "
                + "got on-screen window titles: \(onScreenTitles)"
        )

        print("PASS: the presence prompt reaches the window server while this process stays inactive, matching production")
    }

    do {
        // The collapsed badge pill reaches the real window server at
        // its small size, and its Stop button still exists there and
        // still fires -- the same "on screen while this process stays
        // inactive" proof as the presence prompt above, for the one
        // window this collapse feature is allowed to shrink.
        func findButton(in view: NSView) -> NSButton? {
            for subview in view.subviews {
                if let button = subview as? NSButton { return button }
                if let found = findButton(in: subview) { return found }
            }
            return nil
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.hide(nil)
        let waiting = RunLoopPresenceWaiting(pollInterval: 0.02)
        waiting.wait(until: Date().addingTimeInterval(0.2)) { false }
        expect(!app.isActive, "this process must be inactive before this test means anything -- production's own accessory app is never active either")

        let state = HostScreenBadgeState(
            content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
            startsCollapsed: true
        )
        let controller = HostScreenBadgeWindowController(state: state, restoresPersistedLayout: false)
        controller.show()
        waiting.wait(until: Date().addingTimeInterval(0.3)) { false }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let onScreenBadgeHeights = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ownPID }
            .compactMap { ($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] }

        expect(
            onScreenBadgeHeights.contains { $0 < 40 },
            "the collapsed badge reaches the window server at under 40pt tall -- got this process's own on-screen window heights: \(onScreenBadgeHeights)"
        )

        if let contentView = CanvasHostTestHooks.hostScreenBadgeWindow(controller).contentView,
           let stopButton = findButton(in: contentView) {
            stopButton.performClick(nil)
            expect(state.hasStopped, "the collapsed badge's own Stop button still fires -- collapsing changes its size, not its function")
        } else {
            expect(false, "the collapsed badge has no Stop button to click")
        }

        controller.hide()

        print("PASS: the collapsed badge reaches the window server at under 40pt tall, and its Stop button still exists and fires")
    }
}
