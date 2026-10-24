import AppKit

@main
struct ViewerWindowMaximizeCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = makeViewerWindow()
        defer { window.orderOut(nil) }
        let original = window.frame
        guard let screen = window.screen else {
            fputs("FAIL: the synthetic viewer window has no screen\n", stderr)
            exit(1)
        }
        let available = screen.visibleFrame
        for _ in 0..<3 {
            window.zoom(nil)
            guard matches(window.frame, available) else {
                fputs("FAIL: native viewer zoom does not fill the available screen\n", stderr)
                exit(1)
            }
            window.zoom(nil)
            guard matches(window.frame, original) else {
                fputs("FAIL: native viewer zoom does not restore its previous frame\n", stderr)
                exit(1)
            }
        }
        print("PASS: native viewer zoom fills the available screen and restores its frame across three toggles")
    }

    private static func matches(_ actual: NSRect, _ expected: NSRect) -> Bool {
        abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1
            && abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1
    }
}
