import Foundation
import SensoriumCore

/// What a `hostScreenRequest`'s refusal says, in plain words -- design
/// §6.3's own discipline: a failed check ends the whole session, and the
/// reason it ended is said, not logged. Named reasons only; an unknown one
/// is quoted rather than translated, the same discipline
/// `DisplayCountRefusalCopy` already follows for the Displays menu's own
/// refusals -- inventing a cause for a token this build has never seen
/// would be a guess dressed as an explanation.
///
/// Every line is read under a headline that already names the host, so
/// none names it again: "that machine" is the subject throughout.
public enum HostScreenRefusalCopy {
    /// Minted here rather than sent by the host: the host's offer held no
    /// screen, and a session never falls back to a canvas on its own.
    public static let noneAvailableReason = "host-screen-none-available"

    public static func line(reason: String) -> String {
        switch reason {
        case noneAvailableReason:
            return "This Mac has no screen available to share right now."
        case "canvas-session-active":
            return "That machine was already showing this machine a virtual display. That session has ended. "
                + "Connect with a virtual display, then choose a host screen from the Screen menu."
        case "host-screen-not-allowed":
            return "Sensorium Host on that machine has host screen turned off for this machine."
        case "host-screen-presence-declined":
            return "The person at that machine chose not to share its screen this time. Connect with a "
                + "virtual display, then choose a host screen from the Screen menu \u{2014} they will be "
                + "asked again."
        case "host-screen-presence-unanswered":
            return "No one at that machine answered the request within thirty seconds. Connect with a "
                + "virtual display, then choose a host screen from the Screen menu to ask again."
        case "host-screen-presence-check-required":
            return "That machine needed to ask and could not. Connect with a virtual "
                + "display, then choose a host screen from the Screen menu to try again."
        case "host-screen-display-unavailable":
            return "The screen you chose is no longer available there. Connect with a virtual display, "
                + "then choose another host screen from the Screen menu."
        case "host-screen-retry-needs-person":
            // Minted here rather than sent by the host: an automatic redial
            // holding no resume ticket never reaches that machine at all.
            return "The connection dropped, and showing a host screen again needs someone at this machine "
                + "to ask for it. Connect with a virtual display, then choose a host screen from the Screen menu."
        case "host-screen-resume-refused":
            return "The connection was interrupted and could not resume. Connect with a virtual display, "
                + "then choose a host screen from the Screen menu."
        case "host-screen-session-active":
            return "That machine was already showing this machine a host screen. That session has ended. "
                + "Connect with a virtual display, then choose a host screen from the Screen menu."
        case "host-screen-already-live":
            return "That machine still counts a host-screen session from this machine as live. If another "
                + "window here is showing its screen, use that one. Otherwise wait about thirty seconds for "
                + "that machine to notice the old connection is gone, then connect with a virtual display "
                + "and choose the host screen again from the Screen menu."
        default:
            return "That machine gave a reason this version of Sensorium does not know: "
                + "\u{201C}\(nonBreaking(reason)).\u{201D} Update both apps, then connect with a virtual display."
        }
    }

    /// What a refused change of the host screen's own resolution says --
    /// docs/ux-spec.md's rule that a refusal is said in the window in plain
    /// words with its reason. Unlike every line above, this one never ends
    /// a session: it appears as a transient notice over a picture that is
    /// still live, so it names the machine itself rather than relying on a
    /// headline above it.
    public static func modeRefusalLine(reason: String, hostLabel: String = "The other machine") -> String {
        switch reason {
        case HostScreenModeRefusalReason.failed:
            return "\(hostLabel) could not change its screen\u{2019}s resolution. It is back to what it was."
        case HostScreenModeRefusalReason.unknown:
            return "\(hostLabel) no longer offers that resolution for its screen. Choose another from the "
                + "Screen menu."
        case HostScreenModeRefusalReason.notLive:
            return "\(hostLabel) is no longer showing this machine its screen, so its resolution did not change."
        default:
            return "\(hostLabel) would not change its screen\u{2019}s resolution, and gave a reason this version "
                + "of Sensorium does not know: \u{201C}\(nonBreaking(reason)).\u{201D} Update both apps, then try again."
        }
    }

    /// A quoted, unrecognised wire token wraps like any other text; without
    /// this, the wrap can land inside the token's own hyphens and split the
    /// closing quote mark onto the line after it.
    private static func nonBreaking(_ token: String) -> String {
        token.replacingOccurrences(of: "-", with: "\u{2011}")
    }
}
