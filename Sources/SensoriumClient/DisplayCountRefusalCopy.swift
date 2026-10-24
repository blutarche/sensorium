import Foundation
import SensoriumCore

/// What the Displays menu's own refusal says, in plain words -- design:
/// docs/ux-spec.md's "a refusal must be said in the window in plain words
/// with its reason." Named reasons only; an unknown one is quoted rather
/// than translated, the same discipline
/// `ViewerSessionFailureCopy.canvasRefusalLine` already follows for the
/// primary canvas's own refusals -- inventing a cause for a token this
/// build has never seen would be a guess dressed as an explanation.
public enum DisplayCountRefusalCopy {
    /// What a line calls the host when its caller has no saved host to name.
    public static let genericHostLabel = "the other machine"

    /// The article stays loose: it may end a line, where binding it to the
    /// menu's name would push the whole phrase down and leave the line short.
    private static let displaysMenuName = "the " + ViewerCopyWrapping.control("Displays menu")
    private static let leadIn = "Could not add another private desktop:"

    /// `hostLabel` defaults to the generic phrase for a caller with no saved
    /// host to name. The line comes back wrapped for a narrow banner: the
    /// host's name and the menu's name are held whole, and the last two words
    /// stay together.
    public static func line(reason: String, hostLabel: String = genericHostLabel) -> String {
        let host = hostLabel == genericHostLabel ? hostLabel : ViewerCopyWrapping.name(hostLabel)
        let sentence: String
        switch reason {
        case "host-screen-session-active":
            // No private desktop exists during a host-screen session, so this
            // is the one refusal that cannot say "another".
            sentence = "Could not add a private desktop: a host-screen session with \(host) "
                + "shows only that screen."
        case "display-count-exceeds-host-limit":
            sentence = "\(leadIn) \(host) allows only one display, and that limit "
                + "cannot be changed from this machine."
        case CanvasRefusalReason.creationInProgress:
            sentence = "\(leadIn) \(host) is still setting one up for another "
                + "request. Choose again from \(displaysMenuName) in a moment."
        case "display-count-change-failed":
            sentence = "\(leadIn) \(host) could not set it up right now. Choose "
                + "again from \(displaysMenuName)."
        default:
            // The closing quote and the stop after it ride with the token, so
            // neither can begin a line.
            sentence = "\(leadIn) \(host) gave a reason this version of Sensorium "
                + "does not know: \(ViewerCopyWrapping.quoted(reason)). Update both apps, then try again."
        }
        return ViewerCopyWrapping.keepingLastTwoWordsTogether(sentence)
    }
}
