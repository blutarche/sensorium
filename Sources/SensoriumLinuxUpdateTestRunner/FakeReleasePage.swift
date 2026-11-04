import Foundation
import SensoriumLinuxUpdate

/// A local stand-in for the GitHub release page: serves whatever bytes a test
/// puts at an address, and records every request. Nothing leaves the process.
final class FakeReleasePage: LinuxUpdateTransport, @unchecked Sendable {
    struct Request: Equatable {
        let url: URL
        let maximumBytes: Int64
    }

    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var failures: [URL: LinuxUpdateTransportError] = [:]
    private var recorded: [Request] = []

    var requests: [Request] {
        lock.withLock { recorded }
    }

    func serve(_ data: Data, at url: URL) {
        lock.withLock { files[url] = data }
    }

    func fail(_ url: URL, with error: LinuxUpdateTransportError = .failed("unreachable")) {
        lock.withLock { failures[url] = error }
    }

    /// Serves `manifest` and its signature, made with `privateKey`, at the
    /// release's fixed addresses.
    func publish(_ manifest: Data, signedWith privateKey: Data) {
        serve(manifest, at: LinuxUpdateReleaseLocation.manifestURL)
        serve(linuxSignatureFile(signing: manifest, with: privateKey), at: LinuxUpdateReleaseLocation.signatureURL)
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        try respond(url, maximumBytes: Int64(maximumBytes))
    }

    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        let data = try respond(url, maximumBytes: maximumBytes)
        guard FileManager.default.createFile(atPath: destination.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw LinuxUpdateTransportError.failed("could not create \(destination.lastPathComponent)")
        }
    }

    private func respond(_ url: URL, maximumBytes: Int64) throws -> Data {
        try lock.withLock {
            recorded.append(Request(url: url, maximumBytes: maximumBytes))
            if let failure = failures[url] {
                throw failure
            }
            guard let data = files[url] else {
                throw LinuxUpdateTransportError.badStatus(404)
            }
            guard Int64(data.count) <= maximumBytes else {
                throw LinuxUpdateTransportError.tooLarge
            }
            return data
        }
    }
}
