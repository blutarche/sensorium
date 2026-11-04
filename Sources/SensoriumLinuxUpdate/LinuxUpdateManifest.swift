import Foundation

public enum LinuxUpdateManifestError: Error, Equatable {
    case notJSON
    case unsupportedFormat
    case invalidVersion
    case invalidFile
    case invalidSize
    case invalidDigest
}

/// `sensorium-update-linux-x86_64.json`: what the latest release offers the
/// Linux viewer. Only ever parsed after its signature has verified.
public struct LinuxUpdateManifest: Equatable, Sendable {
    /// The largest archive any release may name. The viewer binary is a few
    /// tens of megabytes.
    public static let maximumArchiveSize: Int64 = 512 * 1024 * 1024

    public let version: LinuxUpdateVersion
    public let file: String
    public let size: Int64
    /// Lowercase hexadecimal, 64 characters.
    public let sha256: String

    public init(version: LinuxUpdateVersion, file: String, size: Int64, sha256: String) {
        self.version = version
        self.file = file
        self.size = size
        self.sha256 = sha256
    }

    /// The only file name a release may give its archive for `version`.
    public static func archiveFileName(for version: LinuxUpdateVersion) -> String {
        "Sensorium-\(version)-linux-x86_64.tar.gz"
    }

    public static func parse(_ data: Data) throws -> LinuxUpdateManifest {
        // The format is read on its own first, so a later format whose other
        // fields changed shape reads as unsupported rather than malformed.
        guard let format = try? JSONDecoder().decode(Format.self, from: data) else {
            throw LinuxUpdateManifestError.notJSON
        }
        guard format.format == 1 else {
            throw LinuxUpdateManifestError.unsupportedFormat
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw LinuxUpdateManifestError.notJSON
        }
        guard let version = LinuxUpdateVersion(wire.version) else {
            throw LinuxUpdateManifestError.invalidVersion
        }
        guard wire.file == archiveFileName(for: version) else {
            throw LinuxUpdateManifestError.invalidFile
        }
        guard wire.size > 0, wire.size <= maximumArchiveSize else {
            throw LinuxUpdateManifestError.invalidSize
        }
        guard isLowercaseDigest(wire.sha256) else {
            throw LinuxUpdateManifestError.invalidDigest
        }
        return LinuxUpdateManifest(version: version, file: wire.file, size: wire.size, sha256: wire.sha256)
    }

    static func isLowercaseDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    private struct Format: Decodable {
        let format: Int
    }

    private struct Wire: Decodable {
        let version: String
        let file: String
        let size: Int64
        let sha256: String
    }
}
