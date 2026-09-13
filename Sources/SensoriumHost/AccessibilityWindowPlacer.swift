@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Reads Accessibility trust without ever asking macOS to present its approval
/// UI. A session canvas is remote by definition, so a TCC prompt would open on
/// a screen nobody is sitting in front of. See `AccessibilityPermissionGate`,
/// which draws the same boundary for the input injector.
public enum HostAccessibilityTrust {
    public static let isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
}

/// Moves another application's windows through the Accessibility API.
///
/// `@unchecked Sendable`: `AXUIElement` is not `Sendable`, and the window
/// elements read by one poll must still be indexable by the placement that
/// follows it -- a second `kAXWindowsAttribute` read can return a different
/// list. The elements are therefore held across the two calls under a lock,
/// and never escape this type.
public final class AccessibilityWindowPlacer: LaunchedWindowPlacing, @unchecked Sendable {
    private let lock = NSLock()
    private var placeable: [AXUIElement] = []

    public init() {}

    public func windowFrames(processIdentifier: pid_t) -> [CGRect] {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            store([])
            return []
        }
        // A window whose position or size cannot be read cannot be safely
        // placed either, so it is dropped from both lists together and the
        // index the adopter uses stays meaningful.
        var elements: [AXUIElement] = []
        var frames: [CGRect] = []
        for window in windows {
            guard let origin = point(of: window, attribute: kAXPositionAttribute),
                  let size = size(of: window) else {
                continue
            }
            elements.append(window)
            frames.append(CGRect(origin: origin, size: size))
        }
        store(elements)
        return frames
    }

    public func place(processIdentifier: pid_t, windowIndex: Int, placement: CanvasWindowPlacement) -> Bool {
        lock.lock()
        let window = windowIndex < placeable.count ? placeable[windowIndex] : nil
        lock.unlock()
        guard let window else {
            return false
        }
        // Size first: a window still larger than the canvas would be pushed
        // back out of it by macOS if it were positioned at the canvas edge
        // before being shrunk.
        var size = placement.size
        var origin = placement.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin) else {
            return false
        }
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        return resized == .success && moved == .success
    }

    private func store(_ elements: [AXUIElement]) {
        lock.lock()
        placeable = elements
        lock.unlock()
    }

    private func point(of element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = attributeValue(of: element, attribute: attribute) else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func size(of element: AXUIElement) -> CGSize? {
        guard let value = attributeValue(of: element, attribute: kAXSizeAttribute) else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func attributeValue(of element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }
}

/// Starts an application through Launch Services. Nothing else in the host
/// opens another application, so the whole surface is this one call.
public final class WorkspaceApplicationOpener: CanvasApplicationOpening {
    public init() {}

    public func open(
        _ application: LaunchableApplication,
        completion: @escaping @Sendable (Result<pid_t, CanvasApplicationOpenError>) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        // Activated so the application actually opens its window; where that
        // window then goes is the adopter's business, never the canvas's.
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application.bundleURL, configuration: configuration) { running, error in
            guard let running else {
                completion(.failure(CanvasApplicationOpenError(
                    message: error?.localizedDescription ?? "the application did not start"
                )))
                return
            }
            completion(.success(running.processIdentifier))
        }
    }
}
