import AppKit
import Foundation

/// What the host window shows when Sensorium Host cannot read its own key --
/// the host's counterpart to the viewer's `ViewerStartupFailureCopy`, worded
/// for an unattended machine rather than a person sitting at it.
public struct HostIdentityFailureCopy: Equatable, Sendable {
    public let headline: String
    public let detail: String
    /// The first thing to try, and the panel's primary button: read the key
    /// this machine already has again.
    public let retryButtonTitle: String
    public let replaceButtonTitle: String
    public let replaceConsequence: String

    public init(
        headline: String,
        detail: String,
        retryButtonTitle: String,
        replaceButtonTitle: String,
        replaceConsequence: String
    ) {
        self.headline = headline
        self.detail = detail
        self.retryButtonTitle = retryButtonTitle
        self.replaceButtonTitle = replaceButtonTitle
        self.replaceConsequence = replaceConsequence
    }

    /// One failure: the file holding this machine's device or TLS key could
    /// not be read or written. Which one failed does not change the words.
    /// `replaceConsequence`'s last sentence holds because host screen
    /// settings are keyed to a paired machine's own public key, not to this
    /// host's key.
    public static let cannotReadKey = HostIdentityFailureCopy(
        headline: "Sensorium Host could not read its own key.",
        detail: "The file that holds the key identifying this machine could not be read. Trying again reads "
            + "it once more. If that keeps failing, \(HostTextFlow.whole(replaceTitle)) replaces the key, and "
            + "every paired machine must pair again.",
        retryButtonTitle: retryTitle,
        replaceButtonTitle: replaceTitle,
        replaceConsequence: "\(HostTextFlow.whole(replaceTitle)) replaces the key that identifies this machine. "
            + "Paired machines will no longer recognize this machine, so pair each one again. "
            + "Host screen settings are kept."
    )

    private static let retryTitle = "Try Again"
    private static let replaceTitle = "Make a New Key"

    package func makeReplacementConfirmation() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Make a new key?"
        alert.informativeText = replaceConsequence
        alert.addButton(withTitle: replaceButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    package static func replacementFailure(reason: String) -> String {
        "Sensorium Host could not replace this machine\u{2019}s key: \(reason)."
    }
}
