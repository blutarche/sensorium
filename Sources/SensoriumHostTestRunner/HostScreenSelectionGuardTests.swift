import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// One bit per obligation of docs/host-screen-design.md §5.4, so a test
/// scenario can be built by naming exactly which ones are unmet rather than
/// hand-assembling six independent fixtures per case.
private struct BrokenObligation: OptionSet {
    let rawValue: Int
    static let deviceArmed = BrokenObligation(rawValue: 1 << 0)
    static let displayArmed = BrokenObligation(rawValue: 1 << 1)
    static let tokenMinted = BrokenObligation(rawValue: 1 << 2)
    static let displayGone = BrokenObligation(rawValue: 1 << 3)
    static let vendorID = BrokenObligation(rawValue: 1 << 4)
    static let preSession = BrokenObligation(rawValue: 1 << 5)

    static let all: [BrokenObligation] = [.deviceArmed, .displayArmed, .tokenMinted, .displayGone, .vendorID, .preSession]
}

private func guardDisplay(id: UInt32, identity: HostScreenDisplayIdentity) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 2560,
        pixelHeight: 1440,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 2560,
        modePixelHeight: 1440,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: identity.vendorNumber,
        modelNumber: identity.modelNumber
    )
}

/// Builds a scenario that is admissible when `breaking` is empty, and fails
/// exactly the obligations named in `breaking` when it is not -- each flag
/// touches only its own piece of the fixture, so any combination composes
/// without one flag accidentally masking or repairing another.
private func guardScenario(breaking: BrokenObligation) -> (
    deviceKey: Data,
    token: Data,
    mintedTokens: [Data: HostScreenDisplayIdentity],
    arming: HostScreenArming,
    currentDisplays: [DisplaySnapshot],
    preSessionSnapshot: [DisplaySnapshot]
) {
    let deviceKey = Data([0x10, 0x20, 0x30])
    let mintedToken = Data([0xAA, 0xBB, 0xCC])
    let requestedToken = breaking.contains(.tokenMinted) ? Data([0xFF, 0xFF, 0xFF]) : mintedToken

    let identity = breaking.contains(.vendorID)
        ? HostScreenDisplayIdentity(vendorNumber: CanvasDisplayIdentity.vendorID, modelNumber: 1)
        : HostScreenDisplayIdentity(vendorNumber: 1552, modelNumber: 40)

    let arming = breaking.contains(.deviceArmed)
        ? HostScreenArming()
        : HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: breaking.contains(.displayArmed) ? [] : [identity],
                armedAt: Date()
            )
        ])

    let live = guardDisplay(id: 7, identity: identity)
    let currentDisplays = breaking.contains(.displayGone) ? [] : [live]
    let preSessionSnapshot = breaking.contains(.preSession) ? [] : [live]

    return (
        deviceKey: deviceKey,
        token: requestedToken,
        mintedTokens: [mintedToken: identity],
        arming: arming,
        currentDisplays: currentDisplays,
        preSessionSnapshot: preSessionSnapshot
    )
}

private func admit(_ breaking: BrokenObligation) -> Result<UInt32, HostScreenSelectionRefusal> {
    let scenario = guardScenario(breaking: breaking)
    return HostScreenSelectionGuard.admit(
        deviceKey: scenario.deviceKey,
        token: scenario.token,
        mintedTokens: scenario.mintedTokens,
        arming: scenario.arming,
        currentDisplays: scenario.currentDisplays,
        preSessionSnapshot: scenario.preSessionSnapshot
    )
}

@MainActor
func runHostScreenSelectionGuardTests() async {
    do {
        // All six obligations met: the only shape that admits.
        let result = admit([])
        expect(result == .success(7), "a display that is armed, minted, present, not a canvas, and in the pre-session snapshot is admitted with its live display ID")

        print("PASS: HostScreenSelectionGuard admits a display only when every one of the six obligations holds")
    }

    do {
        // Each obligation, broken alone, produces exactly its own named
        // refusal -- design §12's "a distinct typed refusal for each".
        let expected: [(BrokenObligation, HostScreenSelectionRefusal)] = [
            (.deviceArmed, .deviceNotArmed),
            (.displayArmed, .displayNotArmed),
            (.tokenMinted, .tokenNotMinted),
            (.displayGone, .displayGone),
            (.vendorID, .displayIsSensoriumCanvas),
            (.preSession, .displayAbsentFromPreSessionSnapshot)
        ]
        for (broken, reason) in expected {
            expect(admit(broken) == .failure(reason), "breaking only \(broken) refuses with exactly \(reason), no other obligation's reason")
        }

        print("PASS: each of the six obligations, broken alone, produces its own distinct refusal")
    }

    do {
        // The property that matters: a refusal is a refusal, never a
        // reduced admission. Every non-empty combination of broken
        // obligations -- all 63 of them -- refuses. None ever returns
        // .success, because .success carries a display ID and a display ID
        // is exactly what "no input yields ... without all six" forbids
        // when even one obligation is unmet.
        var admittedDespiteAFault = 0
        var casesChecked = 0
        for rawValue in 1..<64 {
            let breaking = BrokenObligation(rawValue: rawValue)
            casesChecked += 1
            switch admit(breaking) {
            case .success:
                admittedDespiteAFault += 1
            case .failure:
                break
            }
        }
        expect(casesChecked == 63, "every non-empty combination of the six obligations was exercised")
        expect(admittedDespiteAFault == 0, "no combination of unmet obligations -- one, several, or all six -- ever produces a display ID; the guard refuses the whole request, it does not degrade to a partial one")

        print("PASS: none of the 63 combinations of unmet obligations admits a display, so no input reduces a refusal to a session")
    }
}
