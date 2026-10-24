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
        gaveUpDetail.hasSuffix("choose\(nbsp)Try\(nbsp)Again.") || gaveUpDetail.hasSuffix("Try\(nbsp)Again."),
        "the control it sends the person to is never split, got \"\(gaveUpDetail)\""
    )

    var offered = ViewerSessionStateMachine(hostName: "Workstation")
    let offeredStatus = offered.handle(.hostScreenConnectEnded(reasonLine: "Nothing to share.", offersVirtualDisplay: true))
    expect(
        offeredStatus.buttons.map(\.title) == ["Quit Sensorium", "Connect to a Private Desktop", "Your Machines"],
        "an offered private desktop sits between Quit and the Your Machines default, got "
            + "\(offeredStatus.buttons.map(\.title))"
    )
    expect(
        offeredStatus.buttons.map(\.isPrimary) == [false, false, true],
        "and Your Machines stays the one default, got \(offeredStatus.buttons.map(\.isPrimary))"
    )
    expect(
        ViewerSessionStateMachine.buttonRows.contains(["Quit Sensorium", "Connect to a Private Desktop", "Your Machines"]),
        "the panel is sized for that row"
    )

    print("PASS: the status panel holds names whole, keeps sentence ends together and offers Quit on every row")
}
