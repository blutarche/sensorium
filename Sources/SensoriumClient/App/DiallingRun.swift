import Foundation
import SensoriumCore

/// The viewer's dialling loop, in one place: a driver per run of attempts, and
/// a wake-up the user can fire from the status panel.
///
/// `ClientReconnectDriver` is deliberately one-shot — a driver the user stopped
/// stays stopped — so trying again builds a new one. Nothing here changes the
/// retry policy: what makes the wait finite is the user's own choice to stop it.
@MainActor
final class DiallingRun {
    private let makeDriver: () -> ClientReconnectDriver
    private var current: ClientReconnectDriver?
    /// The task one run of attempts is running in, so stopping can cancel the
    /// wait between them rather than serving it out. A live session is ended
    /// through `ClientSessionHost` first; cancelling alone would leave it
    /// parked on the picture it is still showing.
    private var runTask: Task<ClientReconnectOutcome, Never>?
    private(set) var isStopped = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// A wake-up that arrives before anything is waiting must not be dropped,
    /// or a fast Try again would park the loop forever.
    private var pendingWake = false

    init(makeDriver: @escaping () -> ClientReconnectDriver) {
        self.makeDriver = makeDriver
    }

    func startRun() async -> ClientReconnectOutcome {
        isStopped = false
        let driver = makeDriver()
        current = driver
        return await runCancellably { await driver.runUntilConnectedSessionEnds() }
    }

    /// Redials within the run already in progress, so its backoff schedule
    /// continues instead of restarting.
    func continueRun() async -> ClientReconnectOutcome {
        guard let current else { return .stopped }
        return await runCancellably { await current.runUntilConnectedSessionEnds() }
    }

    private func runCancellably(
        _ body: @escaping @Sendable () async -> ClientReconnectOutcome
    ) async -> ClientReconnectOutcome {
        let task = Task { await body() }
        runTask = task
        let outcome = await task.value
        runTask = nil
        return outcome
    }

    func stopCurrentRun() {
        isStopped = true
        let driver = current
        Task { await driver?.stop() }
        runTask?.cancel()
    }

    func wake() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            pendingWake = true
        }
    }

    func waitForRetry() async {
        if pendingWake {
            pendingWake = false
            return
        }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

extension DiallingRun {
    /// Stops the current run and wakes anything waiting for a retry, so a
    /// return to the launch window is never left blocked on this one.
    func stop() {
        stopCurrentRun()
        wake()
    }
}

