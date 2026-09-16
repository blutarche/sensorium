import AppKit
import CoreGraphics

public struct DisplaySnapshot: Equatable, Hashable, Sendable {
    public let id: UInt32
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let modeWidth: Int
    public let modeHeight: Int
    public let modePixelWidth: Int
    public let modePixelHeight: Int
    public let bounds: CGRect
    public let online: Bool
    /// `CGDisplayIsAsleep` -- online, physically present, but showing
    /// nothing right now. `CGGetActiveDisplayList` omits a display in this
    /// state; `CGGetOnlineDisplayList` does not, which is the whole reason
    /// `DisplayInventory.online()` exists: a display that slept through a
    /// read must still be seen and named, not treated as gone.
    public let asleep: Bool
    /// `CGDisplayMirrorsDisplay`, or `0` (`kCGNullDirectDisplay`) when this
    /// display is not a mirror of another. A mirrored secondary shows
    /// another display's picture, never its own, so it is never a
    /// legitimate host-screen target even though it is online.
    public let mirrorsDisplay: UInt32
    public let builtin: Bool
    public let main: Bool
    /// The EDID vendor and model CoreGraphics reports for this display. A
    /// canvas Sensorium created reports `CanvasDisplayIdentity`'s pair back.
    public let vendorNumber: UInt32
    public let modelNumber: UInt32
    /// `NSScreen.localizedName` for this display, when macOS can match a
    /// screen to this id -- a canvas Sensorium created, or a display no
    /// screen in `NSScreen.screens` currently claims, leaves this `nil`.
    public let name: String?

    public init(
        id: UInt32,
        pixelWidth: Int,
        pixelHeight: Int,
        modeWidth: Int,
        modeHeight: Int,
        modePixelWidth: Int,
        modePixelHeight: Int,
        bounds: CGRect,
        online: Bool,
        asleep: Bool = false,
        mirrorsDisplay: UInt32 = 0,
        builtin: Bool,
        main: Bool,
        vendorNumber: UInt32,
        modelNumber: UInt32,
        name: String? = nil
    ) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.modeWidth = modeWidth
        self.modeHeight = modeHeight
        self.modePixelWidth = modePixelWidth
        self.modePixelHeight = modePixelHeight
        self.bounds = bounds
        self.online = online
        self.asleep = asleep
        self.mirrorsDisplay = mirrorsDisplay
        self.builtin = builtin
        self.main = main
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.name = name
    }
}

public enum DisplayInventory {
    public static func active() -> [DisplaySnapshot] {
        snapshot(of: CGGetActiveDisplayList)
    }

    /// `CGGetActiveDisplayList` omits a display CoreGraphics still considers
    /// online but not currently active -- exactly the state a virtual
    /// display leaks into if its release did not actually tear it down.
    /// Only this list can see one.
    public static func online() -> [DisplaySnapshot] {
        snapshot(of: CGGetOnlineDisplayList)
    }

    /// Display IDs present in `current` that were absent from `baseline` --
    /// the specific display a create/release cycle left behind, as opposed
    /// to one that was already online before the cycle started.
    public static func newlyOnlineIDs(baseline: [DisplaySnapshot], current: [DisplaySnapshot]) -> [UInt32] {
        let baselineIDs = Set(baseline.map { $0.id })
        return current.map { $0.id }.filter { !baselineIDs.contains($0) }.sorted()
    }

    private static func snapshot(
        of list: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError
    ) -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard list(0, nil, &count) == .success else {
            return []
        }

        var ids = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard list(count, &ids, &count) == .success else {
            return []
        }

        let names = localizedNamesByDisplayID()
        return ids.map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplaySnapshot(
                id: id,
                pixelWidth: CGDisplayPixelsWide(id),
                pixelHeight: CGDisplayPixelsHigh(id),
                modeWidth: mode.map { $0.width } ?? 0,
                modeHeight: mode.map { $0.height } ?? 0,
                modePixelWidth: mode.map { $0.pixelWidth } ?? 0,
                modePixelHeight: mode.map { $0.pixelHeight } ?? 0,
                bounds: CGDisplayBounds(id),
                online: CGDisplayIsOnline(id) != 0,
                asleep: CGDisplayIsAsleep(id) != 0,
                mirrorsDisplay: CGDisplayMirrorsDisplay(id),
                builtin: CGDisplayIsBuiltin(id) != 0,
                main: CGDisplayIsMain(id) != 0,
                vendorNumber: CGDisplayVendorNumber(id),
                modelNumber: CGDisplayModelNumber(id),
                name: names[id]
            )
        }
    }

    /// `NSScreen` has no `CGDirectDisplayID` of its own; the only way to
    /// match one to a screen is the `NSScreenNumber` device description key
    /// Apple documents for exactly this purpose.
    private static func localizedNamesByDisplayID() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return names
    }
}
