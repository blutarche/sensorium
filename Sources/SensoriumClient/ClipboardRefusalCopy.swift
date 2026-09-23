import Foundation
import SensoriumCore

/// What the session window says when a clipboard was not shared, from either
/// machine, in plain words. Names the reason and sizes only, never anything
/// that was copied.
public enum ClipboardRefusalCopy {
    /// `nil` for a refusal no one needs to be told about: sharing being off
    /// is the person's own choice, and a refusal for want of a session never
    /// reaches a live session window.
    public static func line(for refusal: ClipboardRefusal) -> String? {
        switch refusal {
        case let .tooLarge(byteCount, limit):
            "Clipboard not shared: \(size(byteCount, roundingUp: true)) is over the "
                + "\(size(limit, roundingUp: false)) limit."
        case .excludedType:
            "Clipboard not shared: the app that copied it marked it private, or it is a file."
        case .unsupportedContent:
            "Clipboard not shared: only text and images are shared."
        case .syncDisabled, .sessionNotActive:
            nil
        }
    }

    /// The copy's size rounds up and the limit's rounds down, so a copy just
    /// over the limit never reads as the same size as it. Formatted without
    /// a locale on purpose: the sentence around it is not localized either.
    private static func size(_ bytes: Int, roundingUp: Bool) -> String {
        let kilobyte = 1024
        let megabyte = kilobyte * kilobyte
        let round: (Double) -> Double = roundingUp ? { $0.rounded(.up) } : { $0.rounded(.down) }
        if bytes >= megabyte {
            let tenths = Int(round(Double(bytes) / Double(megabyte) * 10))
            return tenths % 10 == 0 ? "\(tenths / 10) MB" : "\(tenths / 10).\(tenths % 10) MB"
        }
        if bytes >= kilobyte {
            return "\(Int(round(Double(bytes) / Double(kilobyte)))) KB"
        }
        return "\(bytes) bytes"
    }
}
