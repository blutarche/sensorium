#if canImport(AppKit)
import AppKit
import SensoriumClient

/// Replacing this machine's key is one-way, so a stray Return must cancel.
@MainActor
func testViewerNewKeyAlertTests() {
    let alert = ViewerNewKeyAlert.make()
    let titles = alert.buttons.map(\.title)
    let defaults = alert.buttons.filter { $0.keyEquivalent == "\r" }.map(\.title)
    expect(
        defaults == [ViewerNewKeyConfirmation.cancelTitle],
        "Return answers Cancel and nothing else, got \(defaults) among \(titles)"
    )
    let confirmIndex = titles.firstIndex(of: ViewerNewKeyConfirmation.confirmTitle)
    let cancelIndex = titles.firstIndex(of: ViewerNewKeyConfirmation.cancelTitle)
    expect(confirmIndex != nil && cancelIndex != nil, "both buttons are offered, got \(titles)")
    if let confirmIndex, let cancelIndex {
        let response = { (index: Int) in
            NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
        }
        expect(
            ViewerNewKeyAlert.isConfirmed(response(confirmIndex)),
            "the Make a New Key button confirms"
        )
        expect(
            !ViewerNewKeyAlert.isConfirmed(response(cancelIndex)),
            "the Cancel button does not confirm"
        )
    }
    print("PASS: Return cancels a new key, and only Make a New Key confirms one")
}
#endif
