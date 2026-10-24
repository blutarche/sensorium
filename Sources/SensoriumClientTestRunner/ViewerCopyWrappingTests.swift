import Foundation
import SensoriumClient
import SensoriumCore

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
    let longName = "Kestrel\u{2011}Field\u{2011}Station\u{2011}Notebook."
    expect(
        ViewerCopyWrapping.keepingTailTogether("Could not show a host screen from \(longName)")
            == "Could not show a host screen from \(longName)",
        "a last word long enough to stand alone takes no companion, so the word before it is not stranded"
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

/// A banner is a few wide lines over a live picture, so a ragged right edge
/// shows. Its copy binds only the last two words: just enough that the last
/// line never holds a lone word, and every earlier line fills.
func testViewerNoticeWrappingTests() {
    let nbsp = "\u{00A0}"

    expect(
        ViewerCopyWrapping.keepingLastTwoWordsTogether("Update both apps, then try again.")
            == "Update both apps, then try\(nbsp)again.",
        "only the last two words are bound: got "
            + ViewerCopyWrapping.keepingLastTwoWordsTogether("Update both apps, then try again.")
    )
    expect(
        ViewerCopyWrapping.keepingLastTwoWordsTogether("Nothing here.") == "Nothing\(nbsp)here.",
        "a two-word sentence is bound whole"
    )
    let longName = "Kestrel\u{2011}Field\u{2011}Station\u{2011}Notebook."
    expect(
        ViewerCopyWrapping.keepingLastTwoWordsTogether("Could not show a host screen from \(longName)")
            == "Could not show a host screen from \(longName)",
        "a last word long enough to stand alone takes no companion"
    )
    expect(ViewerCopyWrapping.keepingLastTwoWordsTogether("Stopped.") == "Stopped.", "one word has nothing to bind")
    expect(ViewerCopyWrapping.keepingLastTwoWordsTogether("") == "", "empty text is untouched")
    let once = ViewerCopyWrapping.keepingLastTwoWordsTogether("Update both apps, then try again.")
    expect(ViewerCopyWrapping.keepingLastTwoWordsTogether(once) == once, "binding twice changes nothing more")

    func closingRun(_ line: String) -> String {
        line.split(separator: " ").last.map(String.init) ?? ""
    }
    func nbspCount(_ text: String) -> Int {
        text.filter { String($0) == nbsp }.count
    }
    let reasons = [
        "host-screen-session-active",
        "display-count-exceeds-host-limit",
        CanvasRefusalReason.creationInProgress,
        "display-count-change-failed",
        "a-reason-this-build-has-never-seen"
    ]
    for reason in reasons {
        let line = DisplayCountRefusalCopy.line(reason: reason, hostLabel: "Workstation")
        expect(
            nbspCount(closingRun(line)) == 1,
            "the \(reason) banner binds exactly its last two words, got closing run \"\(closingRun(line))\" in \"\(line)\""
        )
    }
    let creating = DisplayCountRefusalCopy.line(
        reason: CanvasRefusalReason.creationInProgress, hostLabel: "Workstation"
    )
    expect(
        creating.contains("from the Displays\(nbsp)menu"),
        "the article may end a line; the menu's name and its noun stay together, got \"\(creating)\""
    )
    let clipboard = ClipboardRefusalCopy.line(for: .excludedType) ?? ""
    expect(
        nbspCount(closingRun(clipboard)) == 1,
        "the clipboard banner binds exactly its last two words, got \"\(clipboard)\""
    )
    let resolution = HostScreenRefusalCopy.modeRefusalLine(
        reason: HostScreenModeRefusalReason.failed, hostLabel: "Workstation"
    )
    expect(
        nbspCount(closingRun(resolution)) == 1,
        "the resolution banner binds exactly its last two words, got \"\(resolution)\""
    )

    print("PASS: banner copy binds only its last two words, so every earlier line fills")
}
