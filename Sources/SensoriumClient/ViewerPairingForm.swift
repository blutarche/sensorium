import Foundation

/// Which field a message belongs beside. Pairing has exactly three inputs and
/// every message this type produces names the one it is about, so the window
/// can put it under that field instead of in a shared error line.
public enum ViewerPairingField: Equatable, Sendable {
    case address
    case code
    case name
}

/// One field's verdict as the user types. `message` is `nil` while the field is
/// still empty: nothing typed yet is not yet a mistake, and a form that shouts
/// at an untouched field teaches the user to ignore it.
public struct ViewerPairingFieldState: Equatable, Sendable {
    public let isValid: Bool
    public let message: String?

    public init(isValid: Bool, message: String?) {
        self.isValid = isValid
        self.message = message
    }
}

/// What the socket needs, taken out of the one address the user typed.
public struct ViewerPairingAddress: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// A complete, valid form — the only thing the window is allowed to dial with.
public struct ViewerPairingSubmission: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let code: String
    /// What every window title, status line and error says from here on. The
    /// user's name for the machine when they gave one, its address when they did
    /// not.
    public let displayName: String

    public init(host: String, port: UInt16, code: String, displayName: String) {
        self.host = host
        self.port = port
        self.code = code
        self.displayName = displayName
    }
}

/// The pairing form's whole rulebook: what counts as an address, what counts as
/// a code, and what the machine ends up called. Deliberately AppKit-free — the
/// window holds three text fields and this holds every decision, so the rules
/// are verified without a window.
public struct ViewerPairingForm: Equatable, Sendable {
    /// The port the packaged launchers pass. Typed only when the host was
    /// started on a different one, as `address:port`.
    public static let defaultPort: UInt16 = 7777

    public var address: String
    public var code: String
    public var name: String

    public init(address: String = "", code: String = "", name: String = "") {
        self.address = address
        self.code = code
        self.name = name
    }

    public var addressState: ViewerPairingFieldState {
        let raw = Self.trimmed(address)
        guard !raw.isEmpty else {
            return ViewerPairingFieldState(isValid: false, message: nil)
        }
        if raw.contains("://") {
            return .invalid(Message.addressScheme)
        }
        if raw.contains("/") {
            return .invalid(Message.addressSlash)
        }
        if raw.contains(where: \.isWhitespace) {
            return .invalid(Message.addressSpace)
        }
        if raw.contains("@") {
            return .invalid(Message.addressUser)
        }
        guard let split = Self.split(raw) else {
            return .invalid(Message.addressBracket)
        }
        if let portText = split.portText {
            guard let port = UInt16(portText), port > 0 else {
                return .invalid(Message.addressPort)
            }
        }
        guard Self.isPlausibleHost(split.host) else {
            return .invalid(Message.addressImplausible)
        }
        return ViewerPairingFieldState(isValid: true, message: nil)
    }

    public var codeState: ViewerPairingFieldState {
        let raw = Self.trimmed(code)
        guard !raw.isEmpty else {
            return ViewerPairingFieldState(isValid: false, message: nil)
        }
        guard raw.allSatisfy({ Self.isDigit($0) || Self.isGroupSeparator($0) }) else {
            return .invalid(Message.codeCharacters)
        }
        let digits = Self.digits(in: raw)
        if digits.count < Self.codeLength {
            return .invalid(Message.codeMissing(Self.codeLength - digits.count))
        }
        if digits.count > Self.codeLength {
            return .invalid(Message.codeTooLong(digits.count))
        }
        return ViewerPairingFieldState(isValid: true, message: nil)
    }

    /// True while a code is short of six digits and every character typed so
    /// far is a real one -- the "counting down" state `codeState` names with
    /// `Message.codeMissing`, as opposed to a genuine mistake (a stray
    /// character, or more than six digits). The window uses this to decide
    /// whether the count-down message is progress, not yet an error worth
    /// painting red.
    public var codeIsStillTyping: Bool {
        let raw = Self.trimmed(code)
        guard !raw.isEmpty, raw.allSatisfy({ Self.isDigit($0) || Self.isGroupSeparator($0) }) else {
            return false
        }
        return Self.digits(in: raw).count < Self.codeLength
    }

    public var parsedAddress: ViewerPairingAddress? {
        guard addressState.isValid, let split = Self.split(Self.trimmed(address)) else {
            return nil
        }
        let port = split.portText.flatMap(UInt16.init) ?? Self.defaultPort
        return ViewerPairingAddress(host: split.host, port: port)
    }

    /// The one field that improves every later string in the product: without
    /// it the saved host is called by its bare address in every window title,
    /// status line and error message.
    public var resolvedDisplayName: String? {
        guard let parsedAddress else { return nil }
        let name = Self.trimmed(name)
        return name.isEmpty ? parsedAddress.host : name
    }

    public var submission: ViewerPairingSubmission? {
        guard codeState.isValid,
              let parsedAddress,
              let displayName = resolvedDisplayName else {
            return nil
        }
        return ViewerPairingSubmission(
            host: parsedAddress.host,
            port: parsedAddress.port,
            code: Self.digits(in: code),
            displayName: displayName
        )
    }

    public var canSubmit: Bool { submission != nil }

