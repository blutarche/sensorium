#if os(macOS)
import Foundation

/// Whether a failed update says the release itself is bad, or could pass on
/// another try.
public enum UpdateFailureKind: String, Codable, Sendable {
    /// Never tried again for that version with that zip's SHA-256.
    case badRelease
    /// Tried again at the next check, at most three times for that version.
    case couldPassOnAnotherTry
}

/// Why a check stopped or an update did not install.
public enum UpdateFailure: Error, Equatable, Sendable {
    // Check
    case signatureInvalid
    case manifestInvalid
    case wentBackwards(highestSeen: UpdateVersion, offered: UpdateVersion)
    // Download
    case downloadFailed
    case sizeMismatch
    case digestMismatch
    // Stage
    case stagingFailed
    case wrongBundleContents(String)
    case requirementFailed
    case selfTestFailed(status: Int32)
    case selfTestTimedOut
    // Install
    case swapFailed
    case launchFailed
    case readyLate
    case readyMismatch(String)
    case newInstanceDidNotQuit

    public var kind: UpdateFailureKind {
        switch self {
        case .signatureInvalid, .manifestInvalid, .wentBackwards,
             .wrongBundleContents, .requirementFailed, .selfTestFailed:
            .badRelease
        case .downloadFailed, .sizeMismatch, .digestMismatch, .stagingFailed,
             .selfTestTimedOut, .swapFailed, .launchFailed, .readyLate,
             .readyMismatch, .newInstanceDidNotQuit:
            .couldPassOnAnotherTry
        }
    }

    /// The words that finish the *Failed* line: "… could not update:
    /// `<reason>`."
    public var reason: String {
        switch self {
        case .requirementFailed:
            "the new version is not signed like this one"
        case .wentBackwards:
            "the release page offered an older version than one it offered before"
        case .signatureInvalid, .manifestInvalid, .sizeMismatch, .digestMismatch,
             .wrongBundleContents:
            "the download did not match the release"
        case .selfTestFailed:
            "the new version did not start"
        case .downloadFailed, .stagingFailed, .selfTestTimedOut, .swapFailed,
             .launchFailed, .readyLate, .readyMismatch, .newInstanceDidNotQuit:
            "the new version did not start in time"
        }
    }
}
#endif
