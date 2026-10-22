/// What one host-screen session's input path says about itself in the
/// session log: whether the screen is locked, which event tap input is
/// posted at, and whether Accessibility is on, at the session's first
/// forwarded event and again whenever the lock state has changed since;
/// and why input was dropped, once per session for each cause.
///
/// Every line is fixed text chosen from the cases below. None carries a key
/// code, a character, modifier state, a pointer position, or anything else
/// derived from the input itself: while the screen is locked, what the
/// viewer types is a password.
///
/// The tap named is the one `CoreGraphicsInputInjector` chooses for a
/// host-screen session from the same lock reading: the HID tap while
/// locked, the session tap otherwise. A lock change is noticed at the next
/// forwarded event, not when it happens.
struct HostScreenInputDiagnostics {
    enum DropCause: Hashable {
        case accessibilityOff
        case noInjector
        case eventNotCreated
        case displayGone
        case eventNotPosted

        var words: String {
            switch self {
            case .accessibilityOff: "Accessibility is off"
            case .noInjector: "no input injector could be made"
            case .eventNotCreated: "an event could not be created"
            case .displayGone: "the display is gone"
            case .eventNotPosted: "an event could not be posted"
            }
        }

        init(failure: any Error) {
            switch failure as? CoreGraphicsInputInjectorError {
            case .eventCreationFailed, .eventSourceUnavailable: self = .eventNotCreated
            case .canvasDisplayUnavailable: self = .displayGone
            case nil: self = .eventNotPosted
            }
        }
    }

    private var lastLockState: Bool?
    private var loggedDrops: Set<DropCause> = []

    /// The line for a forwarded event arriving while the screen is `locked`,
    /// or `nil` when there is nothing new to say.
    mutating func input(locked: Bool, accessibilityTrusted: () -> Bool) -> String? {
        defer { lastLockState = locked }
        let tap = locked ? "posting at the HID tap" : "posting at the session tap"
        guard let lastLockState else {
            let accessibility = accessibilityTrusted() ? "on" : "off"
            return "host screen input: \(locked ? "locked" : "unlocked"), \(tap), Accessibility \(accessibility)"
        }
        guard locked != lastLockState else { return nil }
        return "host screen input: now \(locked ? "locked" : "unlocked"), \(tap)"
    }

    /// The line for input dropped for `cause`, or `nil` when this session
    /// has already said so.
    mutating func dropped(_ cause: DropCause) -> String? {
        guard loggedDrops.insert(cause).inserted else { return nil }
        return "host screen input dropped: \(cause.words)"
    }
}
