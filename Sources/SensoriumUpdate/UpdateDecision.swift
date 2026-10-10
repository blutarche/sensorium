#if os(macOS)
import Foundation

/// What a verified manifest means for this app.
public enum UpdateDecision: Equatable, Sendable {
    /// The release page offers a version below one this app has already
    /// seen in a valid manifest: a failed check.
    case wentBackwards(highestSeen: UpdateVersion)
    case upToDate
    case update
    /// The release needs a newer macOS than this Mac runs. Nothing to do.
    case requiresNewerMacOS

    /// The first matching row of the table in section 3.1 of
    /// `docs/self-update-design.md` decides. An offer older than the running
    /// version that is not below the highest seen matches no row, and
    /// installs nothing.
    public static func decide(
        offered: UpdateVersion,
        minimumMacOS: UpdateSystemVersion,
        running: UpdateVersion,
        highestSeen: UpdateVersion?,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> UpdateDecision {
        guard minimumMacOS.isSatisfied(by: system) else {
            return .requiresNewerMacOS
        }
        if let highestSeen, offered < highestSeen {
            return .wentBackwards(highestSeen: highestSeen)
        }
        if offered > running {
            return .update
        }
        return .upToDate
    }
}
#endif
