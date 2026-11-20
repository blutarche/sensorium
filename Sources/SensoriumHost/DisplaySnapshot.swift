import Foundation

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
    /// `CGDisplaySerialNumber`. A canvas or sharp screen Sensorium created
    /// reports its `CanvasDisplayIdentity` serial back; `0` when the display
    /// reports none.
    public let serialNumber: UInt32
    /// `NSScreen.localizedName` for this display, when macOS can match a
    /// screen to this id -- a canvas Sensorium created, or a display no
    /// screen in `NSScreen.screens` currently claims, leaves this `nil`. So
    /// does an empty or whitespace-only name, which is what macOS reports
    /// for the placeholder display it presents when no monitor is attached.
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
        serialNumber: UInt32 = 0,
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
        self.serialNumber = serialNumber
        self.name = name.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
    }
}
