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

    private static let displaysMenuName = ViewerCopyWrapping.control("the Displays menu")
    private static let leadIn = "Could not add another private desktop:"

    /// `hostLabel` defaults to the generic phrase for a caller with no saved
    /// host to name. The line comes back wrapped for a narrow banner: the
    /// host's name and the menu's name are held whole, and the last words
    /// stay together.
    public static func line(reason: String, hostLabel: String = genericHostLabel) -> String {
        let host = hostLabel == genericHostLabel ? hostLabel : ViewerCopyWrapping.name(hostLabel)
        let sentence: String
        switch reason {
        case "host-screen-session-active":
            sentence = "\(leadIn) \(host) is showing this machine a host screen, and a "
                + "host screen allows only one display."
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
                + "does not know:\u{00A0}\(ViewerCopyWrapping.quoted(reason)). Update both apps, then try again."
        }
        return ViewerCopyWrapping.keepingTailTogether(sentence)
    }
}
