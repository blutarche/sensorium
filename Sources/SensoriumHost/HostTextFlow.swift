import AppKit
import Foundation

/// Where a line may and may not break in prose the host draws. Applied where
/// a label or drawn paragraph receives its string, so the words themselves
/// stay plain wherever they are decided.
package enum HostTextFlow {
    package static let noBreakSpace = "\u{00A0}"
    package static let nonBreakingHyphen = "\u{2011}"

    /// The face and column a name is measured in, to tell whether it fits on
    /// one line.
    package struct Measure {
        package let attributes: [NSAttributedString.Key: Any]
        package let width: CGFloat

        package init(attributes: [NSAttributedString.Key: Any], width: CGFloat) {
            self.attributes = attributes
            self.width = width
        }
    }

    /// `name` with every space and hyphen made non-breaking, so a line never
    /// ends inside it.
    package static func whole(_ name: String) -> String {
        name
            .replacingOccurrences(of: " ", with: noBreakSpace)
            .replacingOccurrences(of: "-", with: nonBreakingHyphen)
    }

    /// `text` with its break points tidied:
    /// - each mention of one of `names` stays whole when it fits `measure`'s
    ///   column, or always when there is no `measure`, with one exception: a
    ///   name that does not fit what remains of the line it falls on, and
    ///   would leave that line less than half full by moving to the next,
    ///   wraps at its spaces instead. A name too wide for the column breaks
    ///   where it naturally would. Either way its first two words stay
    ///   together;
    /// - a calendar date stays whole;
    /// - the one-letter words "a" and "I" stay with the word after them;
    /// - the last two words stay together, so no line ends with one word alone.
    package static func flow(_ text: String, names: [String] = [], measure: Measure? = nil) -> String {
        var result = text
        for name in names.sorted(by: { $0.count > $1.count }) where name.contains(" ") || name.contains("-") {
            result = holding(name, in: result, measure: measure)
        }
        result = bindingDates(in: result)
        result = bindingOneLetterWords(in: result)
        return bindingLastTwoWords(in: result)
    }

    private static func bindingFirstTwoWords(of name: String) -> String {
        guard let firstSpace = name.firstIndex(of: " ") else { return name }
        var result = name
        result.replaceSubrange(firstSpace...firstSpace, with: noBreakSpace)
        return result
    }

    /// Every mention of `name` in `text`, each held whole or not by where it
    /// falls, in reading order so a later mention is judged after the earlier
    /// ones are in place.
    private static func holding(_ name: String, in text: String, measure: Measure?) -> String {
        var result = text
        var resume = 0
        while let range = result.range(
            of: name,
            range: result.index(result.startIndex, offsetBy: resume)..<result.endIndex
        ) {
            let held = staysWhole(name, after: result[..<range.lowerBound], in: measure)
                ? whole(name)
                : bindingFirstTwoWords(of: name)
            let start = result.distance(from: result.startIndex, to: range.lowerBound)
            result.replaceSubrange(range, with: held)
            resume = start + held.count
        }
        return result
    }

    /// How full the line before a name must be for the name to move whole to
    /// the next line. Below it, the gap that move leaves is worse than
    /// breaking the name at a space.
    private static let minimumFilledBeforeWholeName: CGFloat = 0.5

    private static func staysWhole(_ name: String, after preceding: Substring, in measure: Measure?) -> Bool {
        guard let measure else { return true }
        let width = NSAttributedString(string: name, attributes: measure.attributes).size().width
        guard width <= measure.width else { return false }
        let used = usedWidthOfLastLine(of: String(preceding), in: measure)
        return width <= measure.width - used || used >= measure.width * minimumFilledBeforeWholeName
    }

    /// How much of its column the last line of `text` fills, trailing space
    /// included.
    private static func usedWidthOfLastLine(of text: String, in measure: Measure) -> CGFloat {
        let storage = NSTextStorage(string: bindingOneLetterWords(in: bindingDates(in: text)), attributes: measure.attributes)
        let container = NSTextContainer(size: NSSize(width: measure.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else { return 0 }
        return layout.lineFragmentUsedRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil).maxX
    }

    /// "15 Nov 2023" and "Nov 15, 2023", the two orders a medium date takes.
    private static let datePatterns = [
        #"\b\d{1,2} \p{L}{3,9}\.? \d{4}\b"#,
        #"\b\p{L}{3,9}\.? \d{1,2}, \d{4}\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func bindingDates(in text: String) -> String {
        var result = text
        for pattern in datePatterns {
            let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: result[range].replacingOccurrences(of: " ", with: noBreakSpace))
            }
        }
        return result
    }

    private static let oneLetterWord = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’\-])([aAI]) (?=\S)"#)

    private static func bindingOneLetterWords(in text: String) -> String {
        guard let oneLetterWord else { return text }
        return oneLetterWord.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1\(noBreakSpace)"
        )
    }

    private static func bindingLastTwoWords(in text: String) -> String {
        let end = text.lastIndex(where: { $0 != " " }).map { text.index(after: $0) } ?? text.startIndex
        guard let lastSpace = text[..<end].lastIndex(of: " "),
              text[..<lastSpace].contains(" ") else {
            return text
        }
        var result = text
        result.replaceSubrange(lastSpace...lastSpace, with: noBreakSpace)
        return result
    }
}
