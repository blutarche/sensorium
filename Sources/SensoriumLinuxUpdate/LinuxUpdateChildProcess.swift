import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum LinuxUpdateChildOutcome: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
}

enum LinuxUpdateChildProcess {
    /// Waits for `process` to end, killing it once `timeout` has passed.
    /// Polls `isRunning`: `Process.waitUntilExit()` spins the calling
    /// thread's run loop, which can wait forever on a thread that has none
    /// running.
    static func wait(for process: Process, timeout: TimeInterval?) -> LinuxUpdateChildOutcome {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while process.isRunning {
            if let deadline, Date() >= deadline {
                kill(process.processIdentifier, SIGKILL)
                while process.isRunning {
                    usleep(1_000)
                }
                return .timedOut
            }
            usleep(2_000)
        }
        return process.terminationReason == .exit ? .exited(process.terminationStatus) : .signaled(process.terminationStatus)
    }

    /// Runs blocking work on a thread of its own, so a child process or a
    /// large file never holds a thread of the cooperative pool.
    static func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: body())
            }
        }
    }
}
