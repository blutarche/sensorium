#if os(Linux)
import Foundation
import SensoriumLinuxHost

private let epoch = Date(timeIntervalSince1970: 1_000)

private func present(_ state: HostWindowState, at offset: TimeInterval = 0) -> HostWindowPresentation {
    HostWindowPresentation(state, now: epoch.addingTimeInterval(offset))
}

private func showing(_ code: String = "418297", for seconds: TimeInterval = 270) -> HostWindowState.Pairing {
    .showing(code: code, expiresAt: epoch.addingTimeInterval(seconds), requestingDeviceName: nil)
}

/// The pairing code, its countdown, and the two buttons that show and hide it.
@MainActor
enum HostWindowPairingTests {
    static let all: [(String, () async -> Void)] = [
        ("a code is shown in two groups of three with its countdown and hint", testACodeIsGroupedAndCountsDown),
        ("the countdown rounds up and turns urgent in the last half minute", testTheCountdownRoundsUpAndTurnsUrgent),
        ("an expired code is withdrawn and the Show button comes back", testAnExpiredCodeIsWithdrawn),
        ("Show Pairing Code is offered only when a code can be made", testShowPairingCodeIsOfferedOnlyWhenACodeCanBeMade),
        ("Show Pairing Code drops to an outline beside another filled button", testShowPairingCodeDropsToAnOutlineBesideAnotherFilledButton),
        ("a code that is not six digits is shown as it came", testACodeThatIsNotSixDigitsIsShownAsItCame)
    ]

    static func testACodeIsGroupedAndCountsDown() async {
        var state = HostWindowState(status: .waiting)
        state.pairing = showing()
        let pairing = present(state).pairing
        expect(pairing.code == "418 297", "six digits are read in threes")
        expect(pairing.countdown == "Expires in 4:30", "the countdown reads m:ss")
        expect(pairing.hint == "Type it on the machine you are pairing.", "the hint names which machine types it")
        expect(pairing.showsHideButton, "a code on screen can be hidden")
        expect(pairing.hideButtonTitle == "Hide Code", "the hide button's title")
        expect(!pairing.showsRevealButton, "the code replaces the Show button")
    }

    static func testTheCountdownRoundsUpAndTurnsUrgent() async {
        var state = HostWindowState(status: .waiting)
        state.pairing = showing(for: 0.2)
        let nearEnd = present(state).pairing
        expect(nearEnd.countdown == "Expires in 0:01", "a fraction of a second left never reads 0:00 while the code works")
        expect(nearEnd.countdownIsUrgent, "the last half minute is urgent")
        state.pairing = showing(for: 30.2)
        expect(present(state).pairing.countdown == "Expires in 0:31", "the countdown rounds up")
        state.pairing = showing(for: 31)
        expect(!present(state).pairing.countdownIsUrgent, "more than half a minute left is not urgent")
        state.pairing = showing(for: 30)
        expect(present(state).pairing.countdownIsUrgent, "exactly half a minute left is urgent")
    }

    static func testAnExpiredCodeIsWithdrawn() async {
        var state = HostWindowState(status: .waiting)
        state.pairing = showing(for: 60)
        let expired = present(state, at: 60).pairing
        expect(expired.code == nil, "a code with no time left is not shown")
        expect(expired.countdown == nil, "and has no countdown")
        expect(!expired.showsHideButton, "so there is nothing to hide")
        expect(expired.showsRevealButton, "the Show button returns")
        expect(present(state, at: 59).pairing.code == "418 297", "a code with a second left is still shown")
    }

    static func testShowPairingCodeIsOfferedOnlyWhenACodeCanBeMade() async {
        func reveals(_ status: HostWindowState.Status) -> Bool {
            present(HostWindowState(status: status)).pairing.showsRevealButton
        }
        expect(reveals(.waiting), "a waiting host can show a code")
        expect(reveals(.sharing(deviceName: "Studio", displayName: "Display 1")), "a live session does not stop the code being shown")
        expect(!reveals(.notHosting), "a host that is not hosting has no code to show")
        expect(!reveals(.pairing(deviceName: "Studio")), "a pairing already approved needs no second code")
    }

    static func testShowPairingCodeDropsToAnOutlineBesideAnotherFilledButton() async {
        expect(present(HostWindowState(status: .waiting)).pairing.revealIsFilled, "alone, the button is the accent fill")
        let connected = present(HostWindowState(status: .sharing(deviceName: "Studio", displayName: "Display 1")))
        expect(!connected.pairing.revealIsFilled, "beside Stop it is an outline, so two filled buttons never compete")
        let needsGrant = present(HostWindowState(status: .waiting, grant: .needed))
        expect(!needsGrant.pairing.revealIsFilled, "beside the grant button it is an outline")
    }

    static func testACodeThatIsNotSixDigitsIsShownAsItCame() async {
        var state = HostWindowState(status: .waiting)
        state.pairing = showing("12345")
        expect(present(state).pairing.code == "12345", "a code of another length is not split")
    }
}
#endif
