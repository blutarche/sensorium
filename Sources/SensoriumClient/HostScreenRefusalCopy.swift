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

    /// Where a person picks a host screen: the Screen menu, in the menu bar
    /// on both platforms.
    public static let screenControlName = "the Screen menu"

    // Nothing below names a specific recovery path -- "connect with a
    // virtual display", say -- since a session canvas is opt-in and off by
    // default (`HostPrivateDesktopSetting`): a machine that refuses a host
    // screen may well refuse a canvas too. Every recovery here happens
    // through whichever button `ViewerSessionStateMachine` actually puts on
    // screen for this refusal, which already reflects what that machine
    // offers -- these lines only ever state the fact.
    public static func line(reason: String) -> String {
        switch reason {
        case noneAvailableReason:
            return "This Mac has no screen available to share right now."
        case "canvas-session-active":
            return "That machine was already showing this machine a virtual display. That session has ended."
        case "host-screen-not-allowed":
            return "Sensorium Host on that machine has host screen turned off for this machine."
        case "host-screen-presence-declined":
            return "The person at that machine chose not to share its screen this time. "
                + "They will be asked again when you connect from Your Machines."
        case "host-screen-presence-unanswered":
            return "No one at that machine answered the request within thirty seconds."
        case "host-screen-presence-check-required":
            return "That machine needed to ask and could not."
        case "host-screen-display-unavailable":
            return "The screen you chose is no longer available there."
        case "host-screen-retry-needs-person":
            // Minted here rather than sent by the host: an automatic redial
            // holding no resume ticket never reaches that machine at all.
            return "The connection dropped, and showing a host screen again needs someone at this machine "
                + "to ask for it."
        case "host-screen-resume-refused":
            return "The connection was interrupted and could not resume."
        case "host-screen-session-active":
            return "That machine was already showing this machine a host screen. That session has ended."
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
            return "That machine still shows an earlier session as live. If another "
                + "window here is showing its screen, use that one. Otherwise it clears within thirty "
                + "seconds \u{2014} connect again from Your Machines then."
        default:
            return "That machine gave a reason this version of Sensorium does not know: "
                + "\u{201C}\(nonBreaking(reason)).\u{201D} Update both apps."
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
            return "\(hostLabel) no longer offers that resolution for its screen. Choose another from "
                + "\(screenControlName)."
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
