import AppKit
import Foundation
import SensoriumHost

/// The menu bar item draws the Sensorium mark -- a far screen peeking out
/// behind a near one -- not a lone rectangle, and the near screen's own
/// treatment is still what tells the states apart.
@MainActor
func runHostMenuBarLogoIconTests() async {
    func statusImage(for connection: HostConnectionState) -> NSImage {
        let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
        let presence = HostMenuBarPresence(
            status: HostOperatorStatus(connection: connection, permissions: granted),
            onStop: {},
            quit: {}
        )
        presence.install()
        for child in Mirror(reflecting: presence).children {
            if child.label == "statusItem", let item = child.value as? NSStatusItem?, let image = item?.button?.image {
                return image
            }
        }
        fatalError("the status item has no image")
    }

    /// Alpha at a point in the image's own 16x16 point space, origin bottom-left.
    func alpha(_ image: NSImage, x: Int, y: Int) -> CGFloat {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { fatalError("could not make a bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: x, y: 15 - y)?.alphaComponent ?? 0
    }

    let idle = statusImage(for: .hosting(address: "100.64.1.2"))
    expect(idle.isTemplate, "the menu bar mark is a template image so a light or dark bar can recolour it")
    expect(alpha(idle, x: 2, y: 10) > 0.5, "the far screen shows behind the near one at the left")
    expect(alpha(idle, x: 7, y: 12) > 0.5, "the far screen shows behind the near one along the top")
    expect(alpha(idle, x: 4, y: 8) < 0.1, "a moat of clear space separates the two screens")
    expect(alpha(idle, x: 10, y: 6) < 0.1, "an idle near screen is an outline, hollow inside")
    expect(alpha(idle, x: 10, y: 3) > 0.5, "the near screen's outline sits on its 16:10 bounds, 6.5 points tall")
    expect(alpha(idle, x: 10, y: 10) < 0.1, "the near screen is no taller than 16:10 -- not a squarer box")

    let serving = statusImage(for: .serving(peerName: "Kestrel Laptop Pro"))
    expect(alpha(serving, x: 10, y: 5) > 0.5, "a serving near screen is filled")

    print("PASS: the menu bar item draws the Sensorium mark with state shown on the near screen")
}
