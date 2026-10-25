import Foundation

/// How an address too wide for its row is shortened: the host part gives up
/// characters from its middle, and the ":port" at the end is never touched.
/// The port is what tells two services on one machine apart, and an ellipsis
/// that swallowed it would leave an address that looks complete and is not.
///
/// Pure and measured through a closure, so the macOS view and the Linux
/// painter shorten to the same text with their own fonts.
public enum SessionHUDAddressFit {
    public static let ellipsis = "\u{2026}"

    /// `address` unchanged when `measure` says it fits in `width`; otherwise
    /// the longest host-middle-shortened form that does. When even the
    /// ellipsis and the port do not fit, that is still what comes back: the
    /// port stays whole and the caller's own truncation takes what remains.
    public static func fitting(_ address: String, width: Double, measure: (String) -> Double) -> String {
        guard measure(address) > width else { return address }
        let (host, port) = split(address)
        let characters = Array(host)
        var kept = characters.count - 1
        while kept > 0 {
            let candidate = shortened(characters, keeping: kept) + port
            if measure(candidate) <= width { return candidate }
            kept -= 1
        }
        return ellipsis + port
    }

    /// The host and its trailing ":port", split at the last colon when only
    /// digits follow it. An address with no port is all host.
    private static func split(_ address: String) -> (host: String, port: String) {
        guard let colon = address.lastIndex(of: ":") else { return (address, "") }
        let digits = address[address.index(after: colon)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              colon != address.startIndex else { return (address, "") }
        return (String(address[..<colon]), String(address[colon...]))
    }

    /// `kept` characters of the host, the start getting the extra one of an
    /// odd count, with the ellipsis where the rest was.
    private static func shortened(_ host: [Character], keeping kept: Int) -> String {
        let head = (kept + 1) / 2
        let tail = kept - head
        return String(host.prefix(head)) + ellipsis + String(host.suffix(tail))
    }
}
