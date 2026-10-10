#if os(macOS)
import Foundation

/// Every address the updater contacts. Each is a constant or is built from a
/// constant and fields of a verified manifest; the updater never follows an
/// address it was handed whole.
public enum UpdateReleaseLocation {
    public static let manifestURL = URL(string: "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update.json")!
    public static let signatureURL = URL(string: "https://github.com/blutarche/sensorium/releases/latest/download/sensorium-update.json.sig")!

    /// The cap on the manifest and on its signature.
    public static let maximumSmallFileBytes = 64 * 1024

    /// `UpdateManifest.parse` has already held `app.file` to exactly
    /// `Sensorium-<version>.zip` or `Sensorium-Host-<version>.zip`.
    public static func downloadURL(version: UpdateVersion, app: UpdateManifest.App) -> URL {
        URL(string: "https://github.com/blutarche/sensorium/releases/download/v\(version)/\(app.file)")!
    }
}

public enum UpdateTransportError: Error, Equatable {
    /// The response ran past the byte cap the caller gave.
    case tooLarge
    case badStatus(Int)
    case failed(String)
}

/// Fetches the release page's files. Behind a protocol so tests use a local
/// fake and make no network request.
public protocol UpdateTransport: Sendable {
    /// The whole body of `url`, or `UpdateTransportError.tooLarge` past
    /// `maximumBytes`.
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data

    /// Writes the body of `url` to a new file at `destination`, or throws
    /// `UpdateTransportError.tooLarge` past `maximumBytes`.
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws
}

/// The real transport. GitHub answers both release addresses with a
/// redirect to its file host, which is followed: integrity rests on the
/// manifest's signature and the zip's SHA-256, not on which server answered.
public struct URLSessionUpdateTransport: UpdateTransport {
    public static let userAgent = "Sensorium-Update/1"
    public static let timeout: TimeInterval = 30

    public init() {}

    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }

    public func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let sink = MemorySink()
        try await transfer(url, maximumBytes: Int64(maximumBytes), into: sink)
        return sink.data
    }

    public func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        let descriptor = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else {
            throw UpdateTransportError.failed("could not create \(destination.lastPathComponent)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try await transfer(url, maximumBytes: maximumBytes, into: FileSink(handle: handle))
        try handle.synchronize()
    }

    private func transfer(_ url: URL, maximumBytes: Int64, into sink: any TransferSink) async throws {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let delegate = CappedTransferDelegate(maximumBytes: maximumBytes, sink: sink)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.makeConfiguration(), delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            delegate.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }
}

private protocol TransferSink: AnyObject, Sendable {
    func write(_ data: Data) throws
}

private final class MemorySink: TransferSink, @unchecked Sendable {
    private(set) var data = Data()
    func write(_ chunk: Data) { data.append(chunk) }
}

private final class FileSink: TransferSink, @unchecked Sendable {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ chunk: Data) throws { try handle.write(contentsOf: chunk) }
}

/// Counts bytes as they arrive and cancels the task past the cap, so an
/// oversized or endless response never lands in memory or on disk. Every
/// callback runs on the session's one serial delegate queue.
private final class CappedTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    let sink: any TransferSink
    var continuation: CheckedContinuation<Void, any Error>?
    private var received: Int64 = 0
    private var failure: UpdateTransportError?

    init(maximumBytes: Int64, sink: any TransferSink) {
        self.maximumBytes = maximumBytes
        self.sink = sink
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = .badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            return completionHandler(.cancel)
        }
        if response.expectedContentLength > maximumBytes {
            failure = .tooLarge
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= maximumBytes else {
            failure = .tooLarge
            return dataTask.cancel()
        }
        do {
            try sink.write(data)
        } catch {
            failure = .failed("could not write the download")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = continuation
        self.continuation = nil
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: UpdateTransportError.failed(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}
#endif
