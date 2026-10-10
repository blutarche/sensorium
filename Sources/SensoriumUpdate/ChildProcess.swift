#if os(macOS)
import Foundation

enum ChildProcessOutcome: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case couldNotStart
}

/// Runs a program with no input or output and reports how it ended. Past
/// `timeout` the program is killed and the outcome is `.timedOut`.
final class ChildProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChildProcessOutcome, Never>?

    static func run(_ executable: URL, arguments: [String], timeout: Duration?) async -> ChildProcessOutcome {
        await ChildProcess().run(executable, arguments: arguments, timeout: timeout)
    }

    private func run(_ executable: URL, arguments: [String], timeout: Duration?) async -> ChildProcessOutcome {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            process.terminationHandler = { process in
                self.finish(process.terminationReason == .exit ? .exited(process.terminationStatus) : .signaled(process.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                finish(.couldNotStart)
                return
            }
            guard let timeout else { return }
            let pid = process.processIdentifier
            Task {
                try? await Task.sleep(for: timeout)
                if self.finish(.timedOut) {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    /// Resumes the waiting caller once; later calls do nothing and return
    /// false.
    @discardableResult
    private func finish(_ outcome: ChildProcessOutcome) -> Bool {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: outcome)
        return continuation != nil
    }
}
#endif