    /// Every message a field can put under itself. The window reserves the
    /// height of the tallest one, so a message appearing never moves the
    /// fields below it.
    ///
    /// The over-long code message is listed up to fifteen digits; past that
    /// the count is written in numerals, which is shorter than any of the
    /// words here and so cannot be the tallest.
    public static func possibleMessages(for field: ViewerPairingField) -> [String] {
        switch field {
        case .address:
            return [
                Message.addressScheme,
                Message.addressSlash,
                Message.addressSpace,
                Message.addressUser,
                Message.addressBracket,
                Message.addressPort,
                Message.addressImplausible
            ]
        case .code:
            return [Message.codeCharacters]
                + (1...codeLength).map(Message.codeMissing)
                + ((codeLength + 1)...15).map(Message.codeTooLong)
        case .name:
            return []
        }
    }

    /// What the code field shows as the user types, grouped the same way the
    /// host panel shows it — `418 297` — so someone typing what they see on
    /// the other screen sees it back. Pure so the window's own live
    /// reformatting is verified without a field editor; separators already
    /// in `raw` are dropped and reinserted in one place, so retyping over a
    /// selection never doubles one up.
    public static func groupedCodeDisplay(_ raw: String) -> String {
        let digits = Self.digits(in: raw)
        guard digits.count > 3 else { return digits }
        let index = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<index]) \(digits[index...])"
    }

    /// Stated once, in one place, because the window reserves height from the
    /// same strings the form produces. Two copies would drift and the form
    /// would start reflowing again.
    private enum Message {
        static let addressScheme = "Type only the address, without http:// in front of it."
        static let addressSlash = "Type only the address, with nothing after a slash."
        static let addressSpace = "An address has no spaces in it. Check for a stray one."
        static let addressUser = "Type only the address \u{2014} no user name and @ in front of it."
        static let addressBracket = "That address opens a bracket and never closes it."
        static let addressPort = "The port after the colon must be a whole number from 1 to 65535."
        static let addressImplausible =
            "The other machine\u{2019}s Tailscale address, which starts with 100, or a name such as "
            + "mini.local or mini.tail1234.ts.net."
        static let codeCharacters = "The code is six digits and nothing else."

        static func codeMissing(_ count: Int) -> String {
            "Six digits \u{2014} \(ViewerPairingForm.spell(count)) more to type."
        }

        static func codeTooLong(_ count: Int) -> String {
            "The code is exactly six digits; that is \(ViewerPairingForm.spell(count))."
        }
    }

    private static let codeLength = 6

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ASCII only. `Character.isNumber` is true of digits from every script,
    /// and an Arabic-Indic six would go onto the wire and be refused by a host
    /// that only ever issues `0`-`9`.
    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The host shows the code in two groups of three, because that is how a
    /// person reads six digits aloud. Someone will type what they see, so a
    /// space or a hyphen between the groups is not a mistake — it is just not
    /// part of the code.
    private static func isGroupSeparator(_ character: Character) -> Bool {
        character == " " || character == "-"
    }

    private static func digits(in value: String) -> String {
        String(value.filter(isDigit))
    }

    /// Splits `host`, `host:port` and `[v6]:port` — and leaves a bare IPv6
    /// literal alone, since every colon in it belongs to the address. `nil`
    /// only for a bracket that is never closed.
    private static func split(_ raw: String) -> (host: String, portText: String?)? {
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return nil }
            let host = String(raw[raw.index(after: raw.startIndex)..<close])
            let rest = String(raw[raw.index(after: close)...])
            if rest.isEmpty { return (host, nil) }
            guard rest.hasPrefix(":") else { return nil }
            return (host, String(rest.dropFirst()))
        }
        let colons = raw.filter { $0 == ":" }.count
        guard colons == 1, let separator = raw.firstIndex(of: ":") else {
            // Zero colons: a name or an IPv4 literal. More than one: an
            // unbracketed IPv6 literal, which cannot carry a port.
            return (stripTrailingDot(raw), nil)
        }
        return (stripTrailingDot(String(raw[raw.startIndex..<separator])), String(raw[raw.index(after: separator)...]))
    }

    /// A MagicDNS name is a fully-qualified domain name, and Tailscale's own
    /// tooling shows it with the trailing dot that implies (`mini.tail1234.
    /// ts.net.`). Someone retyping what they see would carry that dot in;
    /// stripped here, once, so every caller of `split` sees the same host an
    /// unqualified name would produce. Left alone for an IPv6 literal, which
    /// is never dot-delimited this way.
    private static func stripTrailingDot(_ host: String) -> String {
        guard !host.contains(":"), host.hasSuffix(".") else { return host }
        return String(host.dropLast())
    }

    /// Syntax only. Whether anything answers there is the network's answer,
    /// not this form's — the point is to catch the typo before a five-second
    /// dial does.
    private static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.contains(":") {
            // An IPv6 literal, possibly with a `%interface` zone.
            return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }
        }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty
                && label.count <= 63
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && label.first != "-"
                && label.last != "-"
        }
    }

    private static let spelledNumbers = [
        "zero", "one", "two", "three", "four", "five",
        "six", "seven", "eight", "nine", "ten"
    ]

    fileprivate static func spell(_ number: Int) -> String {
        spelledNumbers.indices.contains(number) ? spelledNumbers[number] : String(number)
    }
}

private extension ViewerPairingFieldState {
    static func invalid(_ message: String) -> ViewerPairingFieldState {
        ViewerPairingFieldState(isValid: false, message: message)
    }
}
