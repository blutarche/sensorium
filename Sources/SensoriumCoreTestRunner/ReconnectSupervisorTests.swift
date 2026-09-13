import Foundation
import SensoriumCore

func testReconnectBackoffDoublesAndIsCapped() {
    let policy = ReconnectPolicy.remoteDefault
    expect(policy.delay(forAttempt: 1) == 0.5, "first retry waits half a second")
    expect(policy.delay(forAttempt: 2) == 1.0, "second retry doubles")
    expect(policy.delay(forAttempt: 3) == 2.0, "third retry doubles again")
    expect(policy.delay(forAttempt: 6) == 8.0, "backoff is capped")
    expect(policy.delay(forAttempt: 99) == 8.0, "capped backoff never grows past the ceiling")
    expect(policy.delay(forAttempt: 0) == nil, "attempt numbering starts at one")
}

func testConnectionSupervisorRetriesLossAndStopsOnUserDisconnect() {
    var supervisor = ConnectionSupervisor(policy: .remoteDefault)
    expect(supervisor.handle(.connectRequested) == .connect, "a connect request dials immediately")
    expect(supervisor.handle(.transportLost) == .reconnect(after: 0.5), "transport loss schedules the first retry")
    expect(supervisor.handle(.connectFailed) == .reconnect(after: 1.0), "a failed retry backs off further")
    expect(supervisor.handle(.connectSucceeded) == .idle, "a successful connect stops retrying")
    expect(supervisor.handle(.transportLost) == .reconnect(after: 0.5), "backoff resets after a good session")
    expect(supervisor.handle(.userDisconnected) == .stop, "an explicit disconnect ends supervision")
    expect(supervisor.handle(.transportLost) == .stop, "supervision stays stopped after the user disconnects")
}

func testConnectionSupervisorGivesUpAfterMaximumAttempts() {
    var supervisor = ConnectionSupervisor(
        policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 8, multiplier: 2, maximumAttempts: 2)
    )
    _ = supervisor.handle(.connectRequested)
    expect(supervisor.handle(.transportLost) == .reconnect(after: 0.5), "first retry is scheduled")
    expect(supervisor.handle(.connectFailed) == .reconnect(after: 1.0), "second retry is scheduled")
    expect(supervisor.handle(.connectFailed) == .giveUp, "a bounded policy gives up instead of retrying forever")
}

