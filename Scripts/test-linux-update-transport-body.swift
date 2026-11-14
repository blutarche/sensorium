@main struct Test {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() async throws {
        let base = ProcessInfo.processInfo.environment["TEST_HTTPS_BASE"]!
        func url(_ path: String) -> URL { URL(string: base + path)! }
        let transport = URLSessionLinuxUpdateTransport()
        if ProcessInfo.processInfo.environment["RACE_TEST"] == "1" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { fputs("FAIL: cancellation before registration hung\n", stderr); exit(1) }
            let stallURL = url("/stall")
            let cancelled = Task.detached { try await transport.fetch(stallURL, maximumBytes: 100) }
            testRegistrationReached.wait()
            cancelled.cancel()
            try await Task.sleep(for: .milliseconds(300))
            testRegistrationContinue.signal()
            do { _ = try await cancelled.value; check(false, "cancellation ignored") } catch {}
            print("PASS: cancellation before registration")
            return
        }
        if ProcessInfo.processInfo.environment["OWN_DEADLINE_TEST"] == "1" || ProcessInfo.processInfo.environment["OWN_CANCEL_TEST"] == "1" || ProcessInfo.processInfo.environment["OWN_SYNC_TEST"] == "1" {
            let cancel = ProcessInfo.processInfo.environment["OWN_CANCEL_TEST"] == "1"
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let fileURL = url("/data/file")
            let finished = DispatchSemaphore(value: 0)
            let blocked = Task.detached {
                defer { finished.signal() }
                try await transport.download(fileURL, to: file, maximumBytes: 100)
            }
            testSinkReached.wait()
            if cancel { blocked.cancel() }
            try await Task.sleep(for: .milliseconds(cancel ? 400 : 4000))
            check(finished.wait(timeout: .now()) == .timedOut, "returned while sink still writing")
            testSinkContinue.signal()
            do { try await blocked.value; check(false, cancel ? "blocked cancellation reported success" : "blocked deadline reported success") }
            catch LinuxUpdateTransportError.failed {} catch { throw error }
            let bytes = try Data(contentsOf: file)
            try await Task.sleep(for: .milliseconds(200))
            let laterBytes = try Data(contentsOf: file)
            check(laterBytes == bytes, "file changed after return")
            print("PASS: blocked own \(cancel ? "cancellation" : "deadline") waits for writer and fails")
            return
        }
        if ProcessInfo.processInfo.environment["BLOCK_TEST"] == "1" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { fputs("FAIL: blocked sink stalled other deadline\n", stderr); exit(1) }
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let fileURL = url("/data/file")
            let blocked = Task.detached { try await transport.download(fileURL, to: file, maximumBytes: 100) }
            testSinkReached.wait()
            let started = Date()
            do { _ = try await transport.fetch(url("/stall"), maximumBytes: 100); check(false, "deadline ignored") } catch {}
            check(Date().timeIntervalSince(started) < 2.5, "other deadline delayed by blocked sink")
            testSinkContinue.signal()
            try await blocked.value
            print("PASS: blocked sink does not stall other deadline")
            return
        }

        let one = try await transport.fetch(url("/data/one"), maximumBytes: 100)
        check(String(data: one, encoding: .utf8) == "one", "basic fetch")
        let redirect = try await transport.fetch(url("/redirect"), maximumBytes: 100)
        check(String(data: redirect, encoding: .utf8) == "one", "https redirect")
        do { _ = try await transport.fetch(url("/downgrade"), maximumBytes: 100); check(false, "http redirect accepted") }
        catch LinuxUpdateTransportError.badStatus(302) {} catch { throw error }
        do { _ = try await transport.fetch(url("/missing"), maximumBytes: 100); check(false, "status accepted") }
        catch LinuxUpdateTransportError.badStatus(404) {} catch { throw error }
        do { _ = try await transport.fetch(url("/data/longer"), maximumBytes: 2); check(false, "cap ignored") }
        catch LinuxUpdateTransportError.tooLarge {} catch { throw error }
        do { _ = try await transport.fetch(url("/stream"), maximumBytes: 2); check(false, "streaming cap ignored") }
        catch LinuxUpdateTransportError.tooLarge {} catch { throw error }
        do { _ = try await transport.fetch(URL(string: "ftp://127.0.0.1/")!, maximumBytes: 100); check(false, "http accepted") }
        catch LinuxUpdateTransportError.failed {} catch { throw error }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try await transport.download(url("/data/file"), to: file, maximumBytes: 100)
        let fileData = try Data(contentsOf: file)
        check(fileData == Data("file".utf8), "file sink")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let text = "item-\(i)"
                    let data = try await transport.fetch(url("/data/" + text), maximumBytes: 100)
                    check(data == Data(text.utf8), "concurrent routing \(i)")
                }
            }
            for i in 0..<20 {
                group.addTask {
                    let text = "file-\(i)"
                    let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: destination) }
                    try await transport.download(url("/data/" + text), to: destination, maximumBytes: 100)
                    let bytes = try Data(contentsOf: destination)
                    check(bytes == Data(text.utf8), "concurrent file routing \(i)")
                }
            }
            try await group.waitForAll()
        }
        let started = Date()
        do { _ = try await transport.fetch(url("/stall"), maximumBytes: 100); check(false, "deadline ignored") }
        catch LinuxUpdateTransportError.failed {} catch { throw error }
        check(Date().timeIntervalSince(started) < 3, "deadline too slow")
        let cancelled = Task.detached { try await transport.fetch(url("/stall"), maximumBytes: 100) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelStart = Date()
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "cancellation ignored") } catch {}
        check(Date().timeIntervalSince(cancelStart) < 0.8, "cancellation too slow")
        let preCancelled = Task { try await transport.fetch(url("/stall"), maximumBytes: 100) }
        preCancelled.cancel()
        let preCancelStart = Date()
        do { _ = try await preCancelled.value; check(false, "pre-cancellation ignored") } catch {}
        check(Date().timeIntervalSince(preCancelStart) < 0.8, "pre-cancellation too slow")
        for _ in 0..<50 { _ = try await transport.fetch(url("/data/x"), maximumBytes: 100) }
        try await Task.sleep(for: .seconds(2))
        print("PASS: loopback transport, redirects, status, caps, file sink, 50 concurrent, deadline, cancellation, 50 sequential")
    }
}
