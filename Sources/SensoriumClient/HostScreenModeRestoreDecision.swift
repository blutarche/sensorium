import Foundation
import SensoriumCore

/// What a remembered resolution should do at the start of a host-screen
/// session, once the host's mode list and current mode are both known.
public enum HostScreenModeRestoreOutcome: Equatable, Sendable {
    /// Send exactly one `hostScreenModeRequest` for `modeID` -- the live
    /// mode ID a fresh offer gave the remembered shape, never a stale one
    /// carried over from a past session.
    case restore(modeID: String, mode: RememberedHostScreenMode)
    /// Nothing was ever remembered for this machine's this screen.
    case noRememberedChoice
    /// A shape was remembered, but this offer's list has no mode of that
    /// shape -- the display itself changed what it can do since.
    case rememberedChoiceUnavailable(mode: RememberedHostScreenMode)
    /// The remembered shape is already what the screen is on; nothing to do.
    case alreadyCurrent(mode: RememberedHostScreenMode)
}

/// The pure decision behind remembering a host screen's chosen resolution:
/// kept out of `ClientSessionHost` so the rule itself is tested
/// without a live connection, the same reasoning `HostScreenResumeTicketRetention`
/// already applies to a different per-session memory.
public enum HostScreenModeRestoreDecision {
    public static func decide(
        remembered: RememberedHostScreenMode?,
        modes: [HostScreenModeEntry],
        currentModeID: String
    ) -> HostScreenModeRestoreOutcome {
        guard let remembered else { return .noRememberedChoice }
        guard let entry = HostScreenModeMatching.entry(for: remembered, in: modes) else {
            return .rememberedChoiceUnavailable(mode: remembered)
        }
        guard entry.modeID != currentModeID else {
            return .alreadyCurrent(mode: remembered)
        }
        return .restore(modeID: entry.modeID, mode: remembered)
    }

    /// The repo's own log style (`"Sensorium: <line>"` is added by the
    /// caller, the same way `ClipboardSyncEngine`'s log lines are). `nil`
    /// for the two outcomes that are not worth a line: nothing was ever
    /// remembered, or the screen is already on the remembered shape.
    public static func logLine(for outcome: HostScreenModeRestoreOutcome) -> String? {
        switch outcome {
        case let .restore(_, mode):
            return "resolution: restoring \(description(of: mode)) chosen last time"
        case let .rememberedChoiceUnavailable(mode):
            return "resolution: \(description(of: mode)) chosen last time is not offered this session"
        case .noRememberedChoice, .alreadyCurrent:
            return nil
        }
    }

    private static func description(of mode: RememberedHostScreenMode) -> String {
        "\(mode.width)x\(mode.height) (\(mode.isHiDPI ? "HiDPI" : "non-HiDPI"))"
    }
}

/// Gates the restore decision to at most one attempt per instance -- design's
/// "never request twice per session automatically." A fresh instance per
/// host-screen session (the same lifetime `ClientSessionHost.runOnce()`'s
/// own per-session state already has) is what makes "per session" true;
/// this type itself only ever counts its own calls.
@MainActor
public final class HostScreenModeAutoRestore {
    private var hasAttempted = false

    public init() {}

    /// `nil` on every call after the first, whatever the first one decided --
    /// a manual pick from the Resolution submenu still works, since that
    /// path never goes through this gate at all.
    public func attempt(
        remembered: RememberedHostScreenMode?,
        modes: [HostScreenModeEntry],
        currentModeID: String
    ) -> HostScreenModeRestoreOutcome? {
        guard !hasAttempted else { return nil }
        hasAttempted = true
        return HostScreenModeRestoreDecision.decide(remembered: remembered, modes: modes, currentModeID: currentModeID)
    }
}

/// The other half of the round trip: what a live `hostScreenModeApplied`
/// should write to memory. Only a mode the host confirms applying is ever
/// worth remembering -- `hostScreenModeList` (unprompted, or in reply to a
/// request that was refused) and `hostScreenModeRefused` never call this at
/// all, which is what keeps a refusal or a plain snapshot from overwriting a
/// choice that never actually took effect.
public enum HostScreenModeMemoryUpdate {
    public static func remembering(
        currentModeID: String, in modes: [HostScreenModeEntry]
    ) -> RememberedHostScreenMode? {
        modes.first { $0.modeID == currentModeID }.map(RememberedHostScreenMode.init)
    }
}
