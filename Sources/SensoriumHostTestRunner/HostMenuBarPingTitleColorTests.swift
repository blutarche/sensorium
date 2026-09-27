import AppKit
import Foundation
import SensoriumHost

/// AppKit synthesises a menu bar button's `attributedTitle` from `.title`
/// and `.font` on its own, including the adaptive control-text colour a
/// light or dark menu bar needs. Building `attributedTitle` by hand, as the
/// live ping display once did to pin the font, throws that colour away and
/// renders fixed black regardless of the menu bar's own appearance.
@MainActor
func runHostMenuBarPingTitleColorTests() async {
    func statusItem(in presence: HostMenuBarPresence) -> NSStatusItem {
        for child in Mirror(reflecting: presence).children {
            if child.label == "statusItem", let item = child.value as? NSStatusItem? {
                if let item {
                    return item
                }
            }
        }
        fatalError("HostMenuBarPresence no longer has a stored property named statusItem, or install() left it nil")
    }

    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let presence = HostMenuBarPresence(
        status: HostOperatorStatus(
            connection: .servingHostScreen(peerName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
            permissions: granted
        ),
        onStop: {},
        quit: {}
    )
    presence.install()
    guard let button = statusItem(in: presence).button else {
        fatalError("the status item's button was never installed")
    }

    expect(!button.attributedTitle.string.isEmpty, "the title still names the connected peer")
    expect(
        button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil,
        "AppKit's own synthesised text colour must survive -- a hand-built attributedTitle with no "
            + "foregroundColor renders fixed black in a dark menu bar or the highlighted state"
    )
    expect(
        button.font == NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        "the button's own font is set to the monospaced-digit system font, so a live ping's changing "
            + "digit count never jitters the item's width"
    )

    print("PASS: the menu bar title keeps AppKit's own adaptive colour and still uses the monospaced-digit font")
}
