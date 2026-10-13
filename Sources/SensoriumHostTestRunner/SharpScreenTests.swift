import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// The sharp screen's identity, and the display-list checks that decide when a
/// session replaces macOS's placeholder screen and when a sharp screen is
/// offered in its place. Pure functions of a display list; no display is
/// created or changed.

/// macOS's own placeholder screen as a headless host reports it: the
/// 'unkn'/'virt' pair, no name, 1920x1080 at 1x, one mode.
func placeholderSnapshot(id: UInt32) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 1920,
        pixelHeight: 1080,
        modeWidth: 1920,
        modeHeight: 1080,
        modePixelWidth: 1920,
        modePixelHeight: 1080,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        online: true,
        builtin: false,
        main: true,
        vendorNumber: PhysicalDisplayEvidence.headlessStandInVendor,
        modelNumber: PhysicalDisplayEvidence.headlessStandInModel
    )
}

func monitorSnapshot(id: UInt32, asleep: Bool = false) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        online: true,
        asleep: asleep,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40,
        name: "Studio Monitor"
    )
}

func canvasSnapshot(id: UInt32) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 3840,
        pixelHeight: 2400,
        modeWidth: 1920,
        modeHeight: 1200,
        modePixelWidth: 3840,
        modePixelHeight: 2400,
        bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1200),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: CanvasDisplayIdentity.vendorID,
        modelNumber: CanvasDisplayIdentity.productID
    )
}

/// A sharp screen as macOS reports it once it is up: Sensorium's vendor and
/// the sharp screen's serial, 1920x1080 points at 2x, and the name it was
/// created with.
func sharpScreenSnapshot(id: UInt32, online: Bool = true, pixelScale: Int = 2) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 1920 * pixelScale,
        pixelHeight: 1080 * pixelScale,
        modeWidth: 1920,
        modeHeight: 1080,
        modePixelWidth: 1920 * pixelScale,
        modePixelHeight: 1080 * pixelScale,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        online: online,
        builtin: false,
        main: true,
        vendorNumber: CanvasDisplayIdentity.vendorID,
        modelNumber: CanvasDisplayIdentity.productID,
        serialNumber: SharpScreen.identity.serialNumber,
        name: "Sensorium Sharp Screen"
    )
}

