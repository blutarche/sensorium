import AppKit
import Foundation
import SensoriumHost

/// The break rules every host text surface shares: names whole when they fit,
/// dates whole, "a" kept with its noun, the last two words together.
@MainActor
func runHostTextFlowTests() async {
    let nbsp = "\u{00A0}"
    let nbh = "\u{2011}"

    do {
        expect(
            HostTextFlow.whole("Kestrel-Field Laptop") == "Kestrel\(nbh)Field\(nbsp)Laptop",
            "a name's spaces and hyphens become the non-breaking ones"
        )
        print("PASS: whole(_:) makes every space and hyphen of a name non-breaking")
    }

    do {
        expect(
            HostTextFlow.flow("Waiting for Kestrel Laptop to finish pairing")
                == "Waiting for Kestrel Laptop to finish\(nbsp)pairing",
            "the last two words of a headline stay together"
        )
        expect(
            HostTextFlow.flow("Could not read the key.") == "Could not read the\(nbsp)key.",
            "trailing punctuation belongs to the last word"
        )
        expect(
            HostTextFlow.flow("Not hosting") == "Not hosting",
            "two words are the whole text; binding them would leave nothing to wrap"
        )
        expect(HostTextFlow.flow("") == "", "nothing in, nothing out")
        print("PASS: the last two words of a text stay together")
    }

    do {
        expect(
            HostTextFlow.flow("Kestrel Laptop wants to see and control a display of this machine")
                == "Kestrel Laptop wants to see and control a\(nbsp)display of this\(nbsp)machine",
            "the one-letter word a never ends a line"
        )
        expect(
            HostTextFlow.flow("Is this I or a-b or Mia") == "Is this I\(nbsp)or a-b or\(nbsp)Mia",
            "only a standalone a or I binds forward: a hyphenated a-b does not"
        )
        print("PASS: a one-letter article stays with the word after it")
    }

    do {
        let named = HostTextFlow.flow(
            "Kestrel Laptop used LG UltraFine 5K Display from today.",
            names: ["Kestrel Laptop", "LG UltraFine 5K Display"]
        )
        expect(
            named == "Kestrel\(nbsp)Laptop used LG\(nbsp)UltraFine\(nbsp)5K\(nbsp)Display from\(nbsp)today.",
            "each named machine and display is held whole -- got \(named.debugDescription)"
        )

        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let measure = { (width: CGFloat) in HostTextFlow.Measure(attributes: [.font: font], width: width) }
        let fits = HostTextFlow.flow("Kestrel Laptop is here now", names: ["Kestrel Laptop"], measure: measure(300))
        expect(fits.contains("Kestrel\(nbsp)Laptop"), "a name that fits its column is held whole")
        let wider = HostTextFlow.flow(
            "Kestrel Field Station Laptop is here now", names: ["Kestrel Field Station Laptop"], measure: measure(40)
        )
        expect(
            wider.hasPrefix("Kestrel\(nbsp)Field Station Laptop"),
            "a name wider than its column breaks at its own spaces, but never between its first two words -- got \(wider.debugDescription)"
        )
        print("PASS: names stay whole when they fit their column and are left alone when they cannot")
    }

    do {
        let british = HostTextFlow.flow("Kestrel Laptop used Display from 15 Nov 2023, 05:13 to 05:43.")
        expect(
            british.contains("15\(nbsp)Nov\(nbsp)2023,"),
            "a day-month-year date never splits -- got \(british.debugDescription)"
        )
        let american = HostTextFlow.flow("Kestrel Laptop used Display from Nov 15, 2023, 5:13 AM to 5:43 AM.")
        expect(
            american.contains("Nov\(nbsp)15,\(nbsp)2023,"),
            "a month-day-year date never splits -- got \(american.debugDescription)"
        )
        let plain = HostTextFlow.flow("Sensorium Host 0.5.0 will install when no machine is connected.")
        expect(
            plain == "Sensorium Host 0.5.0 will install when no machine is\(nbsp)connected.",
            "a version number is not a date -- got \(plain.debugDescription)"
        )
        print("PASS: calendar dates stay whole in either order")
    }
}
