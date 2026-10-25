import Foundation
import SensoriumClient

/// The words and buttons of the session status panel: how a machine name
/// sits in a headline, where the end of a sentence may wrap, and which
/// buttons an ended session carries.
func testViewerStatusCopyTests() {
    let nbsp = "\u{00A0}"
    let longName = "Kestrel-Field-Station-Long-Range-Research-Notebook"
    let spacedName = "Kestrel Laptop"

    /// Every status the machine can reach for one host, with a reason line
    /// standing in for the copy the reason enums provide.
    func allStatuses(hostName: String) -> [ViewerSessionStatus] {
        let reasonLine = "The reason is stated here."
        var statuses: [ViewerSessionStatus] = []
        var machine = ViewerSessionStateMachine(hostName: hostName)
        statuses.append(machine.status)
        statuses.append(machine.handle(.connectStarted))
        statuses.append(machine.handle(.attemptFailed(reasonLine: reasonLine)))
        statuses.append(machine.handle(.canvasReady))
        statuses.append(machine.handle(.sessionEnded))
        statuses.append(machine.handle(.connectStarted))
        statuses.append(machine.handle(.attemptFailed(reasonLine: reasonLine)))
        statuses.append(machine.handle(.gaveUp))
        statuses.append(machine.handle(.stopRequested))
        statuses.append(machine.handle(.stoppedByHost(reasonLine: reasonLine)))
        statuses.append(machine.handle(.hostEnded(reasonLine: reasonLine)))
        statuses.append(machine.handle(.hostScreenConnectEnded(reasonLine: reasonLine)))
        statuses.append(machine.handle(.hostScreenConnectEnded(reasonLine: reasonLine, offersVirtualDisplay: true)))
        statuses.append(machine.handle(.unverifiedHostConnectEnded(reasonLine: reasonLine)))
        var neverLive = ViewerSessionStateMachine(hostName: hostName)
        statuses.append(neverLive.handle(.hostScreenConnectEnded(reasonLine: reasonLine)))
        return statuses
    }

    for name in [longName, spacedName] {
        let held = ViewerCopyWrapping.name(name)
        let statuses = allStatuses(hostName: name)
        for status in statuses {
            expect(
                !status.headline.contains(name),
                "a headline never carries the machine's own breakable name, got \"\(status.headline)\""
            )
        }
        let namedHeadlines = statuses.filter { $0.headline.contains(held) }
        expect(
            namedHeadlines.count >= 10,
            "every headline that names the machine carries the held form of \"\(name)\", only "
                + "\(namedHeadlines.count) did"
        )
    }

    for status in allStatuses(hostName: "Workstation") + allStatuses(hostName: longName) {
        expect(
            status.headline == ViewerCopyWrapping.keepingTailTogether(status.headline),
            "a headline's closing words stay together, got \"\(status.headline)\""
        )
        expect(
            status.detail == ViewerCopyWrapping.keepingTailTogether(status.detail),
            "a body's closing words stay together, got \"\(status.detail)\""
        )
    }

    var gaveUp = ViewerSessionStateMachine(hostName: "Workstation")
    gaveUp.handle(.connectStarted)
    gaveUp.handle(.canvasReady)
    let gaveUpDetail = gaveUp.handle(.gaveUp).detail
    expect(
        gaveUpDetail.contains("Check that Workstation is awake"),
        "the retry-stopped body names the machine to check, got \"\(gaveUpDetail)\""
    )
    expect(
        gaveUpDetail.contains("Try\(nbsp)Again."),
        "the control it sends the person to is never split, got \"\(gaveUpDetail)\""
    )

    // One checklist for "this machine cannot be reached", whether the panel is
    // still trying or has stopped.
    let checklist = ViewerSessionFailureCopy.reachabilityChecklist(hostLabel: "Workstation")
    expect(
        unbound(checklist) == "Check that Workstation is awake, and that both machines are on the same network "
            + "or have Tailscale connected",
        "the checklist names the machine and the two things to check, got \"\(unbound(checklist))\""
    )
    expect(
        gaveUpDetail.contains(checklist),
        "the retry-stopped body carries the shared checklist, got \"\(gaveUpDetail)\""
    )
    let unreachablePanelLine = ViewerSessionFailureCopy.panelLine(for: .unreachable, hostLabel: "Workstation")
    expect(
        unbound(unreachablePanelLine) == "Could not reach Workstation. \(unbound(checklist)).",
        "an unreachable attempt reads as one failure sentence then the shared checklist, got "
            + "\"\(unbound(unreachablePanelLine))\""
    )
    expect(
        !unreachablePanelLine.contains(".local") && !unreachablePanelLine.contains("Nothing answered"),
        "the panel line drops the address and Sensorium Host tips the terminal line keeps"
    )
    expect(
        ViewerSessionFailureCopy.panelLine(for: .unknown, hostLabel: "Workstation")
            == ViewerSessionFailureCopy.line(for: .unknown, hostLabel: "Workstation"),
        "every failure other than an unreachable one reads the same in the panel as anywhere else"
    )
    var retrying = ViewerSessionStateMachine(hostName: "Workstation")
    retrying.handle(.connectStarted)
    let retryingDetail = retrying.handle(.attemptFailed(reasonLine: unreachablePanelLine)).detail
    expect(
        unbound(retryingDetail) == "\(unbound(unreachablePanelLine)) Sensorium is trying again.",
        "a failed first attempt shows the failure, then says Sensorium is trying again, got "
            + "\"\(unbound(retryingDetail))\""
    )
    expect(
        !retryingDetail.contains("Attempt 1 did not connect"),
        "and no longer opens with the attempt count, got \"\(retryingDetail)\""
    )

    // A first connect with no failure yet has nothing to cancel; once an
    // attempt has failed and Sensorium is trying again, Cancel stops it, as it
    // does while reconnecting.
    var plainFirstConnect = ViewerSessionStateMachine(hostName: "Workstation")
    expect(
        plainFirstConnect.handle(.connectStarted).buttons.map(\.title) == ["Quit Sensorium", "Your Machines"],
        "the first connecting panel, with no failure yet, offers Quit and Your Machines only"
    )
    let retryingStatus = plainFirstConnect.handle(.attemptFailed(reasonLine: unreachablePanelLine))
    expect(
        retryingStatus.phase == .connecting
            && retryingStatus.buttons.map(\.action) == [.quit, .stopTrying, .yourMachines]
            && retryingStatus.buttons.map(\.title) == ["Quit Sensorium", "Cancel", "Your Machines"]
            && retryingStatus.buttons.allSatisfy { !$0.isPrimary },
        "the connecting panel that says Sensorium is trying again offers Quit, Cancel, Your Machines in that "
            + "order, none of them the default, got \(retryingStatus.buttons.map(\.title))"
    )
    expect(
        ViewerSessionStateMachine.buttonRows.contains(retryingStatus.buttons.map(\.title)),
        "and it is the row the reconnecting panel already carries, so the panel is not sized for a new one"
    )
    let redialled = plainFirstConnect.handle(.connectStarted)
    expect(
        redialled.phase == .connecting && redialled.buttons.map(\.action) == [.quit, .stopTrying, .yourMachines],
        "Cancel does not vanish while the next attempt is under way, got \(redialled.buttons.map(\.title))"
    )
    let cancelled = plainFirstConnect.handle(.stopRequested)
    expect(
        cancelled.phase == .lost && cancelled.eyebrow == "STOPPED"
            && cancelled.buttons.map(\.action) == [.quit, .yourMachines, .tryAgain]
            && cancelled.buttons.last?.isPrimary == true,
        "Cancel from a retry leaves the not-connected panel with Try Again as its default, got "
            + "\(cancelled.phase) / \(cancelled.eyebrow) / \(cancelled.buttons.map(\.title))"
    )
    expect(
        unbound(cancelled.detail).contains("Nothing is being retried now.")
            && !unbound(cancelled.detail).contains(unbound(unreachablePanelLine)),
        "and says nothing is being retried, without repeating the failure it stopped, got \"\(cancelled.detail)\""
    )
    let again = plainFirstConnect.handle(.retryRequested)
    expect(
        again.phase == .connecting && again.buttons.map(\.title) == ["Quit Sensorium", "Your Machines"],
        "Try Again after that starts a fresh first connect, with no failure to cancel yet, got "
            + "\(again.phase) / \(again.buttons.map(\.title))"
    )

    // A window that was live on one target and then asked for a host screen
    // that never came up has not ended a host-screen session.
    var liveThenRefused = ViewerSessionStateMachine(hostName: "Workstation")
    liveThenRefused.handle(.connectStarted)
    liveThenRefused.handle(.canvasReady)
    let neverCameUp = liveThenRefused.handle(
        .hostScreenConnectEnded(reasonLine: "The reason is stated here.", screenNeverCameUp: true)
    )
    expect(
        neverCameUp.eyebrow == "NOT STARTED"
            && unbound(neverCameUp.headline) == "Could not show a host screen from Workstation.",
        "a host screen that never came up reads as not started even in a window that was live before, got "
            + "\(neverCameUp.eyebrow) / \(unbound(neverCameUp.headline))"
    )
    let endedAfterLive = liveThenRefused.handle(.hostScreenConnectEnded(reasonLine: "The reason is stated here."))
    expect(
        endedAfterLive.eyebrow == "SESSION ENDED"
            && unbound(endedAfterLive.headline) == "The host-screen session with Workstation ended.",
        "a host-screen session that was showing and then ended still reads as ended, got "
            + "\(endedAfterLive.eyebrow) / \(unbound(endedAfterLive.headline))"
    )

    expect(
        HostScreenRefusalCopy.screenNeverCameUp(reason: HostScreenRefusalCopy.retryNeedsPersonReason),
        "a redial that never reached the host is a host screen that never came up"
    )
    expect(
        !HostScreenRefusalCopy.screenNeverCameUp(reason: "host-screen-resume-refused")
            && !HostScreenRefusalCopy.screenNeverCameUp(reason: "host-screen-presence-declined"),
        "a refused resume names a session that was up, and the other refusals keep the reading they had"
    )

    var offered = ViewerSessionStateMachine(hostName: "Workstation")
    let offeredStatus = offered.handle(.hostScreenConnectEnded(reasonLine: "Nothing to share.", offersVirtualDisplay: true))
    expect(
        offeredStatus.buttons.map(\.title) == [
            "Quit Sensorium", "Connect to a Private Desktop", "Your Machines", "Try Again"
        ],
        "an offered private desktop sits between Quit and the list, with Try Again last, got "
            + "\(offeredStatus.buttons.map(\.title))"
    )
    expect(
        offeredStatus.buttons.map(\.action) == [.quit, .connectAsVirtualDisplay, .yourMachines, .tryAgain],
        "each button keeps its own action, got \(offeredStatus.buttons.map(\.action))"
    )
    expect(
        offeredStatus.buttons.map(\.isPrimary) == [false, false, false, true],
        "and Try Again is the one default, got \(offeredStatus.buttons.map(\.isPrimary))"
    )
    expect(
        ViewerSessionStateMachine.buttonRows.contains([
            "Quit Sensorium", "Connect to a Private Desktop", "Your Machines", "Try Again"
        ]),
        "the panel is sized for that row"
    )
    let privateDesktopSentence = "Workstation offers a private desktop instead: a separate desktop that isn\u{2019}t shown on its screens."
    var offeredNoScreen = ViewerSessionStateMachine(hostName: "Workstation")
    let offeredNoScreenStatus = offeredNoScreen.handle(.hostScreenConnectEnded(
        reasonLine: HostScreenRefusalCopy.line(
            reason: HostScreenRefusalCopy.noneAvailableReason, hostLabel: "Workstation"
        ),
        offersVirtualDisplay: true
    ))
    expect(
        unbound(offeredNoScreenStatus.detail)
            == "Workstation has no screen to share right now. Trying again asks for its screen once more. "
                + privateDesktopSentence,
        "a panel that offers Connect to a Private Desktop says what that is, after the reason, got "
            + "\"\(unbound(offeredNoScreenStatus.detail))\""
    )
    var notOffered = ViewerSessionStateMachine(hostName: "Workstation")
    let notOfferedStatus = notOffered.handle(.hostScreenConnectEnded(
        reasonLine: HostScreenRefusalCopy.line(
            reason: HostScreenRefusalCopy.noneAvailableReason, hostLabel: "Workstation"
        ),
        offersVirtualDisplay: false
    ))
    expect(
        unbound(notOfferedStatus.detail)
            == "Workstation has no screen to share right now. Trying again asks for its screen once more.",
        "a panel that does not offer it adds nothing, got \"\(unbound(notOfferedStatus.detail))\""
    )

    print("PASS: the status panel holds names whole, keeps sentence ends together and offers Quit on every row")
}
