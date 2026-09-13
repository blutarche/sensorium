import CoreGraphics
import Foundation
import SensoriumHost

/// A leftover virtual display that stays online but never goes active again
/// passes the active-list baseline check outright, because
/// `DisplayInventory.active()` never lists it at all. Catching that leak
/// needs a second comparison against the *online* list, exercised here
/// against fake before/after inventories so it needs no real display.
@MainActor
func runOnlineDisplayLeakDetectionTests() async {
    func fake(_ id: UInt32) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id,
            pixelWidth: 1920,
            pixelHeight: 1200,
            modeWidth: 1920,
            modeHeight: 1200,
            modePixelWidth: 3840,
            modePixelHeight: 2400,
            bounds: .zero,
            online: true,
            builtin: false,
            main: false,
            vendorNumber: 0,
            modelNumber: 0
        )
    }

    let builtin = fake(1)
    let leftoverCanvas = fake(99)

    expect(
        DisplayInventory.newlyOnlineIDs(baseline: [builtin], current: [builtin]) == [],
        "an unchanged online list reports no leak"
    )

    expect(
        DisplayInventory.newlyOnlineIDs(baseline: [builtin], current: [builtin, leftoverCanvas]) == [99],
        "a display online after release that was not online before is named as the leak"
    )

    expect(
        DisplayInventory.newlyOnlineIDs(baseline: [builtin, leftoverCanvas], current: [builtin]) == [],
        "a display that went offline is not a leak -- disappearing is exactly what release should do"
    )

    expect(
        DisplayInventory.newlyOnlineIDs(baseline: [], current: [leftoverCanvas]) == [99],
        "an empty baseline still names every display that turns up online afterward"
    )

    print("PASS: DisplayInventory.newlyOnlineIDs names the display a create/release cycle left online, ignoring pre-existing or since-vanished displays")
}
