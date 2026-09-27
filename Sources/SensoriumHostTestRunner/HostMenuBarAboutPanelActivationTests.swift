import AppKit
import Foundation
import SensoriumHost

/// "About Sensorium Host" from the status item opens the panel on a machine
/// that may not have this app active yet -- without bringing it to front
/// first, the panel draws behind whatever the person at this machine was
/// already looking at.
@MainActor
func runHostMenuBarAboutPanelActivationTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    var activateCount = 0
    let presence = HostMenuBarPresence(
        status: HostOperatorStatus(connection: .notHosting, permissions: granted),
        quit: {},
        activate: { activateCount += 1 }
    )
    presence.perform(NSSelectorFromString("openAboutPanel"))
    expect(activateCount == 1, "opening the About panel activates the app first, got \(activateCount) calls")

    print("PASS: About Sensorium Host brings the app to the front before showing its panel")
}