@MainActor
func runSharpScreenTests() async {
    do {
        let sharp = SharpScreen.identity
        expect(
            sharp.vendorID == CanvasDisplayIdentity.vendorID && sharp.productID == CanvasDisplayIdentity.productID,
            "the sharp screen carries Sensorium's own vendor and product, so every check that knows a Sensorium display knows it too"
        )
        for surface in CanvasSurfaceID.allCases {
            for purpose in [CanvasPurpose.session, .capabilityProbe] {
                expect(
                    !CanvasIdentityFallback.identities(for: surface, purpose: purpose)
                        .contains { $0.serialNumber == sharp.serialNumber },
                    "the sharp screen's serial is never one a canvas presents, got \(sharp.serialNumber)"
                )
            }
        }
        let remainder = sharp.serialNumber % CanvasDisplayIdentity.attemptStride
        expect(
            !(1...UInt32(CanvasSurfaceID.capacity)).contains(remainder),
            "no canvas attempt of any surface can ever reach the sharp screen's serial, got remainder \(remainder)"
        )
    }
    print("PASS: the sharp screen has a fixed identity of its own, which no canvas identity can ever take")

    do {
        let placeholder = placeholderSnapshot(id: 4)
        expect(
            SharpScreen.isPlaceholder(placeholder, among: [placeholder]),
            "macOS's placeholder screen, alone, is a placeholder a host-screen session replaces"
        )
        expect(
            !SharpScreen.isPlaceholder(placeholder, among: [placeholder, monitorSnapshot(id: 2)]),
            "a placeholder beside a monitor is never replaced"
        )
        expect(
            !SharpScreen.isPlaceholder(placeholder, among: [placeholder, monitorSnapshot(id: 2, asleep: true)]),
            "a placeholder beside a sleeping monitor is never replaced: the monitor is still there"
        )
        expect(
            !SharpScreen.isPlaceholder(placeholder, among: [placeholder, canvasSnapshot(id: 91)]),
            "a placeholder that is not the only online display is never replaced, even beside a canvas"
        )
        let offline = DisplaySnapshot(
            id: 4, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: .zero, online: false,
            builtin: false, main: false,
            vendorNumber: PhysicalDisplayEvidence.headlessStandInVendor,
            modelNumber: PhysicalDisplayEvidence.headlessStandInModel
        )
        expect(!SharpScreen.isPlaceholder(offline, among: [offline]), "an offline placeholder is never replaced")
        let monitor = monitorSnapshot(id: 2)
        expect(!SharpScreen.isPlaceholder(monitor, among: [monitor]), "a monitor alone is never replaced")
        let canvasClaimingPlaceholderModel = DisplaySnapshot(
            id: 5, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), online: true,
            builtin: false, main: true,
            vendorNumber: CanvasDisplayIdentity.vendorID,
            modelNumber: PhysicalDisplayEvidence.headlessStandInModel
        )
        expect(
            !SharpScreen.isPlaceholder(canvasClaimingPlaceholderModel, among: [canvasClaimingPlaceholderModel]),
            "a display Sensorium created is never taken for the placeholder"
        )
        expect(
            !SharpScreen.isPlaceholder(placeholder, among: []),
            "a placeholder missing from the very list it is checked against is never replaced"
        )
        expect(SharpScreen.placeholder(among: [placeholder]) == placeholder, "the single placeholder is found")
        expect(
            SharpScreen.placeholder(among: [placeholder, placeholderSnapshot(id: 6)]) == nil,
            "two placeholders at once is not the single placeholder this replaces"
        )
        expect(SharpScreen.placeholder(among: [monitor]) == nil, "a monitor is not found as the placeholder")
    }
    print("PASS: only macOS's placeholder screen, alone, online and with no monitor beside it, reads as the placeholder a session replaces")

    do {
        let sharp = sharpScreenSnapshot(id: 9)
        expect(SharpScreen.isSharpScreen(sharp), "a display with Sensorium's vendor and the sharp screen's serial is a sharp screen")
        expect(!SharpScreen.isSharpScreen(canvasSnapshot(id: 91)), "a session canvas is not a sharp screen")
        expect(
            HostScreenOfferEligibility.offerGapReason(for: sharp, among: [sharp]) == nil,
            "a sharp screen that is the only online display is offered, whether this process made it or an earlier host left it behind"
        )
        expect(
            HostScreenOfferEligibility.offerGapReason(for: sharp, among: [sharp, monitorSnapshot(id: 2)]) == .createdBySensorium,
            "a sharp screen beside a monitor is never offered"
        )
        expect(
            HostScreenOfferEligibility.offerGapReason(for: sharp, among: [sharp, canvasSnapshot(id: 91)]) == .createdBySensorium,
            "a sharp screen beside a canvas is not the only online display, so it is not offered"
        )
        let canvas = canvasSnapshot(id: 91)
        expect(
            HostScreenOfferEligibility.offerGapReason(for: canvas, among: [canvas]) == .createdBySensorium,
            "a session canvas is never offered, even alone"
        )
        expect(
            HostScreenArmingPresentation.displayLabel(for: sharp) == "External Display",
            "a sharp screen is offered under the placeholder's own label, never its creation name, got \(HostScreenArmingPresentation.displayLabel(for: sharp))"
        )
        expect(
            HostScreenDisplayIdentity(sharp) == HostScreenDisplayIdentity(placeholderSnapshot(id: 4)),
            "a sharp screen answers to the placeholder's identity, so a viewer that chose the placeholder finds it again"
        )
        expect(
            HostScreenDisplayIdentity(canvas) != HostScreenDisplayIdentity(placeholderSnapshot(id: 4)),
            "a session canvas keeps its own identity"
        )
    }
    print("PASS: a sharp screen alone is offered as the placeholder would be, and nothing else Sensorium created is")

    do {
        let deviceKey = Data(repeating: 7, count: 32)
        let offerToken = Data(repeating: 1, count: 16)
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(devicePublicKey: deviceKey, deviceName: "Kestrel Laptop Pro", armedAt: Date())
        ])
        let placeholderIdentity = HostScreenDisplayIdentity(placeholderSnapshot(id: 4))
        let sharp = sharpScreenSnapshot(id: 9)
        expect(
            HostScreenSelectionGuard.admit(
                deviceKey: deviceKey, token: offerToken, mintedTokens: [offerToken: placeholderIdentity],
                arming: arming, currentDisplays: [sharp]
            ) == .success(9),
            "a token minted for the placeholder admits the sharp screen standing in for it"
        )
        expect(
            HostScreenSelectionGuard.admit(
                deviceKey: deviceKey, token: offerToken, mintedTokens: [offerToken: placeholderIdentity],
                arming: arming, currentDisplays: [sharp, monitorSnapshot(id: 2)]
            ) == .failure(.displayIsSensoriumCanvas),
            "a sharp screen beside a monitor is refused as a display Sensorium created"
        )
        let canvas = canvasSnapshot(id: 91)
        expect(
            HostScreenSelectionGuard.admit(
                deviceKey: deviceKey, token: offerToken, mintedTokens: [offerToken: HostScreenDisplayIdentity(canvas)],
                arming: arming, currentDisplays: [canvas]
            ) == .failure(.displayIsSensoriumCanvas),
            "a session canvas is still refused, even alone"
        )
    }
    print("PASS: host-screen admission allows a sharp screen alone and refuses every other display Sensorium created")

    do {
        let list = FakeDisplayList([sharpScreenSnapshot(id: 9)])
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { list.read() }, wait: { _ in })
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        guard case let .hostScreenList(entries, _) = try! controller.offerHostScreenList() else {
            expect(false, "an armed connection is offered a list")
            return
        }
        expect(entries.count == 1, "the leftover sharp screen is offered, got \(entries.count) entries")
        expect(entries.first?.label == "External Display", "under the placeholder's label, got \(entries.first?.label ?? "none")")
        expect(
            entries.first?.displayIdentity == HostScreenDisplayIdentity(placeholderSnapshot(id: 4)).wireStableIdentifier,
            "and the placeholder's identity, got \(entries.first?.displayIdentity ?? "none")"
        )
        expect(
            entries.first?.logicalWidth == 1920 && entries.first?.logicalHeight == 1080 && entries.first?.backingScale == 2,
            "at its own 2x geometry"
        )
    }
    print("PASS: a sharp screen an earlier host left behind is offered as External Display when it is the only online display")
}
