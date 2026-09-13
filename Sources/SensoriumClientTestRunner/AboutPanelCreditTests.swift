import AppKit
import SensoriumCore

/// The credit shown in the viewer's About panel must survive even when the
/// running binary is unbundled and has no Info.plist -- see
/// `SensoriumCredit.standardAboutPanelOptions`.
func testAboutPanelCreditTests() {
    let options = SensoriumCredit.standardAboutPanelOptions
    guard let credits = options[.credits] as? NSAttributedString else {
        fatalError("standardAboutPanelOptions carries no .credits entry, or not as an NSAttributedString")
    }
    expect(
        credits.string == SensoriumCredit.copyrightLine,
        "the About panel's credits must be the copyright line, got \(credits.string)"
    )
    print("PASS: the About panel's options carry the copyright line even without an Info.plist")
}
