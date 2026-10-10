import Foundation

/// The display a host-screen session streams in place of macOS's own
/// placeholder screen, on a host with no monitor attached.
///
/// With no monitor, macOS keeps one placeholder display online: 1920x1080
/// pixels at 1x, with a single mode. A viewer on a high-density screen has
/// to scale that picture up, and it looks soft. A session that would stream
/// the placeholder instead streams a virtual display Sensorium creates for
/// it, 1920x1080 points at 2x. macOS takes the placeholder away while that
/// display exists and brings it back once it is released.
///
/// Everything here is decided from a display list alone, so the checks are
/// the same wherever a list comes from.
public enum SharpScreen {
    public static let identity = CanvasDisplayIdentity.sharpScreen

    /// Whether `display` carries the sharp screen's identity: the one this
    /// process manages, or one an earlier host left behind.
    public static func isSharpScreen(_ display: DisplaySnapshot) -> Bool {
        display.vendorNumber == identity.vendorID && display.serialNumber == identity.serialNumber
    }

    /// Whether `display` is a sharp screen that is the only online display,
    /// which is the one shape in which it stands where the placeholder would.
    /// Offered and admitted then like the placeholder, whether this process
    /// manages it or an earlier host left it behind; never otherwise.
    public static func standsInForPlaceholder(_ display: DisplaySnapshot, among displays: [DisplaySnapshot]) -> Bool {
        guard isSharpScreen(display), display.online else {
            return false
        }
        let online = displays.filter(\.online)
        return online.count == 1 && online[0].id == display.id
    }

    /// Whether `display` is macOS's placeholder screen and nothing else could
    /// be meant: it reports the placeholder's vendor and model, Sensorium did
    /// not create it, it is online, it is the only online display, and
    /// nothing in `displays` looks like a monitor. Any doubt reads as "not
    /// the placeholder", which leaves the session streaming the display it
    /// was admitted for.
    ///
    /// `displays` is every display this machine has online, `display`
    /// included.
    public static func isPlaceholder(_ display: DisplaySnapshot, among displays: [DisplaySnapshot]) -> Bool {
        guard PhysicalDisplayEvidence.isHeadlessStandIn(display),
              !PhysicalDisplayEvidence.isSensoriumCanvas(display),
              display.online,
              !hasMonitor(displays) else {
            return false
        }
        let online = displays.filter(\.online)
        return online.count == 1 && online[0].id == display.id
    }

    /// The one display in `displays` that `isPlaceholder` accepts, or `nil`
    /// when there is none.
    public static func placeholder(among displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        displays.first { isPlaceholder($0, among: displays) }
    }

    /// Whether `displays` holds anything that may be a monitor: a display
    /// that is neither one Sensorium created nor macOS's placeholder. Asleep
    /// or awake alike, since a sleeping monitor is still attached.
    public static func hasMonitor(_ displays: [DisplaySnapshot]) -> Bool {
        displays.contains {
            !PhysicalDisplayEvidence.isSensoriumCanvas($0) && !PhysicalDisplayEvidence.isHeadlessStandIn($0)
        }
    }
}
