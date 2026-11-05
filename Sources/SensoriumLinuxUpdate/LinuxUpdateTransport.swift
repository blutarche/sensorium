import Foundation

/// Every address the updater contacts. Each is a constant or is built from a
/// constant and fields of a verified manifest; the updater never follows an
/// address it was handed whole.
public enum LinuxUpdateReleaseLocation {
    public static let manifestURL = URL(string: "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update-linux-x86_64.json")!
    public static let signatureURL = URL(string: "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update-linux-x86_64.json.sig")!

    /// The cap on the manifest and on its signature.
    public static let maximumSmallFileBytes = 64 * 1024

    /// What a real transport sends as `User-Agent`, and how long it waits
    /// for each request.
    public static let userAgent = "Sensorium-Update/1"
    public static let timeout: TimeInterval = 30

    /// The most a whole transfer may take, redirects and body included, so a
    /// server that keeps sending a few bytes at a time still cannot hold a
    /// check or a download open: one for the manifest or its signature, one
    /// for the archive.
    public static let smallFileDeadline: TimeInterval = 30
    public static let archiveDeadline: TimeInterval = 10 * 60

    /// `LinuxUpdateManifest.parse` has already held `manifest.file` to
    /// exactly `Sensorium-<version>-linux-x86_64.tar.gz`.
    public static func downloadURL(for manifest: LinuxUpdateManifest) -> URL {
        URL(string: "https://github.com/blutarche/sensorium/releases/download/v\(manifest.version)/\(manifest.file)")!
    }
}

public enum LinuxUpdateTransportError: Error, Equatable {
    /// The response ran past the byte cap the caller gave.
    case tooLarge
    case badStatus(Int)
    case failed(String)
}

/// Fetches the release page's files. Behind a protocol so tests use a local
/// fake and make no network request. A real transport sends no cookies,
/// keeps no cache, names itself with `LinuxUpdateReleaseLocation.userAgent`,
/// gives up on a request after `LinuxUpdateReleaseLocation.timeout` and on a
/// whole transfer at `smallFileDeadline` or `archiveDeadline`, and stops
/// reading past the cap rather than after it.
public protocol LinuxUpdateTransport: Sendable {
    /// The whole body of `url`, or `LinuxUpdateTransportError.tooLarge` past
    /// `maximumBytes`.
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data

    /// Writes the body of `url` to a new file at `destination`, or throws
    /// `LinuxUpdateTransportError.tooLarge` past `maximumBytes`.
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws
}
