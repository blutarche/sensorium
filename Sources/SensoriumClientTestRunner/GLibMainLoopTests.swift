#if canImport(CGLib)
import Foundation
import SensoriumClient

/// The Linux viewer's event loop has to carry this process's own scheduled
/// work, or nothing a session does off the wire would ever reach the screen.
/// Both kinds are checked: a Dispatch block, which is what the platform's own
/// callbacks arrive as, and a `@MainActor` job, which is what every await in
/// the viewer resumes as.
@MainActor
func testGLibMainLoopTests() {
    nonisolated(unsafe) var ranDispatchBlock = false
    nonisolated(unsafe) var ranMainActorJob = false

    DispatchQueue.main.async {
        ranDispatchBlock = true
    }
    Task { @MainActor in
        ranMainActorJob = true
        GLibMainLoop.stop()
    }
    // A loop that never carries the work above would otherwise hang the whole
    // runner rather than fail it.
    let watchdog = Task.detached {
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }
        GLibMainLoop.stop()
    }

    GLibMainLoop.run()
    watchdog.cancel()

    expect(ranDispatchBlock, "a DispatchQueue.main.async block runs inside GLibMainLoop.run()")
    expect(ranMainActorJob, "a @MainActor job runs inside GLibMainLoop.run()")
    expect(!GLibMainLoop.isRunning, "GLibMainLoop.stop() ends the loop and run() returns")

    print("PASS: GLibMainLoop carries Dispatch main-queue work and main-actor jobs, and stops on request")
}
#else
/// Nothing to check where there is no GLib: the macOS viewer runs an AppKit
/// run loop.
@MainActor
func testGLibMainLoopTests() {}
#endif
