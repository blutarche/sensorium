import Foundation

/// How the viewer's own sentences are prepared so they wrap well, on every
/// platform: the rules are in the text itself (no-break characters), so the
/// AppKit labels and the Linux painter break lines identically.
///
/// - A machine name never breaks at its own spaces or hyphens. A name wider
///   than a whole line still breaks, by character, because it has no other
///   place to.
/// - A control name quoted in a sentence, such as `Your Machines`, never
///   splits across two lines.
/// - The end of a sentence is held together, so the last line of a wrapped
///   headline or body never holds a lone word. A last word long enough to
///   stand alone, such as a long machine name, takes no companion: binding it
///   to the word before would strand that word on a line of its own.
public enum ViewerCopyWrapping {
    static let noBreakSpace: Character = "\u{00A0}"
    static let nonBreakingHyphen: Character = "\u{2011}"

    /// A machine name as it should sit inside a sentence.
    public static func name(_ name: String) -> String {
        String(name.map { character in
            switch character {
            case " ": noBreakSpace
            case "-": nonBreakingHyphen
            default: character
            }
        })
    }

    /// A control's title quoted in running text.
    public static func control(_ title: String) -> String {
        title.replacingOccurrences(of: " ", with: String(noBreakSpace))
    }

    /// An unrecognised wire token quoted verbatim. The closing quote is part
    /// of the same unbreakable run as the token, so it cannot start a line.
    public static func quoted(_ token: String) -> String {
        "\u{201C}\(name(token))\u{201D}"
    }

    /// The length below which a closing run still reads as a stranded remnant
    /// and takes another word with it.
    private static let minimumTailCharacters = 16
    private static let maximumTailWords = 4

    /// Joins the last words of `text`'s final paragraph with no-break spaces.
    /// A tail grows (up to four words) until it is long enough not to look
    /// like a leftover, so a short last word always has company. Idempotent,
    /// so a sentence built from bound sentences can be bound again.
    public static func keepingTailTogether(_ text: String) -> String {
        keepingTailTogether(text, maximumWords: maximumTailWords)
    }

    /// For a banner, whose few wide lines show a ragged right edge: only the
    /// last two words are bound, which is all it takes for the last line not
    /// to hold a lone word. Every earlier line is free to fill. A last word
    /// long enough to stand alone still takes no companion.
    public static func keepingLastTwoWordsTogether(_ text: String) -> String {
        keepingTailTogether(text, maximumWords: 2)
    }

    private static func keepingTailTogether(_ text: String, maximumWords: Int) -> String {
        var characters = Array(text)
        let paragraphStart = characters.lastIndex(of: "\n").map { $0 + 1 } ?? 0

        var words: [Range<Int>] = []
        var wordStart: Int?
        for index in paragraphStart..<characters.count {
            if isWordSeparator(characters[index]) {
                if let start = wordStart {
                    words.append(start..<index)
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = index
            }
        }
        if let start = wordStart {
            words.append(start..<characters.count)
        }
        guard words.count >= 2, let last = words.last else { return text }

        var tailWords = 1
        while tailWords < words.count, tailWords < maximumWords,
              last.upperBound - words[words.count - tailWords].lowerBound < minimumTailCharacters {
            tailWords += 1
        }
        let tailStart = words[words.count - tailWords].lowerBound
        for index in tailStart..<last.upperBound where isWordSeparator(characters[index]) {
            characters[index] = noBreakSpace
        }
        return String(characters)
    }

    private static func isWordSeparator(_ character: Character) -> Bool {
        character == " " || character == noBreakSpace
    }
}
