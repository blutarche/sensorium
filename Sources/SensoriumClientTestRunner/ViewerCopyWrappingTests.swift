import Foundation
import SensoriumClient

/// The wrapping rules every overlay, notice and message window shares: a name
/// never breaks at its own spaces or hyphens, a control name quoted in text
/// never splits, and a wrapped sentence never ends on a stranded word.
func testViewerCopyWrappingTests() {
    let nbsp = "\u{00A0}"
    let hyphen = "\u{2011}"

    expect(
        ViewerCopyWrapping.name("Kestrel Laptop") == "Kestrel\(nbsp)Laptop",
        "a name's spaces become no-break spaces"
    )
    expect(
        ViewerCopyWrapping.name("Kestrel-Field-Station") == "Kestrel\(hyphen)Field\(hyphen)Station",
        "a name's hyphens become non-breaking hyphens"
    )
    expect(ViewerCopyWrapping.name("Workstation") == "Workstation", "a name with neither is untouched")
    expect(
        ViewerCopyWrapping.control("Your Machines") == "Your\(nbsp)Machines",
        "a control name quoted in text keeps its words together"
    )
    expect(
        ViewerCopyWrapping.quoted("a-reason") == "\u{201C}a\(hyphen)reason\u{201D}",
        "a quoted token is wrapped in curly quotes with its hyphens held"
    )

    let nameSentence = "Could not show a host screen from Workstation."
    expect(
        ViewerCopyWrapping.keepingTailTogether(nameSentence)
            == "Could not show a host screen from\(nbsp)Workstation.",
        "a name is never alone on the last line: got \(ViewerCopyWrapping.keepingTailTogether(nameSentence))"
    )
    let tryAgain = "Update both apps, then try again."
    expect(
        ViewerCopyWrapping.keepingTailTogether(tryAgain) == "Update both apps,\(nbsp)then\(nbsp)try\(nbsp)again.",
        "a two-word tail that is too short to stand alone takes more words with it: got "
            + ViewerCopyWrapping.keepingTailTogether(tryAgain)
    )
    expect(
        ViewerCopyWrapping.keepingTailTogether("Nothing here.") == "Nothing\(nbsp)here.",
        "a short sentence is bound whole"
    )
    expect(ViewerCopyWrapping.keepingTailTogether("Stopped.") == "Stopped.", "one word has nothing to bind")
    expect(ViewerCopyWrapping.keepingTailTogether("") == "", "empty text is untouched")
    for text in [nameSentence, tryAgain, "Connecting to Kestrel\(nbsp)Laptop\u{2026}"] {
        let once = ViewerCopyWrapping.keepingTailTogether(text)
        expect(
            ViewerCopyWrapping.keepingTailTogether(once) == once,
            "binding a sentence twice changes nothing more: \(once)"
        )
    }
    let twoParagraphs = "First paragraph stays loose here.\n\nThen a closing line of words."
    expect(
        ViewerCopyWrapping.keepingTailTogether(twoParagraphs)
            == "First paragraph stays loose here.\n\nThen a closing\(nbsp)line\(nbsp)of\(nbsp)words.",
        "only the last paragraph is bound: got \(ViewerCopyWrapping.keepingTailTogether(twoParagraphs))"
    )

    print("PASS: copy wrapping keeps names, control names and sentence tails whole")
}
