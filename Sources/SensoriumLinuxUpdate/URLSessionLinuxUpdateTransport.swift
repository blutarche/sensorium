#if os(Linux)
import Foundation
import FoundationNetworking

/// The Linux apps' real update transport: an ephemeral session that keeps
/// no cookies, cache or credentials, names itself with
/// `LinuxUpdateReleaseLocation.userAgent`, gives up on a request after
/// `LinuxUpdateReleaseLocation.timeout` and fails a transfer past its
/// deadline, follows only https redirects, and cancels a response the moment
/// it passes the caller's cap. GitHub answers every release address with a
/// redirect to its file host; integrity rests on the manifest's signature
/// and the archive's SHA-256, not on which server answered.
public struct URLSessionLinuxUpdateTransport: LinuxUpdateTransport {
    public init() {}

    static func makeConfiguration(deadline: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = LinuxUpdateReleaseLocation.timeout
        configuration.timeoutIntervalForResource = deadline
        configuration.httpAdditionalHeaders = ["User-Agent": LinuxUpdateReleaseLocation.userAgent]
        return configuration
    }

    private static let router: LinuxTransferRouter = {
        let router = LinuxTransferRouter()
        _ = router.session // Initialize before publishing to concurrent callers.
        return router
    }()

    public func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let sink = LinuxMemorySink()
        try await transfer(url, maximumBytes: Int64(maximumBytes), deadline: LinuxUpdateReleaseLocation.smallFileDeadline, into: sink)
        return sink.data
    }

    public func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        let descriptor = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else {
            throw LinuxUpdateTransportError.failed("could not create \(destination.lastPathComponent)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try await transfer(url, maximumBytes: maximumBytes, deadline: LinuxUpdateReleaseLocation.archiveDeadline, into: LinuxFileSink(handle: handle))
    }

    private func transfer(_ url: URL, maximumBytes: Int64, deadline: TimeInterval, into sink: any LinuxTransferSink) async throws {
        guard url.scheme == "https" else {
            throw LinuxUpdateTransportError.failed("only https addresses are fetched")
        }
        var request = URLRequest(url: url)
        request.setValue(LinuxUpdateReleaseLocation.userAgent, forHTTPHeaderField: "User-Agent")
        let task = Self.router.session.dataTask(with: request)
        let deadlineTime = DispatchTime.now() + deadline
        let cancellation = LinuxTransferCancellation(task: task, deadline: deadlineTime)
        let delegate = LinuxCappedTransferDelegate(maximumBytes: maximumBytes, sink: sink)
        delegate.cancellation = cancellation
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: deadlineTime)
        timer.setEventHandler { cancellation.cancel() }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.continuation = continuation
                Self.router.register(delegate, for: task)
                cancellation.start()
                timer.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }

    }
}

/// Cancellation cannot reach URLSession before the router and continuation exist.
private final class LinuxTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let task: URLSessionTask
    private let deadline: DispatchTime
    private var started = false
    private var cancelled = false
    private var finished = false

    init(task: URLSessionTask, deadline: DispatchTime) { self.task = task; self.deadline = deadline }
    func start() {
        lock.lock()
        started = true
        task.resume()
        if cancelled { task.cancel() }
        lock.unlock()
    }
    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancelled = true
        if started { task.cancel() }
        lock.unlock()
    }

    // Called only after all queued writes finish. A blocked synchronous write
    // cannot be interrupted safely; returning earlier would let it mutate a
    // caller-owned file after the caller starts cleanup. The deadline bounds
    // success, not the time spent waiting for a stuck filesystem.
    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return cancelled || DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds
    }
}

/// FoundationNetworking can abort while tearing down a session's curl multi
/// handle. Keep exactly one ephemeral session for the process, rather than
/// invalidating a session after every transfer. Completed transfers are removed.
private final class LinuxTransferRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: LinuxCappedTransferDelegate] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    lazy var session: URLSession = URLSession(
        configuration: URLSessionLinuxUpdateTransport.makeConfiguration(deadline: LinuxUpdateReleaseLocation.archiveDeadline),
        delegate: self, delegateQueue: queue
    )

    func register(_ transfer: LinuxCappedTransferDelegate, for task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        transfers[task.taskIdentifier] = transfer
    }

    private func transfer(for task: URLSessionTask, removing: Bool = false) -> LinuxCappedTransferDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return removing ? transfers.removeValue(forKey: task.taskIdentifier) : transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let transfer = transfer(for: task) else { return completionHandler(nil) }
        transfer.queue.async { transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(for: dataTask) else { return completionHandler(.cancel) }
        transfer.queue.async { transfer.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        // Bound outstanding writes so a stalled disk cannot buffer an entire
        // archive. Overload fails this transfer, never the shared router.
        guard transfer.reserve(data.count) else {
            transfer.queue.async { transfer.failBackpressure() }
            dataTask.cancel()
            return
        }
        transfer.queue.async {
            transfer.urlSession(session, dataTask: dataTask, didReceive: data)
            transfer.release(data.count)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = transfer(for: task, removing: true) else { return }
        transfer.queue.async { transfer.urlSession(session, task: task, didCompleteWithError: error) }
    }
}

private protocol LinuxTransferSink: AnyObject, Sendable {
    func write(_ data: Data) throws
    func finish() throws
}

private extension LinuxTransferSink { func finish() throws {} }

private final class LinuxMemorySink: LinuxTransferSink, @unchecked Sendable {
    private(set) var data = Data()
    func write(_ chunk: Data) { data.append(chunk) }
}

private final class LinuxFileSink: LinuxTransferSink, @unchecked Sendable {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ chunk: Data) throws { try handle.write(contentsOf: chunk) }
    func finish() throws { try handle.synchronize() }
}

/// Counts bytes as they arrive and cancels the task past the cap, so an
/// oversized or endless response never lands in memory or on disk. Every
/// transfer is serialized on its own queue, separate from the router.
private final class LinuxCappedTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let pendingLock = NSLock()
    private var pendingBytes = 0
    private let pendingLimit = 8 * 1024 * 1024
    func reserve(_ count: Int) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard count <= pendingLimit - pendingBytes else { return false }
        pendingBytes += count
        return true
    }
    func release(_ count: Int) {
        pendingLock.lock()
        pendingBytes -= count
        pendingLock.unlock()
    }
    func failBackpressure() { failure = .failed("download sink could not keep up") }

    let queue = DispatchQueue(label: "sensorium.update.transfer")
    let maximumBytes: Int64
    let sink: any LinuxTransferSink
    var cancellation: LinuxTransferCancellation?
    var continuation: CheckedContinuation<Void, any Error>?
    private var received: Int64 = 0
    private var failure: LinuxUpdateTransportError?

    init(maximumBytes: Int64, sink: any LinuxTransferSink) {
        self.maximumBytes = maximumBytes
        self.sink = sink
    }

    /// A redirect to anything but https is not followed, which leaves the
    /// redirect itself as the response, refused below by its status.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
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
        if failure == nil && error == nil {
            do { try sink.finish() }
            catch { failure = .failed("could not finish the download") }
        }
        if cancellation?.complete() == true {
            continuation?.resume(throwing: LinuxUpdateTransportError.failed("transfer cancelled or deadline exceeded"))
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: LinuxUpdateTransportError.failed(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}
#endif
