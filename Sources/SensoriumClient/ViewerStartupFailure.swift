import Foundation

/// Why the viewer cannot even start: the key that identifies this machine could
/// not be read. Named for what the person has to do about it, not for the
/// loader's internal state.
public enum ViewerIdentityFailure: Error, Equatable, Sendable {
    case unreadable(reason: String)
}

/// What a window says when the app cannot start. AppKit-free, like every other
/// decision about wording in this target.
///
/// The failure is recoverable without sending anyone to a command line:
/// reading the key again, or generating a fresh one, is the whole remedy, so
/// `retryButtonTitle`/`replaceButtonTitle`/`replaceConsequence` are never
/// `nil`.
/// Kept apart from `detail`, which only ever describes the problem: a
/// caller printing this to a terminal (the `pair` verb's own CLI path,
/// scaffolding with no button to tap) has no reason to also print a
/// sentence about tapping one.
public struct ViewerStartupFailureCopy: Equatable, Sendable {
    public let headline: String
    public let detail: String
    /// The first thing to try: repeat the read that just failed. Reached
    /// this screen only after that read already ran once, at launch or at
    /// the last "Try again," so tapping it again costs nothing a person has
    /// not already waited out.
    public let retryButtonTitle: String
    public let replaceButtonTitle: String
    /// Said once, before the button that acts on it exists to be tapped:
    /// whichever way this failed, tapping it means the same thing.
    public let replaceConsequence: String

    public init(
        headline: String,
        detail: String,
        retryButtonTitle: String = "Try again",
        replaceButtonTitle: String,
        replaceConsequence: String
    ) {
        self.headline = headline
        self.detail = detail
        self.retryButtonTitle = retryButtonTitle
        self.replaceButtonTitle = replaceButtonTitle
        self.replaceConsequence = replaceConsequence
    }

    public static func copy(for failure: ViewerIdentityFailure) -> ViewerStartupFailureCopy {
        switch failure {
        case let .unreadable(reason):
            return ViewerStartupFailureCopy(
                headline: "Sensorium could not read this machine\u{2019}s key.",
                detail: "\(reason). Without it there is nothing to prove which machine this is, so no "
                    + "session can start.",
                replaceButtonTitle: "Make a new key",
                replaceConsequence: "Make a new key replaces the key that identifies this Mac. The host will "
                    + "then ask for a pairing code again."
            )
        }
    }
}
