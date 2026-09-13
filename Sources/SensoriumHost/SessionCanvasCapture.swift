import CoreGraphics
import Foundation
import ScreenCaptureKit
import SensoriumCore

public enum SessionCanvasCaptureError: Error, Equatable {
    case canvasDisplayNotFound
}

/// Resolves the ScreenCaptureKit content filter for the session-owned canvas and
/// nothing else. A display that is not the owned handle is never resolvable here.
///
/// Running this requires the user to grant Screen Recording permission to the
/// host app. Nothing in this repository grants or requests that permission.
@available(macOS 13.0, *)
public enum SessionCanvasCapture {
    public static func contentFilter(
        ownedHandle: VirtualDisplayHandle,
        shareableContent: SCShareableContent
    ) throws -> SCContentFilter {
        guard let display = shareableContent.displays.first(where: { $0.displayID == ownedHandle.rawValue }) else {
            throw SessionCanvasCaptureError.canvasDisplayNotFound
        }
        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    public static func contentFilter(ownedHandle: VirtualDisplayHandle) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return try contentFilter(ownedHandle: ownedHandle, shareableContent: content)
    }
}
