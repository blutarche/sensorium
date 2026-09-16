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
    public static func line(reason: String) -> String {
        switch reason {
        case "canvas-session-active":
            return "That machine was already showing this machine a virtual display. That session has ended. "
                + "Connect with a virtual display, then choose a host screen from the Screen menu."
        case "host-screen-not-allowed":
            return "Sensorium Host on that Mac has host screen turned off for this machine."
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
        case "host-screen-needs-rearming":
            return "That machine needs \u{201C}Share host screen\u{201D} for this machine turned off and back on. "
                + "Do that in Sensorium Host there."
        case "host-screen-credential-unknown":
            return "That machine does not have this machine's current presence key. Pair with that machine again "
                + "to register it, then try the host screen again."
        case "host-screen-display-unavailable":
            return "The screen you chose is no longer available there. Connect with a virtual display, "
                + "then choose another host screen from the Screen menu."
        case "host-screen-retry-needs-person":
            return "The connection dropped. Showing a host screen again needs a fresh confirmation on "
                + "this machine. Connect with a virtual display, then choose a host screen from the Screen menu."
        case "host-screen-resume-refused":
            return "The connection was interrupted and could not resume. Connect with a virtual display, "
                + "then choose a host screen from the Screen menu."
        case "host-screen-session-active":
            return "That machine was already showing this machine a host screen. That session has ended. "
                + "Connect with a virtual display, then choose a host screen from the Screen menu."
        case "host-screen-already-live":
            return "This machine is already showing that machine\u{2019}s screen in another window. Use that "
                + "window, or close it and choose the host screen again from the Screen menu."
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

    /// True only for the one reason a virtual display cannot fix on its
    /// own: this machine's presence credential is no longer recognised, and
    /// only the pairing ceremony can register a new one. A machine that has
    /// registered a credential the host simply has not snapshotted the
    /// strength of yet (`host-screen-needs-rearming`) is fixed on the
    /// host's own side, never by pairing again.
    public static func offersPairAgain(reason: String) -> Bool {
        reason == "host-screen-credential-unknown"
    }
}
