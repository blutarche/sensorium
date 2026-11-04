import Foundation

/// Whether a failed update says the release itself is bad, or could pass on
/// another try.
public enum LinuxUpdateFailureKind: String, Codable, Sendable {
    /// Never tried again for that version with that archive's SHA-256.
    case badRelease
    /// Tried again at the next check, at most three times for that version.
    case couldPassOnAnotherTry
}

/// Why a check stopped or an update did not install. The kinds follow the
/// table in section 3.6 of `docs/self-update-design.md`.
public enum LinuxUpdateFailure: Error, Equatable, Sendable {
    // Check
    case signatureInvalid
    case manifestInvalid
    case wentBackwards(highestSeen: LinuxUpdateVersion, offered: LinuxUpdateVersion)
    // Download
    case downloadFailed
    case sizeMismatch
    case digestMismatch
    // Stage
    /// The engine could not make or fill its own directories. Says nothing
    /// about the release.
    case stagingFailed
    /// The archive matched the signed manifest but does not hold exactly the
    /// one binary it must, or the binary reports another version.
    case wrongArchiveContents(String)
    case selfTestFailed(status: Int32)
    case selfTestTimedOut
    // Install
    case switchFailed
    case launchFailed
    /// The new version did not confirm that it started: its ready file did
    /// not appear in time, or a launch found a pending switch it never
    /// confirmed.
    case readyLate

    public var kind: LinuxUpdateFailureKind {
        switch self {
        case .signatureInvalid, .manifestInvalid, .wentBackwards, .wrongArchiveContents, .selfTestFailed:
            .badRelease
        case .downloadFailed, .sizeMismatch, .digestMismatch, .stagingFailed, .selfTestTimedOut,
             .switchFailed, .launchFailed, .readyLate:
            .couldPassOnAnotherTry
        }
    }

    /// The words that finish the *Failed* line: "… could not update:
    /// `<reason>`."
    public var reason: String {
        switch self {
        case .wentBackwards:
            "the release page offered an older version than one it offered before"
        case .signatureInvalid, .manifestInvalid, .sizeMismatch, .digestMismatch, .wrongArchiveContents:
            "the download did not match the release"
        case .selfTestFailed:
            "the new version did not start"
        case .downloadFailed, .stagingFailed, .selfTestTimedOut, .switchFailed, .launchFailed, .readyLate:
            "the new version did not start in time"
        }
    }
}
