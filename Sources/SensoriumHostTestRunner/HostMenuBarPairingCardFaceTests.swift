import AppKit
import Foundation
import SensoriumHost

/// The menu-bar pairing panel's own code box: only the six digits earn the
/// mono face -- the countdown and the hint sentence around them read in the
/// sans body face, the same rule `HostSetupPairingCodeViewTests` already
/// checks for the Host Setup window's own copy of this card.
///
/// A code a person revealed themselves names no requesting device, so the
/// ready state's detail line is empty and the card draws no line for it.
@MainActor
func runHostMenuBarPairingCardFaceTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let presentation = HostOperatorStatus(
        connection: .hosting(address: "203.0.113.42"),
        pairing: .showing(code: "418297", expiresAt: Date().addingTimeInterval(300)),
        permissions: granted
    ).presentation(now: Date())

    let texts = CanvasHostTestHooks.menuBarPanelTexts(presentation)
    expect(
        texts.count == 5,
        "the status card's eyebrow and headline, then the code, its countdown, and the hint naming which "
            + "machine types it -- got \(texts.count) texts"
    )

    let digits = texts[2]
    expect(
        digits.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == CanvasDesign.font(.mono, size: 30, weight: .semibold),
        "the six digits still read in the mono face"
    )

    let countdown = texts[3]
    let countdownString = countdown.string as NSString
    let wordFont = countdown.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    expect(
        wordFont == CanvasDesign.font(.primary, size: 12),
        "the countdown sentence itself reads in the sans body face -- got \(String(describing: wordFont))"
    )
    let digitRange = countdownString.rangeOfCharacter(from: .decimalDigits)
    expect(digitRange.location != NSNotFound, "the countdown carries a live minutes:seconds value -- got: \(countdown.string)")
    let digitFont = countdown.attribute(.font, at: digitRange.location, effectiveRange: nil) as? NSFont
    expect(
        digitFont == NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        "the countdown's own digits carry tabular figures -- got \(String(describing: digitFont))"
    )

    let hint = texts[4]
    expect(
        hint.string == HostOperatorPresentation.pairingCodeHint,
        "the hint names which machine the digits are typed on -- got: \(hint.string)"
    )
    expect(
        hint.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == CanvasDesign.font(.primary, size: 12),
        "the hint sentence reads in the sans body face, not the mono face the six digits alone earn"
    )

    print("PASS: the menu-bar pairing card's countdown and hint read in the sans face, with the countdown's digits tabular")
}
