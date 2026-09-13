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
    /// `hostLabel` defaults to the generic phrase for a caller with no saved
    /// host to name.
    public static func line(reason: String, hostLabel: String = "the other machine") -> String {
        switch reason {
        case "host-screen-session-active":
            return "Could not add a second display: \(hostLabel) is showing this machine a host screen, and a "
                + "host screen allows only one display."
        case "display-count-exceeds-host-limit":
            return "Could not add a second display: \(hostLabel) allows only one display, and that limit "
                + "cannot be changed from this machine."
        case CanvasRefusalReason.creationInProgress:
            return "Could not add a second display: \(hostLabel) is still setting one up for another "
                + "request. Choose again from the Displays menu in a moment."
        case "display-count-change-failed":
            return "Could not add a second display: \(hostLabel) could not set it up right now. Choose "
                + "again from the Displays menu."
        default:
            return "Could not add a second display: \(hostLabel) gave a reason this version of Sensorium "
                + "does not know: \u{201C}\(nonBreaking(reason)).\u{201D} Update both apps, then try again."
        }
    }

    /// A quoted, unrecognised wire token wraps like any other text; without
    /// this, the wrap can land inside the token's own hyphens and split the
    /// closing quote mark onto the line after it.
    private static func nonBreaking(_ token: String) -> String {
        token.replacingOccurrences(of: "-", with: "\u{2011}")
    }
}
