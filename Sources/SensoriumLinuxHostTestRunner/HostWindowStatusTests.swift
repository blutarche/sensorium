#if os(Linux)
import Foundation
import SensoriumLinuxHost

private let epoch = Date(timeIntervalSince1970: 0)

private func present(_ state: HostWindowState) -> HostWindowPresentation {
    HostWindowPresentation(state, now: epoch)
}


/// What the host window says about the machine as a whole: the status card's
/// words, and which controls sit under it.
@MainActor
enum HostWindowStatusTests {
    static let all: [(String, () async -> Void)] = [
        ("a host waiting for a machine shows READY and no Stop", testAWaitingHostShowsReadyAndNoStop),
        ("a live host-screen session names the device and the display and shows Stop", testALiveSessionNamesTheDeviceAndShowsStop),
        ("a pairing in progress names the device", testAPairingInProgressNamesTheDevice),
        ("a host that is not hosting says so without a code to show", testANotHostingHostSaysSo),
        ("a host that could not start says why under a warning eyebrow", testACouldNotStartHostSaysWhy),
        ("a stopped capture outranks everything and asks for a restart", testAStoppedCaptureOutranksEverything),
        ("a withdrawn screen sharing grant replaces the card and offers the button", testAWithdrawnGrantReplacesTheCardAndOffersTheButton),
        ("a withdrawn grant keeps the live session and its Stop", testAWithdrawnGrantKeepsTheLiveSessionAndItsStop),
        ("a request to pair is named while the host waits", testARequestToPairIsNamedWhileTheHostWaits),
        ("a desktop without layer shell says the screen cannot be offered and offers nothing", testAnUnsupportedDesktopOffersNothing)
    ]

    static func testAWaitingHostShowsReadyAndNoStop() async {
        let presentation = present(HostWindowState(status: .waiting))
        expect(presentation.card.eyebrow == "READY", "a waiting host's eyebrow is READY")
        expect(presentation.card.headline == "Waiting for a machine to connect.", "the headline says it is waiting")
        expect(presentation.card.detail.isEmpty, "a waiting host has no detail line")
        expect(!presentation.showsStop, "nobody is connected, so there is nothing to stop")
        expect(presentation.grantButtonTitle == nil, "an allowed host offers no grant button")
    }

    static func testALiveSessionNamesTheDeviceAndShowsStop() async {
        let presentation = present(HostWindowState(status: .sharing(deviceName: "Kestrel Laptop", displayName: "Display 1")))
        expect(presentation.card.eyebrow == "SHARING HOST SCREEN", "the eyebrow names the mode")
        expect(presentation.card.headline == "Connected to Kestrel Laptop", "the headline names the device")
        expect(
            presentation.card.detail == "It sees and controls Display 1 \u{2014} this machine\u{2019}s own screen.",
            "the detail says it is this machine's own screen"
        )
        expect(presentation.showsStop, "a live session offers Stop")
    }

    static func testAPairingInProgressNamesTheDevice() async {
        let presentation = present(HostWindowState(status: .pairing(deviceName: "Kestrel Laptop")))
        expect(presentation.card.eyebrow == "WAITING", "the eyebrow says the host is waiting")
        expect(presentation.card.headline == "Waiting for Kestrel Laptop to finish pairing.", "the headline names the device")
        expect(presentation.card.detail == "Code accepted. Kestrel Laptop is connecting.", "the detail says the code was accepted")
        expect(!presentation.showsStop, "a pairing is not a session")
    }

    static func testANotHostingHostSaysSo() async {
        let presentation = present(HostWindowState(status: .notHosting))
        expect(presentation.card.eyebrow == "STATUS", "the eyebrow is STATUS")
        expect(presentation.card.headline == "This machine is not hosting.", "the headline says it is not hosting")
        expect(presentation.card.detail == "No machine is connected.", "the detail says nobody is connected")
    }

