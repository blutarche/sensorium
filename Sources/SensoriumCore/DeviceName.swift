/// The one rule for a machine's name before anyone sees it: the name a
/// device reports when it pairs or says hello, and a name a person types for
/// a machine on either side.
///
/// A reported name comes from the other machine, so it is untrusted text
/// that ends up in the live-session indicator, the ask-first prompt, the
/// menu bar and the session record. Cleaning removes every control (`Cc`)
/// and format (`Cf`) character, which covers bidirectional overrides and
/// isolates and zero-width characters, so a name cannot reorder or hide
/// text around it. That includes the zero-width joiner, so an emoji built
/// from joined emoji shows as its separate parts.
public enum DeviceName {
    /// In characters a person sees (grapheme clusters), not bytes.
    public static let maximumLength = 64

    /// `raw` with control and format characters removed, every run of
    /// whitespace (newlines and tabs included) turned into one space,
    /// trimmed, and cut to `maximumLength`. `nil` when nothing is left.
    public static func sanitized(_ raw: String) -> String? {
        var cleaned = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            // Checked before the control category: a newline or tab is a
            // control character too, and must leave a space, not vanish.
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format:
                continue
            default:
                if pendingSpace, !cleaned.isEmpty {
                    cleaned.append(" ")
                }
                pendingSpace = false
                cleaned.append(scalar)
            }
        }
        var name = String(String(cleaned).prefix(maximumLength))
        while name.last == " " {
            name.removeLast()
        }
        return name.isEmpty ? nil : name
    }
}
