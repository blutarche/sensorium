import AppKit
import Foundation

/// A prompt styled like a system alert, naming the device and display,
/// Allow and Refuse, for the person physically at this machine. Content is
/// fixed at construction, like `HostScreenBadgeWindowController`'s own
/// `state`: one instance answers one question.
///
/// Deliberately not a literal `NSAlert` -- `Scripts/render-ui-previews.swift`
/// needs to render this the same offscreen way it already renders the badge
/// (`cacheDisplay` on a constructed-but-never-shown content view), and an
/// `NSAlert`'s own view hierarchy is not reliably built before its modal
/// session actually runs. `HostScreenPresencePanel` supplies the wait
/// strategy; this type only ever builds and shows a window.
@MainActor
public final class HostScreenPresencePromptWindowController: NSObject {
    /// Not `private`: `HostScreenPresencePanel`, the only other type that
    /// needs the real `NSWindow` to show and hide it, lives in this same
    /// module.
    let window: NSPanel
    private let eyebrow = NSTextField(labelWithString: "")
    private let headline = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let timeoutLine = NSTextField(labelWithString: "")
    private let allowButton = NSButton()
    private let refuseButton = NSButton()
    private var onAllow: (() -> Void)?
    private var onRefuse: (() -> Void)?
    /// Fixed at construction: this prompt's thirty-second deadline.
    private let deadline: Date
    private var countdownTimer: Timer?

    /// An alert-styled panel is a fixed size by design, not a shape a long
    /// device name or display label gets to renegotiate. Without a width
    /// constraint on `outerStack`, Auto Layout has nothing pinning the
    /// window's own width, and it grows to whatever `headline`/`subtitle`'s
    /// unwrapped intrinsic width asks for instead of wrapping within this
    /// one, sized only by height.
    private static let panelWidth: CGFloat = 360

    public init(content: HostScreenBadgeContent) {
        deadline = Date().addingTimeInterval(HostScreenPresenceRule.promptTimeout)
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 208),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Screen Sharing Request"
        // A genuine question, not a passive status indicator like the
        // badge: above every ordinary window, including a full-screen one,
        // so it cannot go unseen behind whatever the person at this machine
        // was already doing.
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.backgroundColor = CanvasDesign.chromeBg.nsColor
        // `sensoriumd` runs at activation policy `.accessory` and is never
        // made the active app -- an ordinary panel's `hidesOnDeactivate`
        // defaults to `true`, which hides it from the window server the
        // moment it is ordered front while an inactive app owns it, so a
        // person at this machine would never see it at all. `HostScreenBadge`
        // does the same.
        // `.nonactivatingPanel` lets Allow and Don't Allow still take
        // keyboard clicks and Don't Allow's own Return key equivalent
        // without activating this app, so a click on either button never
        // steals the keyboard focus the person at this machine already had.
        window.hidesOnDeactivate = false

