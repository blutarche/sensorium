#if os(macOS)
import AppKit
import CoreGraphics

extension DisplayInventory {
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
                serialNumber: CGDisplaySerialNumber(id),
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
#endif
