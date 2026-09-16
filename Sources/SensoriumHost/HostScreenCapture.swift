import ScreenCaptureKit

public enum HostScreenCaptureError: Error, Equatable {
    case displayNotShareable
}

/// Resolves the ScreenCaptureKit content filter for a host-screen target --
/// one existing physical display, captured exactly as it is. Sibling to
/// `SessionCanvasCapture`, which resolves the same kind of filter for the
/// session-owned virtual canvas; the two are kept separate rather than
/// merged, because `SessionCanvasCapture` is structurally incapable of
/// resolving anything but the one display it owns, and this type must be
/// able to resolve whichever display `HostScreenSelectionGuard` already
/// admitted for this session.
///
/// This does no admission checking of its own -- `HostSessionController`'s
/// `HostScreenSelectionGuard` already proved this exact display ID belongs
/// to an armed machine, is live, and is not a session canvas, before this is
/// ever called. Re-checking any of that here would be a second,
/// divergent copy of an obligation `HostScreenSelectionGuard` already owns.
///
/// Running this requires the user to grant Screen Recording permission to
/// the host app. Nothing in this repository runs it, and no test calls
/// these methods -- the same discipline `SessionCanvasCapture` already
/// states about itself.
@available(macOS 13.0, *)
public enum HostScreenCapture {
    static func contentFilter(
        displayID: UInt32,
        shareableContent: SCShareableContent
    ) throws -> SCContentFilter {
        guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw HostScreenCaptureError.displayNotShareable
        }
        // Capture everything on the target -- no excluded application, no
        // excepted window. This is safe for the session canvas only because
        // that target is private; for host screen it is the whole point --
        // the viewer sees exactly what is on the real display, the same as
        // sitting in front of the machine.
        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    public static func contentFilter(displayID: UInt32) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return try contentFilter(displayID: displayID, shareableContent: content)
    }
}
