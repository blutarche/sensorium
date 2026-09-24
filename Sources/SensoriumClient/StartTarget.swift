import Foundation
import SensoriumCore

/// Which target a saved machine's session should try first, decided once per
/// machine rather than picked again at every launch. `.hostScreenWhenOffered`
/// is the default, and every machine saved before this field existed decodes
/// as it: a machine this host has never offered a screen to still falls back
/// to a session canvas, today's own unchanged behaviour, and one this host
/// has offered a screen to now starts on it directly -- see
/// `resolve(preference:lastTarget:rememberedOffer:)`.
///
/// `.virtualDisplay` and `.hostScreen` also name the one target a session
/// actually reached and showed a picture on -- what `.hostScreenWhenOffered`
/// falls back to when it has no remembered offer of its own, stamped on
/// `SavedHost.lastLiveTarget` the same moment `lastConnectedAt` is. A stored
/// `lastLiveTarget` is never itself `.hostScreenWhenOffered`; nothing here
/// enforces that structurally, since only one write path (a session going
/// live) ever produces one, and it always names the target that session
/// actually reached.
public enum StartTarget: Equatable, Sendable {
    /// The default: start on a host screen this host has offered this
    /// machine, and fall back to a session canvas only for a machine that
    /// has never been offered one -- see
    /// `resolve(preference:lastTarget:rememberedOffer:)`.
    case hostScreenWhenOffered
    case virtualDisplay
    /// `displayIdentity` is `HostScreenListEntry.displayIdentity` -- stable
    /// across offers, unlike a `opaqueToken` -- and `label` is that same
    /// offer's own label, carried along so a saved preference can still be
    /// shown by name before the next connect has offered it again.
    case hostScreen(displayIdentity: String, label: String)
}

/// One host screen a canvas connect most recently offered this machine,
/// remembered per `SavedHost` so `.hostScreenWhenOffered` can connect to it
/// directly next time rather than starting on a canvas and waiting for the
/// same offer to arrive again. Never carries an `opaqueToken`: a token is
/// good for one offer, and this is read back across a relaunch.
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
    /// `preference` is the machine's own saved choice; `lastTarget` is
    /// whatever `.hostScreenWhenOffered` falls back to when it has no
    /// remembered offer, or `nil` for a machine that has never gone live.
    /// `rememberedOffer` is this machine's own `SavedHost.rememberedHostScreenOffer`
    /// -- the most recent canvas connect's own unprompted offer. `.virtualDisplay`
    /// and `.hostScreen` name themselves regardless of either -- a person who
    /// pinned one of those is not asking this machine to remember anything.
    ///
    /// `.hostScreenWhenOffered` connects directly to the screen a session
    /// with this machine last actually reached, if that screen is still
    /// among the ones remembered; otherwise the first screen remembered, in
    /// the host's own offered order; otherwise a session canvas, for a
    /// machine this host has never offered a screen to, or no longer offers
    /// any of what it once did.
    public static func resolve(
        preference: StartTarget,
        lastTarget: StartTarget?,
        rememberedOffer: [RememberedHostScreen] = []
    ) -> SessionTarget {
        switch preference {
        case .virtualDisplay:
            return .sessionCanvas
        case let .hostScreen(displayIdentity, _):
            return .hostScreen(displayIdentity: displayIdentity)
        case .hostScreenWhenOffered:
            if case let .hostScreen(lastIdentity, _) = lastTarget,
               rememberedOffer.contains(where: { $0.displayIdentity == lastIdentity }) {
                return .hostScreen(displayIdentity: lastIdentity)
            }
            guard let first = rememberedOffer.first else {
                return .sessionCanvas
            }
            return .hostScreen(displayIdentity: first.displayIdentity)
        }
    }
}

/// Whether a canvas connect's own unprompted offer, arriving the moment this
/// attempt's `connect()` returns, should switch it to a host screen before it
/// has ever gone live -- docs/host-screen-design.md §5.7's "the moment it
/// arrives" rule. `isDefaultChosen` is true only while the current target is
/// still the default preference's own to adjust: an explicit virtual-display
/// pin or pick, or the default's own earlier refusal fallback, is never
/// second-guessed by an offer that happens to arrive afterwards.
public enum StartTargetAutoSwitch {
    public static func target(
        isDefaultChosen: Bool,
        currentTarget: SessionTarget,
        offer: [HostScreenListEntry]
    ) -> (displayIdentity: String, label: String)? {
        guard isDefaultChosen, currentTarget == .sessionCanvas, let first = offer.first else {
            return nil
        }
        return (first.displayIdentity, first.label)
    }
}

/// Whether a refused host-screen connect should fall back to a session
/// canvas on its own, rather than end the whole run the way a refusal
/// otherwise does -- docs/host-screen-design.md §5.7: a person's own
/// explicit pin or pick is never second-guessed this way, so this is true
/// only for a target the default preference chose, and only before this
/// session has ever shown anything, since ending outright is not a dead end
/// once there is already a picture up.
public enum StartTargetHostScreenRefusalFallback {
    public static func shouldFallBackToVirtualDisplay(isDefaultChosen: Bool, hasBeenLive: Bool) -> Bool {
        isDefaultChosen && !hasBeenLive
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
