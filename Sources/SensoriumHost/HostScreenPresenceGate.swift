import Foundation

/// What `HostSessionController` calls once the presence rule has answered
/// `.mustAsk`: from there, the answer of the person at this machine is the
/// one thing standing between the request and an outright refusal.
///
/// A protocol, not `HostScreenPresenceGate` directly, so a test can inject a
/// double that skips the real one's exclusivity bookkeeping entirely.
@MainActor
public protocol HostScreenPresenceGating {
    /// Shows the prompt naming `content`'s device and display, and blocks
    /// until a person answers or the thirty-second window closes,
    /// whichever comes first.
    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome
}

/// What a concrete prompt must supply: show something naming `content`,
/// block until Allow, Refuse, or the thirty-second window closes, and
/// report which. `nil` means the window closed with neither button pressed
/// -- the only way that can happen, since the real prompt (like the badge,
/// `HostScreenBadge.swift`) offers no native close control of its own, so
/// its own thirty-second timer is what closed it.
@MainActor
public protocol HostScreenPresencePrompting {
    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceRule.Answer?
}

/// The real, testable half of the flow: never more than one prompt showing
/// at a time, one machine, one person to ask, plus the `Answer?` to outcome
/// mapping, reusing `HostScreenPresenceRule.decide`. `prompting` shows the
/// window, injected so this type is testable without AppKit.
@MainActor
public final class HostScreenPresenceGate: HostScreenPresenceGating {
    private let prompting: any HostScreenPresencePrompting

    /// `true` for exactly as long as one call to `ask` is inside
    /// `prompting.ask`. A second call arriving while it is still up
    /// refuses immediately rather than opening a second window a person
    /// standing at one machine could never answer both of at once -- this can
    /// genuinely happen despite `HostSessionController` being `@MainActor`:
    /// `prompting.ask` blocks by pumping a nested run loop, which can
    /// dispatch another connection's already-queued `@MainActor` work
    /// before this call returns.
    public private(set) var isPromptShowing = false

    public init(prompting: any HostScreenPresencePrompting) {
        self.prompting = prompting
    }

    public func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome {
        guard !isPromptShowing else {
            return .refused(reason: Self.alreadyAskingReason)
        }
        isPromptShowing = true
        defer { isPromptShowing = false }
        guard let answer = prompting.ask(content: content) else {
            // `elapsedSinceAsked > promptTimeout` always refuses, so this
            // can never read the force-unwrap as a crash.
            return HostScreenPresenceRule.decide(
                answer: nil,
                elapsedSinceAsked: HostScreenPresenceRule.promptTimeout + 1
            )!
        }
        // `decide` always settles once `answer` is non-nil and
        // `elapsedSinceAsked` is within `promptTimeout`.
        return HostScreenPresenceRule.decide(answer: answer, elapsedSinceAsked: 0)!
    }

    /// Mapped by `HostSessionController` to
    /// `host-screen-presence-check-required`; kept distinct so the return
    /// value still says why.
    public static let alreadyAskingReason = "another host-screen presence prompt is already showing"
}
