#if os(macOS)
import Foundation

/// Which of the two apps is updating. Each reads its own entry of the
/// manifest.
public enum UpdateAppRole: String, Sendable, CaseIterable {
    case viewer
    case host

    /// The release file this app ships in, for `version`.
    public func zipFileName(for version: UpdateVersion) -> String {
        switch self {
        case .viewer: "Sensorium-\(version).zip"
        case .host: "Sensorium-Host-\(version).zip"
        }
    }
}

public enum UpdateManifestError: Error, Equatable {
    case notJSON
    case unsupportedFormat
    case invalidVersion
    case invalidMinimumMacOS
    case invalidApp(UpdateAppRole)
}

/// `sensorium-update.json`: what the latest release offers. Only ever parsed
/// after its signature has verified.
public struct UpdateManifest: Equatable, Sendable {
    public struct App: Equatable, Sendable {
        public let bundleIdentifier: String
        public let file: String
        public let size: Int64
        public let sha256: String
    }

    /// The largest zip any release may name. Both apps are a few megabytes.
    public static let maximumZipSize: Int64 = 512 * 1024 * 1024

    public let version: UpdateVersion
    public let minimumMacOS: UpdateSystemVersion
    public let viewer: App
    public let host: App

    public func app(_ role: UpdateAppRole) -> App {
        switch role {
        case .viewer: viewer
        case .host: host
        }
    }

    public static func parse(_ data: Data) throws -> UpdateManifest {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw UpdateManifestError.notJSON
        }
        guard wire.format == 1 else {
            throw UpdateManifestError.unsupportedFormat
        }
        guard let version = UpdateVersion(wire.version) else {
            throw UpdateManifestError.invalidVersion
        }
        guard let minimum = UpdateSystemVersion(wire.minimumMacOS) else {
            throw UpdateManifestError.invalidMinimumMacOS
        }
        return UpdateManifest(
            version: version,
            minimumMacOS: minimum,
            viewer: try validated(wire.apps.viewer, role: .viewer, version: version),
            host: try validated(wire.apps.host, role: .host, version: version)
        )
    }

    private static func validated(_ app: Wire.App, role: UpdateAppRole, version: UpdateVersion) throws -> App {
        let isDigest = app.sha256.utf8.count == 64 && app.sha256.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
        guard !app.bundleIdentifier.isEmpty,
              app.file == role.zipFileName(for: version),
              app.size > 0, app.size <= maximumZipSize,
              isDigest else {
            throw UpdateManifestError.invalidApp(role)
        }
        return App(bundleIdentifier: app.bundleIdentifier, file: app.file, size: app.size, sha256: app.sha256)
    }

    private struct Wire: Decodable {
        struct App: Decodable {
            let bundleIdentifier: String
            let file: String
            let size: Int64
            let sha256: String
        }
        struct Apps: Decodable {
            let viewer: App
            let host: App
        }
        let format: Int
        let version: String
        let minimumMacOS: String
        let apps: Apps
    }
}
#endif
