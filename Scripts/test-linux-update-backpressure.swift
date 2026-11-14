// Appended to the extracted production transport by the Python test driver.
private final class GatedSink: LinuxTransferSink, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    private(set) var chunks: [Data] = []
    func write(_ data: Data) throws {
        if chunks.isEmpty {
            entered.signal()
            proceed.wait()
        }
        chunks.append(data)
    }
}

@main struct BackpressureTest {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func wait(_ semaphore: DispatchSemaphore, _ message: String) {
        check(semaphore.wait(timeout: .now() + 10) == .success, message)
    }
    static func main() async {
        let router = LinuxTransferRouter()
        let session = router.session
        // These tasks are never resumed: callbacks are delivered explicitly, so
        // the ordering and 8 MiB boundary do not depend on the network or disk.
        let firstTask = URLSession.shared.dataTask(with: URL(string: "https://example.invalid/first")!)
        let secondTask = URLSession.shared.dataTask(with: URL(string: "https://example.invalid/second")!)
        let blockedSink = GatedSink()
        let otherSink = LinuxMemorySink()
        let first = LinuxCappedTransferDelegate(maximumBytes: 20 * 1024 * 1024, sink: blockedSink)
        let second = LinuxCappedTransferDelegate(maximumBytes: 20 * 1024 * 1024, sink: otherSink)
        let registered = DispatchSemaphore(value: 0)
        let result = Task.detached { () -> String in
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    first.continuation = continuation
                    registered.signal()
                }
                return "unexpected success"
            } catch LinuxUpdateTransportError.failed(let message) {
                return message
            } catch {
                return "unexpected error: \(error)"
            }
        }
        wait(registered, "continuation not installed")
        router.register(first, for: firstTask)
        router.register(second, for: secondTask)
        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        router.urlSession(session, dataTask: firstTask, didReceive: chunk)
        wait(blockedSink.entered, "first sink did not block")
        for _ in 1..<8 { router.urlSession(session, dataTask: firstTask, didReceive: chunk) }
        // The limit is inclusive; the next byte must fail without being written.
        router.urlSession(session, dataTask: firstTask, didReceive: Data([0x42]))
        let otherData = Data("other transfer remains independent".utf8)
        router.urlSession(session, dataTask: secondTask, didReceive: otherData)
        second.queue.sync {}
        check(otherSink.data == otherData, "other transfer blocked or corrupted")
        check(!first.reserve(1), "overloaded transfer lost its outstanding reservations")
        blockedSink.proceed.signal()
        first.queue.sync {}
        check(blockedSink.chunks.count == 8, "queued writes did not drain or overflow byte was written")
        check(blockedSink.chunks.allSatisfy { $0 == chunk }, "queued write contents changed")
        check(first.reserve(8 * 1024 * 1024), "queued write reservations not released")
        first.release(8 * 1024 * 1024)
        router.urlSession(session, task: firstTask, didCompleteWithError: nil)
        let failure = await result.value
        check(failure == "download sink could not keep up", "wrong result: \(failure)")
        let after = Data(" still works".utf8)
        router.urlSession(session, dataTask: secondTask, didReceive: after)
        second.queue.sync {}
        check(otherSink.data == otherData + after, "other transfer affected by overload completion")
        router.urlSession(session, task: secondTask, didCompleteWithError: nil)
        second.queue.sync {}
        print("PASS: 8 MiB inclusive cap, overflow failure, queued writes drained, concurrent transfer unaffected")
    }
}