        buildContent(content: content)
    }

    /// Centered on `NSScreen.main`, never the target display.
    public func show() {
        if let screen = NSScreen.main {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: screen.frame.midX - frame.width / 2,
                y: screen.frame.midY - frame.height / 2
            ))
        }
        window.makeKeyAndOrderFront(nil)
        startCountdownTimer()
    }

    public func hide() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        window.orderOut(nil)
    }

    private func startCountdownTimer() {
        guard countdownTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCountdown()
            }
        }
        // `.common`, so the countdown keeps moving while the person reads
        // the panel -- the same mode `HostMenuBarPresence`'s own pairing
        // countdown ticker uses, for the same reason.
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func updateCountdown() {
        timeoutLine.attributedStringValue = CanvasDesign.textWithTabularDigits(
            HostScreenPresenceRule.countdownLabel(remainingSeconds: deadline.timeIntervalSinceNow),
            size: 12,
            color: CanvasDesign.muted
        )
    }

    /// Set by `HostScreenPresencePanel` before `show()`.
    public func onAnswer(allow: @escaping () -> Void, refuse: @escaping () -> Void) {
        onAllow = allow
        onRefuse = refuse
    }

    private func buildContent(content: HostScreenBadgeContent) {
        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = CanvasDesign.chromeBg.cgColor

        let inset = CanvasDesign.Space.lg
        let textWidth = Self.panelWidth - inset * 2

        // Names the app asking, since this panel appears over whatever the
        // person was doing. Not "Screen Sharing Request": macOS has its own
        // Screen Sharing feature, and this prompt is not that.
        eyebrow.attributedStringValue = CanvasDesign.eyebrow("Sensorium Host \u{00B7} Host Screen Request")
        headline.stringValue = "\(content.deviceName) wants to see and control a display of this machine"
        headline.font = CanvasDesign.font(.primary, size: 15, weight: .semibold)
        headline.textColor = CanvasDesign.ink.nsColor
        headline.lineBreakMode = .byWordWrapping
        // No cap, same reason as `subtitle` below.
        headline.maximumNumberOfLines = 0
        headline.preferredMaxLayoutWidth = textWidth
        // In curly quotes: the display label can carry its own commas and
        // parentheses (a Thunderbolt daisy chain's own position note), which
        // would otherwise read as more clauses of this sentence rather than
        // as one name. A word joiner (U+2060) glues the opening quote to the
        // label's first character so word wrap never leaves the quote
        // orphaned at the end of a line.
        subtitle.stringValue = "If you allow, \(content.deviceName) sees and controls "
            + "\u{201C}\u{2060}\(content.displayLabel)\u{201D} until you click Stop on the badge that stays on screen, "
            + "or it disconnects. You\u{2019}re asked because this machine was used in the last few minutes."
        subtitle.font = CanvasDesign.font(.primary, size: 12)
        subtitle.textColor = CanvasDesign.muted.nsColor
        subtitle.lineBreakMode = .byWordWrapping
        // No cap: `maximumNumberOfLines` does not only clip the drawn text --
        // it also caps what this field reports for its own intrinsic height,
        // which is what the window's own Auto Layout-driven auto-grow sizes
        // against. A long display label already pushes this sentence past
        // three lines; capping it would silently drop the trailing clause
        // instead of the window ever asking for the room to show it.
        subtitle.maximumNumberOfLines = 0
        subtitle.preferredMaxLayoutWidth = textWidth

        timeoutLine.lineBreakMode = .byWordWrapping
        timeoutLine.maximumNumberOfLines = 3
        updateCountdown()

        let textStack = NSStackView(views: [eyebrow, headline, subtitle, timeoutLine])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = CanvasDesign.Space.xs
        textStack.translatesAutoresizingMaskIntoConstraints = false

        // Don't Allow is the default, as in macOS's own permission alerts:
        // a failed, cancelled, or unanswered check must refuse. It is the
        // pair's only filled button so nothing competes with it; Allow is
        // plain, with no key equivalent.
        configureFilledButton(refuseButton, title: "Don\u{2019}t Allow", action: #selector(refuseTapped))
        configurePlainButton(allowButton, title: "Allow", action: #selector(allowTapped))

        // Allow left, Don't Allow at the row's right edge -- macOS's own
        // permission alerts put the default button there, not at the left.
        let buttonRow = NSStackView(views: [allowButton, refuseButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = CanvasDesign.Space.sm
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let outerStack = NSStackView(views: [textStack, buttonRow])
        outerStack.orientation = .vertical
        outerStack.alignment = .trailing
        outerStack.spacing = CanvasDesign.Space.lg
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outerStack)

        NSLayoutConstraint.activate([
            outerStack.widthAnchor.constraint(equalToConstant: Self.panelWidth - inset * 2),
            // Without this, textStack's own width is only as wide as its
            // longest arranged subview's fitting size, and outerStack's
            // `.trailing` alignment then pushes a short headline's whole
            // text block rightward instead of pinning it to the same
            // leading edge a long headline's full-width text reaches on
            // its own.
            textStack.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
            outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),
            allowButton.widthAnchor.constraint(equalToConstant: 80),
            allowButton.heightAnchor.constraint(equalToConstant: 28),
            refuseButton.widthAnchor.constraint(equalToConstant: 80),
            refuseButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        window.contentView = contentView
    }

    private func configureFilledButton(_ button: NSButton, title: String, action: Selector) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = CanvasDesign.Radius.tight
        button.layer?.backgroundColor = CanvasDesign.accent.cgColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: CanvasDesign.font(.primary, size: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        button.target = self
        button.action = action
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configurePlainButton(_ button: NSButton, title: String, action: Selector) {
        button.isBordered = true
        button.bezelStyle = .rounded
        button.title = title
        button.font = CanvasDesign.font(.primary, size: 12, weight: .semibold)
        button.target = self
        button.action = action
        button.keyEquivalent = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = CanvasDesign.Radius.tight
        button.layer?.borderWidth = 1
        button.layer?.borderColor = CanvasDesign.line2.cgColor
    }

    @objc private func allowTapped() {
        onAllow?()
    }

    @objc private func refuseTapped() {
        onRefuse?()
    }
}

/// What actually blocks `ask()` until an answer arrives or the thirty-second
/// window closes -- separated from `HostScreenPresencePanel` so the wait
/// strategy itself is testable without ever constructing a window: `wait`
/// takes a plain predicate, nothing about `HostScreenBadgeContent`, AppKit,
/// or any window at all.
@MainActor
public protocol HostScreenPresenceWaiting {
    /// Blocks the caller -- but never application-modally -- until
    /// `isResolved()` returns `true` or `deadline` passes, whichever comes
    /// first, then returns. Every other window on this machine must stay able
    /// to receive its own events throughout.
    func wait(until deadline: Date, isResolved: () -> Bool)
}

/// The real wait: dequeues and dispatches `NSApp`'s own events in `.default`
/// mode -- the same mode ordinary event dispatch already runs in, never a
/// modal session -- in short slices, checking `isResolved` between each.
/// `RunLoop.main.run(mode:before:)` alone only services timers and other run
/// loop sources; it never hands a queued mouse-down to the window it landed
/// on, because that dispatch is `NSApplication`'s job, not the run loop's.
/// `NSApp.modalWindow` stays `nil` throughout, so every other window's own
/// Stop control stays clickable while this waits.
@MainActor
public struct RunLoopPresenceWaiting: HostScreenPresenceWaiting {
    /// Short enough that a click is serviced within a fraction of a
    /// second.
    public static let defaultPollInterval: TimeInterval = 0.05

    private let pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = Self.defaultPollInterval) {
        self.pollInterval = pollInterval
    }

    public func wait(until deadline: Date, isResolved: () -> Bool) {
        let app = NSApplication.shared
        while !isResolved(), Date() < deadline {
            let sliceEnd = min(deadline, Date().addingTimeInterval(pollInterval))
            var dequeuedAnyEvent = false
            while let event = app.nextEvent(matching: .any, until: sliceEnd, inMode: .default, dequeue: true) {
                dequeuedAnyEvent = true
                app.sendEvent(event)
                if isResolved() {
                    break
                }
            }
            app.updateWindows()
            // Guards the case of a mode with no sources to wait on.
            if !dequeuedAnyEvent, Date() < sliceEnd {
                Thread.sleep(until: sliceEnd)
            }
        }
    }
}

/// The one real `HostScreenPresencePrompting`: builds a fresh
/// `HostScreenPresencePromptWindowController` per ask, shows it, and
/// blocks on `waiting` until an answer arrives or
/// `HostScreenPresenceRule.promptTimeout` passes, whichever comes first.
/// Never application-modal: every other window's own Stop control,
/// including a *different* connection's, must stay clickable throughout.
@MainActor
public final class HostScreenPresencePanel: HostScreenPresencePrompting {
    private let waiting: any HostScreenPresenceWaiting

    public init(waiting: any HostScreenPresenceWaiting = RunLoopPresenceWaiting()) {
        self.waiting = waiting
    }

    public func ask(content: HostScreenBadgeContent) -> HostScreenPresenceRule.Answer? {
        let controller = HostScreenPresencePromptWindowController(content: content)
        var answer: HostScreenPresenceRule.Answer?
        controller.onAnswer(
            allow: { answer = .approved },
            refuse: { answer = .declined }
        )
        controller.show()
        waiting.wait(until: Date().addingTimeInterval(HostScreenPresenceRule.promptTimeout)) {
            answer != nil
        }
        controller.hide()
        return answer
    }
}
