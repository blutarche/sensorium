#if os(macOS)
import CryptoKit
import Foundation
import SensoriumUpdate

/// A local stand-in for the GitHub release page: serves whatever bytes a test
/// puts at an address, and records every request. Nothing leaves the process.
final class FakeReleasePage: UpdateTransport, @unchecked Sendable {
    struct Request: Equatable {
        let url: URL
        let maximumBytes: Int64
    }

    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var failures: Set<URL> = []
    private var recorded: [Request] = []

    var requests: [Request] {
        lock.withLock { recorded }
    }

    func serve(_ data: Data, at url: URL) {
        lock.withLock { files[url] = data }
    }

    func fail(_ url: URL) {
        lock.withLock { _ = failures.insert(url) }
    }

    /// Serves `manifest` and its signature, made with `key`, at the release's
    /// fixed addresses.
    func publish(_ manifest: Data, signedWith key: Curve25519.Signing.PrivateKey) {
        serve(manifest, at: UpdateReleaseLocation.manifestURL)
        serve(signatureFile(signing: manifest, with: key), at: UpdateReleaseLocation.signatureURL)
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let data = try respond(url, maximumBytes: Int64(maximumBytes))
        return data
    }

    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        let data = try respond(url, maximumBytes: maximumBytes)
        try data.write(to: destination)
    }

    private func respond(_ url: URL, maximumBytes: Int64) throws -> Data {
        try lock.withLock {
            recorded.append(Request(url: url, maximumBytes: maximumBytes))
            guard !failures.contains(url), let data = files[url] else {
                throw UpdateTransportError.failed("not served")
            }
            guard Int64(data.count) <= maximumBytes else {
                throw UpdateTransportError.tooLarge
            }
            return data
        }
    }
}
#endif
