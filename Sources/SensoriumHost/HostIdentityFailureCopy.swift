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
        headline: "Sensorium Host cannot read its own key",
        detail: "The file that holds the key identifying this Mac could not be read. Click Try again. If that "
            + "keeps failing, make a new key.",
        retryButtonTitle: "Try again",
        replaceButtonTitle: "Make a new key",
        replaceConsequence: "Make a new key replaces the key that identifies this Mac. Paired machines will "
            + "no longer recognize this Mac, so pair each one again. Host screen settings are kept."
    )
}
