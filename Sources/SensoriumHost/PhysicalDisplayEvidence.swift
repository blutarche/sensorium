import Foundation

/// Whether the baseline a preflight is about to disturb contains a display
/// this process did not create.
///
/// A count of active displays is not evidence: virtual displays are counted the
/// same way, so a machine whose only screens are Sensorium canvases would
/// satisfy a count-based check and produce a meaningless "physical baseline
/// preserved" result.
///
/// The evidence is the display's own identity. Sensorium stamps
/// `CanvasDisplayIdentity.vendorID` into every canvas it creates and
/// `CGDisplayVendorNumber` reads it straight back, so a display not carrying
/// that vendor is one Sensorium did not create. That is a narrower claim than
/// "a monitor is attached" -- a third-party virtual display driver would also
/// read as not-ours -- but it is the claim the guard needs: preservation is only
/// provable against something the preflight is not itself responsible for.
public struct PhysicalDisplayEvidence: Equatable, Sendable {
    public let physicalDisplayCount: Int
    public let activeDisplayCount: Int

    public init(physicalDisplayCount: Int, activeDisplayCount: Int) {
        self.physicalDisplayCount = physicalDisplayCount
        self.activeDisplayCount = activeDisplayCount
    }

    public init(displays: [DisplaySnapshot]) {
        self.init(
            physicalDisplayCount: displays.filter { !Self.isSensoriumCanvas($0) }.count,
            activeDisplayCount: displays.count
        )
    }

    /// Matched on the vendor alone. The ID is Sensorium's own, so any display
    /// carrying it came from this project; also requiring the product ID would
    /// let a canvas with some later product ID count as physical, which weakens
    /// the refusal in exactly the direction that makes a preservation result
    /// vacuous.
    public static func isSensoriumCanvas(_ display: DisplaySnapshot) -> Bool {
        display.vendorNumber == CanvasDisplayIdentity.vendorID
    }

    /// The EDID vendor ('unkn') and model ('virt') macOS reported for the
    /// display it keeps online while no monitor is drawing, observed on a
    /// Mac mini whose monitors display sleep had taken offline. It reads
    /// awake, so `CGDisplayIsAsleep` cannot tell that the monitors are off.
    public static let headlessStandInVendor: UInt32 = 0x756E_6B6E
    public static let headlessStandInModel: UInt32 = 0x7669_7274

    public static func isHeadlessStandIn(_ display: DisplaySnapshot) -> Bool {
        display.vendorNumber == headlessStandInVendor && display.modelNumber == headlessStandInModel
    }

    public var hasPhysicalDisplay: Bool {
        physicalDisplayCount > 0
    }

    /// Preservation is only testable when a display we did not create exists
    /// *and* the canvas about to be created is not the only thing on screen.
    public var isPreservationTestable: Bool {
        hasPhysicalDisplay && activeDisplayCount >= 2
    }
}
