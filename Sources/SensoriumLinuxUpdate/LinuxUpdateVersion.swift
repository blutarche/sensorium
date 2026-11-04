import Foundation

/// A release version, `major.minor.patch`, each part plain decimal digits
/// with no leading zero. Being canonical means two equal versions are always
/// written the same way, so the text can be compared with a file name, a
/// directory name, or what a binary prints as its own version.
public struct LinuxUpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.utf8.count <= 9,
                  piece.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  piece == "0" || piece.first != "0",
                  let value = Int(piece) else {
                return nil
            }
            parts.append(value)
        }
        (major, minor, patch) = (parts[0], parts[1], parts[2])
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: LinuxUpdateVersion, rhs: LinuxUpdateVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension LinuxUpdateVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = LinuxUpdateVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a version"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What a verified manifest means for this viewer.
public enum LinuxUpdateDecision: Equatable, Sendable {
    /// The release page offers a version below one this viewer has already
    /// seen in a valid manifest: a failed check.
    case wentBackwards(highestSeen: LinuxUpdateVersion)
    case upToDate
    case update

    /// The first matching row of the table in section 3.1 of
    /// `docs/self-update-design.md` decides. An offer older than the running
    /// version that is not below the highest seen matches no row, and
    /// installs nothing.
    public static func decide(
        offered: LinuxUpdateVersion,
        running: LinuxUpdateVersion,
        highestSeen: LinuxUpdateVersion?
    ) -> LinuxUpdateDecision {
        if let highestSeen, offered < highestSeen {
            return .wentBackwards(highestSeen: highestSeen)
        }
        if offered > running {
            return .update
        }
        return .upToDate
    }
}
