import Foundation
import SensoriumCore

/// Which target a saved machine's session should try first, decided once per
/// machine rather than picked again at every launch. `.hostScreenWhenOffered`
/// is the default, and every machine saved before this field existed decodes
/// as it: the session starts on a screen the host offers on that same
/// connection, and never on a session canvas by itself -- see
/// `StartTargetResolution.resolve(preference:lastTarget:)`.
///
/// `.virtualDisplay` and `.hostScreen` also name the one target a session
/// actually reached and showed a picture on -- which screen
/// `.hostScreenWhenOffered` prefers when the host still offers it, stamped on
/// `SavedHost.lastLiveTarget` the same moment `lastConnectedAt` is. A stored
/// `lastLiveTarget` is never itself `.hostScreenWhenOffered`; nothing here
/// enforces that structurally, since only one write path (a session going
/// live) ever produces one, and it always names the target that session
/// actually reached.
public enum StartTarget: Equatable, Sendable {
    /// The default: start on a host screen the host offers this machine.
    /// A session canvas is only ever a person's own pick.
    case hostScreenWhenOffered
    case virtualDisplay
    /// `displayIdentity` is `HostScreenListEntry.displayIdentity` -- stable
    /// across offers, unlike a `opaqueToken` -- and `label` is that same
    /// offer's own label, carried along so a saved preference can still be
    /// shown by name before the next connect has offered it again.
    case hostScreen(displayIdentity: String, label: String)
}

/// One host screen a connect most recently offered this machine, remembered
/// per `SavedHost` so the Screen menu can name it before the next offer
/// arrives. Never carries an `opaqueToken`: a token is good for one offer,
/// and this is read back across a relaunch.
public struct RememberedHostScreen: Equatable, Sendable, Codable {
    public let displayIdentity: String
    public let label: String

    public init(displayIdentity: String, label: String) {
        self.displayIdentity = displayIdentity
        self.label = label
    }
}

/// Resolves a saved preference into what the next connect actually names,
/// pure so `ClientSessionHost` (which these runners cannot name -- it is
/// internal) reads it from something that can be.
public enum StartTargetResolution {
    /// `preference` is the machine's own saved choice; `lastTarget` is the
    /// target a session with this machine last actually reached, or `nil`
    /// for a machine that has never gone live. `.virtualDisplay` and
    /// `.hostScreen` name themselves regardless -- a person who pinned one
    /// of those is not asking this machine to remember anything.
    ///
    /// `.hostScreenWhenOffered` starts on a screen from the host's fresh
    /// offer, preferring the one this machine last reached. A last-live
    /// session canvas is not a preference: it resolves as if nothing were
    /// remembered.
    public static func resolve(preference: StartTarget, lastTarget: StartTarget?) -> SessionTarget {
        switch preference {
        case .virtualDisplay:
            return .sessionCanvas
        case let .hostScreen(displayIdentity, _):
            return .hostScreen(displayIdentity: displayIdentity)
        case .hostScreenWhenOffered:
            guard case let .hostScreen(lastIdentity, _) = lastTarget else {
                return .offeredHostScreen(preferredDisplayIdentity: nil)
            }
            return .offeredHostScreen(preferredDisplayIdentity: lastIdentity)
        }
    }
}

/// Local persistence only (`SavedHost`), the same posture
/// `StreamScalePreference`'s own `Codable` extension takes and for the same
/// reason: this format only ever has to read back what this same build
/// wrote, and is free to diverge from the wire's.
extension StartTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case displayIdentity
        case label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        // The wire string is unchanged from before this case was renamed:
        // every machine saved by an older build wrote "lastUsed", and it
        // must still decode as today's default.
        case "lastUsed":
            self = .hostScreenWhenOffered
        case "virtualDisplay":
            self = .virtualDisplay
        case "hostScreen":
            self = .hostScreen(
                displayIdentity: try container.decode(String.self, forKey: .displayIdentity),
                label: try container.decode(String.self, forKey: .label)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unrecognized StartTarget kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostScreenWhenOffered:
            try container.encode("lastUsed", forKey: .kind)
        case .virtualDisplay:
            try container.encode("virtualDisplay", forKey: .kind)
        case let .hostScreen(displayIdentity, label):
            try container.encode("hostScreen", forKey: .kind)
            try container.encode(displayIdentity, forKey: .displayIdentity)
            try container.encode(label, forKey: .label)
        }
    }
}