    static func testACouldNotStartHostSaysWhy() async {
        let presentation = present(HostWindowState(status: .couldNotStart(
            headline: "Could not start hosting.", detail: "Another program is using the port."
        )))
        expect(presentation.card.eyebrow == "COULD NOT START", "the eyebrow says it could not start")
        expect(presentation.card.eyebrowIsWarning, "a failure's eyebrow is drawn in the warning colour")
        expect(presentation.card.headline == "Could not start hosting.", "the headline is the one handed in")
        expect(presentation.card.detail == "Another program is using the port.", "the detail is the one handed in")
    }

    static func testAStoppedCaptureOutranksEverything() async {
        var state = HostWindowState(status: .captureStopped, grant: .needed)
        state.pairing = .showing(code: "418297", expiresAt: epoch.addingTimeInterval(60), requestingDeviceName: nil)
        let presentation = present(state)
        expect(presentation.card.eyebrow == "CAPTURE STOPPED", "the eyebrow says capture stopped")
        expect(presentation.card.headline == "Quit Sensorium Host and open it again.", "the headline asks for a restart")
        expect(
            presentation.card.detail == "This machine has stopped handing Sensorium Host any picture to send. "
                + "Opening it again is the only thing that restores it.",
            "the detail explains the restart"
        )
        expect(presentation.card.eyebrowIsWarning, "the eyebrow is a warning")
    }

    static func testAWithdrawnGrantReplacesTheCardAndOffersTheButton() async {
        let presentation = present(HostWindowState(status: .waiting, grant: .needed))
        expect(presentation.card.eyebrow == "SCREEN SHARING NEEDED", "the eyebrow names the missing grant")
        expect(
            presentation.card.headline == "Screen sharing needs to be allowed again.",
            "the headline is the grant sentence"
        )
        expect(presentation.card.eyebrowIsWarning, "a missing grant is a warning")
        expect(!presentation.card.detail.contains("Mac"), "the Linux copy never says Mac")
        expect(presentation.grantButtonTitle == "Allow Screen Sharing", "the grant button starts the grant")
    }

    static func testAWithdrawnGrantKeepsTheLiveSessionAndItsStop() async {
        let presentation = present(HostWindowState(
            status: .sharing(deviceName: "Kestrel Laptop", displayName: "Display 1"), grant: .needed
        ))
        expect(presentation.card.headline == "Connected to Kestrel Laptop", "who is connected matters more mid-session")
        expect(presentation.showsStop, "Stop stays while a session is live")
        expect(presentation.grantButtonTitle == "Allow Screen Sharing", "the grant button still shows")
    }

    static func testARequestToPairIsNamedWhileTheHostWaits() async {
        var state = HostWindowState(status: .waiting)
        state.pairing = .showing(code: "418297", expiresAt: epoch.addingTimeInterval(60), requestingDeviceName: "Kestrel Laptop")
        let presentation = present(state)
        expect(presentation.card.headline == "Waiting for a machine to connect.", "the headline is unchanged")
        expect(presentation.card.detail == "Kestrel Laptop is asking to pair.", "the detail names who asks")

        var connected = HostWindowState(status: .sharing(deviceName: "Studio", displayName: "Display 1"))
        connected.pairing = state.pairing
        expect(
            present(connected).card.detail == "It sees and controls Display 1 \u{2014} this machine\u{2019}s own screen.",
            "a pairing request never overwrites a live session's claim"
        )
    }

    static func testAnUnsupportedDesktopOffersNothing() async {
        var state = HostWindowState(desktop: .unsupported, status: .waiting, grant: .needed)
        state.pairing = .showing(code: "418297", expiresAt: epoch.addingTimeInterval(60), requestingDeviceName: nil)
        let presentation = present(state)
        expect(presentation.card.eyebrow == "NOT SUPPORTED HERE", "the eyebrow names the state")
        expect(
            presentation.card.headline == "This desktop cannot share its screen.",
            "the headline says the screen cannot be offered here"
        )
        expect(!presentation.card.detail.isEmpty, "the detail says why in plain words")
        for word in ["GNOME", "Wayland", "layer", "protocol", "Mac"] {
            expect(!presentation.card.detail.contains(word), "the detail does not say \(word)")
        }
        expect(!presentation.showsStop, "nothing can be shared, so nothing can be stopped")
        expect(presentation.grantButtonTitle == nil, "a grant is no use on a desktop that cannot offer the screen")
    }
}
#endif
