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
/// Every line is read under a headline that already names the host, so a
/// line names it only where the sentence needs a subject; otherwise "that
/// machine" is it.
public enum HostScreenRefusalCopy {
    /// Minted here rather than sent by the host: the host's offer held no
    /// screen, and a session never falls back to a canvas on its own.
    public static let noneAvailableReason = "host-screen-none-available"

    /// Where a person picks a host screen: the Screen menu, in the menu bar
    /// on both platforms.
    public static let screenControlName = "the Screen menu"

    /// What a line calls the host when its caller has no name for it.
    public static let genericHostLabel = "that machine"

    /// The name of the per-machine switch on the host that allows a host
    /// screen, exactly as Sensorium Host labels it.
    private static let hostScreenSwitchName = "Share host screen"

    // These lines are shown under the status panel whose accent button is
    // Try Again, and again as a row's failure fragment in Your Machines, so
    // the way back is always "trying again": it names what that does and
    // names no button. Another path (Your Machines, the Screen menu) is
    // offered only as the alternative to it.
    //
    // A line never names a specific recovery through a private desktop,
    // since that is opt-in and off by default (`HostPrivateDesktopSetting`):
    // a machine that refuses a host screen may well refuse a private desktop
    // too. `ViewerSessionStateMachine` puts that button on screen only when
    // the machine offers it.
    /// `hostLabel` is the host's name as the person gave it, used only where
    /// a sentence needs a subject; leave it out where the caller has none.
    public static func line(reason: String, hostLabel: String = genericHostLabel) -> String {
        let isGeneric = hostLabel == genericHostLabel
        let host = isGeneric ? hostLabel : ViewerCopyWrapping.name(hostLabel)
        let subject = isGeneric ? "That machine" : host
        switch reason {
        case noneAvailableReason:
            return "The host has no screen available to share right now."
        case "canvas-session-active":
            return "An earlier private desktop session was still active. It has now ended. "
                + "Trying again asks for the host screen once more."
        case "host-screen-not-allowed":
            return "\(subject) has \u{201C}\(ViewerCopyWrapping.control(hostScreenSwitchName))\u{201D} turned off for "
                + "this machine. Someone there can turn it on. Trying again then asks for its screen."
        case "host-screen-presence-declined":
            return "The person at \(host) chose not to share its screen this time. "
                + "Trying again asks them again."
        case "host-screen-presence-unanswered":
            return "No one at \(host) answered the request within thirty seconds."
        case "host-screen-presence-check-required":
            return "Sensorium Host could not ask for permission to share the screen. Quit and reopen "
                + "Sensorium Host there, then try again."
        case "host-screen-display-unavailable":
            return "The screen you chose is no longer available. Trying again asks for it once more, or "
                + "choose an available screen from \(ViewerCopyWrapping.control("Your Machines"))."
        case "host-screen-retry-needs-person":
            // Minted here rather than sent by the host: an automatic redial
            // after a request was sent, holding no resume ticket, never
            // reaches that machine at all.
            return "The connection dropped before the screen came up. Trying again requests the screen once more."
        case "host-screen-resume-refused":
            // The host ended or never knew the session this resume named: a
            // Stop at the host, a restart, or a changed arming record. The
            // viewer does not start a new session for it.
            return "The connection was interrupted and could not resume."
        case "host-screen-resume-expired":
            // An expired resume starts a fresh session by itself, so this
            // line is shown only when that fresh attempt is itself answered
            // this way, or by a viewer that does not start one.
            return "The connection was away too long to resume."
        case "host-screen-session-active":
            return "An earlier host-screen session was still active. It has now ended. "
                + "Trying again asks for the host screen once more."
        case "host-screen-already-live":
            // "Another window here" is a real cause, not a hypothetical one:
            // `HostScreenLiveSessionRegistry.admit` keys its one-live-session
            // claim on the device's public key alone, so a second window or
            // launch under the same paired identity trips this exactly as a
            // genuinely stale entry does. Thirty seconds matches the
            // viewer's own `ClientControlDialing.defaultHostSilenceTimeout`,
            // which redials by then, and the host's own, shorter
            // `HostNetworkSession.defaultViewerSilenceTimeout` has already
            // freed the slot before that redial lands.
            return "\(subject) still shows an earlier session as live. If another "
                + "window here is showing its screen, use that one. Otherwise it clears within thirty "
                + "seconds, and trying again then asks for the screen."
        default:
            return "\(subject) gave a reason this version of Sensorium does not know:\u{00A0}"
                + "\(ViewerCopyWrapping.quoted(reason)). Update both apps, then try again."
        }
    }

    /// What a refused change of the host screen's own resolution says --
    /// docs/ux-spec.md's rule that a refusal is said in the window in plain
    /// words with its reason. Unlike every line above, this one never ends
    /// a session: it appears as a transient notice over a picture that is
    /// still live, so it names the machine itself rather than relying on a
    /// headline above it.
    public static func modeRefusalLine(reason: String, hostLabel: String = "The other machine") -> String {
        let host = ViewerCopyWrapping.name(hostLabel)
        let line: String
        switch reason {
        case HostScreenModeRefusalReason.failed:
            line = "\(host) could not change its screen\u{2019}s resolution. It is back to what it was."
        case HostScreenModeRefusalReason.unknown:
            line = "\(host) no longer offers that resolution for its screen. Choose another from "
                + "\(ViewerCopyWrapping.control(screenControlName))."
        case HostScreenModeRefusalReason.notLive:
            line = "\(host) is no longer showing this machine its screen, so its resolution did not change."
        default:
            line = "\(host) would not change its screen\u{2019}s resolution, and gave a reason this version "
                + "of Sensorium does not know:\u{00A0}\(ViewerCopyWrapping.quoted(reason)). "
                + "Update both apps, then try again."
        }
        return ViewerCopyWrapping.keepingTailTogether(line)
    }
}
