import Foundation
import SensoriumCore
import SensoriumHost

/// `FakeHostByteChannel.receiveBytes(count:)` polls every 5ms once its
/// script is exhausted, so a fed byte arriving later is still picked up --
/// see its own doc comment. Review finding (MEDIUM): without checking
/// `cancel()`'s own flag, that loop ran for the rest of the process for
/// every session a test ever started and stopped, since
/// `HostNetworkSession.start()` launches `run()` in an untracked `Task`
/// that nothing else ever cancels.
@MainActor
func runFakeHostByteChannelTests() async {
    let channel = FakeHostByteChannel(scriptedPackets: [])
    let receiveTask = Task {
        try await channel.receiveBytes(count: 5)
    }
    // Let the loop actually start polling an empty buffer before cancelling.
    try! await Task.sleep(for: .milliseconds(20))
    channel.cancel()

    let started = MonotonicClock.nowNanoseconds()
    do {
        _ = try await receiveTask.value
        expect(false, "receiveBytes must throw once the channel is cancelled, not return bytes that were never fed")
    } catch is HostNetworkSessionError {
        let elapsedNanoseconds = MonotonicClock.nowNanoseconds() - started
        expect(
            elapsedNanoseconds < 50_000_000,
            "receiveBytes throws within about one poll interval of cancel() being called, not after the full closeAfterScriptDelay or never"
        )
    } catch {
        expect(false, "receiveBytes reports HostNetworkSessionError.closed on cancellation, not \(error)")
    }

    print("PASS: FakeHostByteChannel.receiveBytes throws promptly once cancel() is called, instead of polling forever")
}
