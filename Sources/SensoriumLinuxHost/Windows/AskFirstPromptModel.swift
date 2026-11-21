#if os(Linux)
import Foundation
import SensoriumCore

/// What the ask-first prompt names: the device that wants the screen and the
/// display it would see.
public struct AskFirstPromptContent: Equatable, Sendable {
    public var deviceName: String
    public var displayLabel: String

    public init(deviceName: String, displayLabel: String) {
        self.deviceName = deviceName
        self.displayLabel = displayLabel
    }
}

/// How an ask-first prompt ended.
public enum AskFirstOutcome: Equatable, Sendable {
    case allowed
    /// The person chose Don't Allow.
    case denied
    /// Nobody answered in time. Counts as a refusal.
    case timedOut

    public var allows: Bool { self == .allowed }
}

/// The ask-first prompt's words and its wait, without a window. One instance
/// answers one question: it reports exactly one outcome, the first of an
/// answer or the timeout.
///
/// The wait follows the macOS host's rule. The timeout is checked before the
/// answer, so an Allow that arrives after the window closed is refused;
/// exactly at the limit is still open.
public final class AskFirstPromptModel {
    /// The shared duration, so this prompt and the viewer's own wait for it
    /// cannot drift apart.
    public static let defaultTimeout = SessionTimeouts.hostScreenPresencePromptTimeout

    public let windowTitle = "Allow Seeing and Controlling This Screen?"
    /// Names the app asking, since the prompt appears over whatever the person
    /// was doing. Drawn in capitals by the window.
    public let eyebrow = "Sensorium Host \u{00B7} Host Screen Request"
    public let headline: String
    public let subtitle: String
    public let allowTitle = "Allow"
    public let denyTitle = "Don\u{2019}t Allow"

    public private(set) var outcome: AskFirstOutcome?

    private let timeout: TimeInterval
    private let now: () -> Date
    private let askedAt: Date
    private let onOutcome: (AskFirstOutcome) -> Void

    public init(
        content: AskFirstPromptContent,
        timeout: TimeInterval = AskFirstPromptModel.defaultTimeout,
        now: @escaping () -> Date = { Date() },
        onOutcome: @escaping (AskFirstOutcome) -> Void
    ) {
        self.timeout = timeout
        self.now = now
        self.askedAt = now()
        self.onOutcome = onOutcome
        headline = "\(content.deviceName) wants to see and control a display of this machine."
        subtitle = "If you allow, \(content.deviceName) sees and controls \(content.displayLabel) "
            + "until you click Stop on the badge that stays on screen, or it disconnects. "
            + "You\u{2019}re asked because this machine was used in the last few minutes."
    }

    /// The line under the text, counting down to the automatic refusal.
    public var countdownLine: String {
        let remaining = max(0, askedAt.addingTimeInterval(timeout).timeIntervalSince(now()))
        let whole = Int(remaining.rounded())
        return "Don\u{2019}t Allow will be chosen automatically in \(whole / 60):\(String(format: "%02d", whole % 60))."
    }

    public func allow() { resolve(.allowed) }

    public func deny() { resolve(.denied) }

    /// Called as time passes. Resolves to a timeout once the window has closed.
    public func tick() { resolve(nil) }

    private func resolve(_ answer: AskFirstOutcome?) {
        guard outcome == nil else { return }
        let elapsed = now().timeIntervalSince(askedAt)
        let result: AskFirstOutcome
        if elapsed > timeout {
            result = .timedOut
        } else if let answer {
            result = answer
        } else {
            return
        }
        outcome = result
        onOutcome(result)
    }
}
#endif
