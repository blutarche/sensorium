#if os(macOS)
import Foundation

/// A release version, `major.minor.patch`, each part plain decimal digits
/// with no leading zero. Being canonical means two equal versions are always
/// written the same way, so the text can be compared with a file name or an
/// app's `CFBundleShortVersionString`.
public struct UpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ text: String) {
        guard let parts = Self.numericParts(text), parts.count == 3 else {
            return nil
        }
        (major, minor, patch) = (parts[0], parts[1], parts[2])
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    fileprivate static func numericParts(_ text: String) -> [Int]? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.count <= 9,
                  piece.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  piece == "0" || piece.first != "0",
                  let value = Int(piece) else {
                return nil
            }
            parts.append(value)
        }
        return parts
    }
}

/// The oldest macOS a release runs on, written with two or three parts, as
/// `LSMinimumSystemVersion` is.
public struct UpdateSystemVersion: Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        (self.major, self.minor, self.patch) = (major, minor, patch)
    }

    public init?(_ text: String) {
        guard let parts = UpdateVersion.numericParts(text), (2...3).contains(parts.count) else {
            return nil
        }
        self.init(major: parts[0], minor: parts[1], patch: parts.count == 3 ? parts[2] : 0)
    }

    public func isSatisfied(by running: OperatingSystemVersion) -> Bool {
        (running.majorVersion, running.minorVersion, running.patchVersion) >= (major, minor, patch)
    }
}
#endif
