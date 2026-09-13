import AppKit
import Foundation
import SensoriumHost

/// Every launcher sentence that names the host reads that name from the
/// view's own `hostName`, so the empty-catalog subtext and a failed launch
/// can never name two different machines on one panel.
@MainActor
func runCanvasLauncherHostNameTests() async {
    let placement = CanvasHostTestHooks.placementForTesting(displayID: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200))
    let hostName = "Kestrel Mac mini"
    let texts = CanvasHostTestHooks.launcherHostNameTexts(
        frame: NSRect(x: 0, y: 0, width: 440, height: 1104),
        canvas: placement,
        hostName: hostName
    )

    expect(
        texts.emptyStateSubtext.contains(hostName),
        "the empty-catalog subtext names the machine from the view's own hostName -- got: \(texts.emptyStateSubtext)"
    )
    expect(
        texts.launchFailedStatus.contains(hostName),
        "a failed launch's status names the machine from the view's own hostName -- got: \(texts.launchFailedStatus)"
    )

    print("PASS: the launcher's empty-catalog subtext and its launch-failed status both name the machine from one stored hostName")
}
