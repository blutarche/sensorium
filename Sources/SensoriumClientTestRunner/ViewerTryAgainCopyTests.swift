import Foundation
import SensoriumClient
import SensoriumCore

/// Every body shown over a Try Again default says what trying again does, so
/// the button never asks for a press the words around it have not explained.
func testViewerTryAgainBodiesSayWhatItDoesTests() {
    let host = "Studio"

    // The exact lines the host's endings read as.
    expect(
        ViewerSessionFailureCopy.line(for: .stoppedByHost, hostLabel: host)
            == "Stopped: a person at Studio ended this session from that machine. "
            + "Trying again starts a new session.",
        "a Stop at the host says what Try Again does"
    )
    expect(
        ViewerSessionFailureCopy.line(for: .hostCaptureUnavailable, hostLabel: host)
            == "Stopped: Studio is no longer giving Sensorium any picture to send. Someone there can quit and "
            + "reopen Sensorium Host. Trying again then starts a new session.",
        "a host that cannot capture says who can fix it and what Try Again does after"
    )
    expect(
        ViewerSessionFailureCopy.line(for: .hostDisplaysAsleep, hostLabel: host)
            == "Stopped: the screens on Studio are asleep, so there was nothing to send. Sensorium asked that "
            + "machine to wake them and they did not come back. Someone there can wake a screen. "
            + "Trying again then starts a new session.",
        "sleeping screens say who can wake one and what Try Again does after"
    )
    expect(
        ViewerSessionFailureCopy.line(for: .unknown, hostLabel: host)
            == "The session with Studio stopped, and Sensorium could not tell why. Trying again starts a new "
            + "session. If it keeps failing, quit and reopen Sensorium on both machines.",
        "an ending nobody could explain still says what Try Again does"
    )
    expect(
        HostScreenRefusalCopy.line(reason: "host-screen-resume-expired")
            == "The connection was away too long to resume. Trying again starts a new session.",
        "an expired resume says what Try Again does"
    )

    var live = ViewerSessionStateMachine(hostName: host)
    live.handle(.connectStarted)
    live.handle(.canvasReady)
    expect(
        unbound(live.handle(.sessionEnded).detail)
            == "The picture is frozen where the connection dropped. Trying again reconnects.",
        "a dropped connection says what Try Again does"
    )

    let unreadable = ViewerStartupFailureCopy.copy(
        for: .unreadable(reason: "this machine\u{2019}s saved key can\u{2019}t be read")
    )
    expect(
        unbound(unreadable.detail) == "This machine\u{2019}s saved key can\u{2019}t be read. Without it there is "
            + "nothing to prove which machine this is, so no session can start. "
            + "Trying again reads the key once more.",
        "the key that cannot be read says what Try Again does, got \(unbound(unreadable.detail))"
    )
    expect(
        unreadable.detail == ViewerCopyWrapping.keepingTailTogether(unreadable.detail),
        "and its closing words stay together"
    )

    // Whatever reaches the panel: every state whose default is Try Again.
    let refusalReasons = [
        HostScreenRefusalCopy.noneAvailableReason, HostScreenRefusalCopy.retryNeedsPersonReason,
        "canvas-session-active", "host-screen-not-allowed", "host-screen-presence-declined",
        "host-screen-presence-unanswered", "host-screen-presence-check-required",
        "host-screen-display-unavailable", "host-screen-resume-refused", "host-screen-resume-expired",
        "host-screen-session-active", "host-screen-already-live", "a-future-reason"
    ]
    var statuses: [(String, ViewerSessionStatus)] = []
    var machine = ViewerSessionStateMachine(hostName: host)
    machine.handle(.connectStarted)
    machine.handle(.canvasReady)
    statuses.append(("session ended", machine.handle(.sessionEnded)))
    statuses.append(("stop requested", machine.handle(.stopRequested)))
    statuses.append(("gave up", machine.handle(.gaveUp)))
    let hostEndings: [ViewerSessionFailure] = [.hostDisplaysAsleep, .hostCaptureUnavailable, .unknown]
    for failure in hostEndings {
        statuses.append((
            "host ended \(failure)",
            machine.handle(.hostEnded(reasonLine: ViewerSessionFailureCopy.line(for: failure, hostLabel: host)))
        ))
    }
    statuses.append((
        "stopped by host",
        machine.handle(.stoppedByHost(reasonLine: ViewerSessionFailureCopy.line(for: .stoppedByHost, hostLabel: host)))
    ))
    for reason in refusalReasons {
        let line = HostScreenRefusalCopy.line(reason: reason, hostLabel: host)
        for offersPrivateDesktop in [false, true] {
            statuses.append((
                "refused \(reason), private desktop \(offersPrivateDesktop)",
                machine.handle(.hostScreenConnectEnded(reasonLine: line, offersVirtualDisplay: offersPrivateDesktop))
            ))
        }
    }
    var checked = 0
    for (name, status) in statuses where status.buttons.contains(where: { $0.action == .tryAgain && $0.isPrimary }) {
        checked += 1
        expect(
            unbound(status.detail).localizedCaseInsensitiveContains("trying again"),
            "the \(name) body sits over Try Again and says what trying again does, got \"\(unbound(status.detail))\""
        )
    }
    expect(checked == statuses.count, "every state in the sweep has Try Again as its default, only \(checked) did")

    print("PASS: every body shown over Try Again says what trying again does")
}

