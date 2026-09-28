#if canImport(AppKit)
import AppKit

/// The macOS form of `ViewerNewKeyConfirmation`. Return presses Cancel:
/// replacing the key is never the answer to a stray Return.
@MainActor
public enum ViewerNewKeyAlert {
    public static func make() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = ViewerNewKeyConfirmation.question
        alert.informativeText = ViewerNewKeyConfirmation.detail
        // NSAlert gives a first button titled Cancel Escape, not Return.
        alert.addButton(withTitle: ViewerNewKeyConfirmation.cancelTitle).keyEquivalent = "\r"
        alert.addButton(withTitle: ViewerNewKeyConfirmation.confirmTitle).keyEquivalent = ""
        return alert
    }

    public static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }
}
#endif