/// The first reconnecting panel says where the picture froze: at a dropped
/// connection, or at an ending that was not a drop.
func testViewerRetryAfterEndingCopyTests() {
    let dropped = "The picture is frozen where the connection dropped."
    let ended = "The picture is frozen where the session ended."

    func live() -> ViewerSessionStateMachine {
        var machine = ViewerSessionStateMachine(hostName: "Studio")
        machine.handle(.connectStarted)
        machine.handle(.canvasReady)
        return machine
    }

    let endings: [(String, (inout ViewerSessionStateMachine) -> Void)] = [
        ("a Stop at the host", { $0.handle(.stoppedByHost(reasonLine: "Stopped.")) }),
        ("an ending the host named", { $0.handle(.hostEnded(reasonLine: "The host ended it.")) }),
        ("a refused host screen", { $0.handle(.hostScreenConnectEnded(reasonLine: "No screen.")) }),
        (
            "a refused host screen with a private desktop on offer",
            { $0.handle(.hostScreenConnectEnded(reasonLine: "No screen.", offersVirtualDisplay: true)) }
        )
    ]
    for (name, end) in endings {
        var machine = live()
        end(&machine)
        let retried = machine.handle(.retryRequested)
        expect(
            retried.phase == .reconnecting && unbound(retried.detail) == ended,
            "Try Again after \(name) says where the session ended, got \"\(unbound(retried.detail))\""
        )
        expect(
            unbound(machine.handle(.connectStarted).detail) == ended,
            "and so does the first dial that follows, got \"\(unbound(machine.status.detail))\""
        )
        machine.handle(.stopRequested)
        expect(
            unbound(machine.handle(.retryRequested).detail) == ended,
            "and Cancel then Try Again does not change what froze the picture"
        )
        machine.handle(.canvasReady)
        machine.handle(.sessionEnded)
        expect(
            unbound(machine.handle(.retryRequested).detail) == dropped,
            "but a drop after a picture came back is a drop again, got \"\(unbound(machine.status.detail))\""
        )
    }

    var drop = live()
    drop.handle(.sessionEnded)
    expect(unbound(drop.handle(.retryRequested).detail) == dropped, "Try Again after a drop says the connection dropped")
    expect(unbound(drop.handle(.connectStarted).detail) == dropped, "and so does the first dial after it")

    var gaveUp = live()
    gaveUp.handle(.sessionEnded)
    gaveUp.handle(.connectStarted)
    gaveUp.handle(.gaveUp)
    expect(
        unbound(gaveUp.handle(.retryRequested).detail) == dropped,
        "Try Again after the retries ran out says the connection dropped"
    )

    var stopped = live()
    stopped.handle(.sessionEnded)
    stopped.handle(.connectStarted)
    stopped.handle(.stopRequested)
    expect(
        unbound(stopped.handle(.retryRequested).detail) == dropped,
        "Try Again after Cancel on a drop says the connection dropped"
    )

    var neverLive = ViewerSessionStateMachine(hostName: "Studio")
    neverLive.handle(.hostScreenConnectEnded(reasonLine: "No screen."))
    expect(
        neverLive.handle(.retryRequested).phase == .connecting,
        "a window that never had a picture connects rather than reconnects"
    )

    print("PASS: Try Again names where the picture froze: the dropped connection or the ending")
}
