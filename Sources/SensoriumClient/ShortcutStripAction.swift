import SensoriumCore

/// The words a disruptive action asks before it fires. The way out is spelled
/// the same for every one of them, so it is not something a case can get wrong.
public struct ShortcutStripConfirmation: Equatable, Sendable {
    public let question: String
    public let confirmTitle: String
    public let cancelTitle = "Cancel"

    public init(question: String, confirmTitle: String) {
        self.question = question
        self.confirmTitle = confirmTitle
    }
}

/// One button on the viewer's shortcut strip.
///
/// Each of these is a chord the viewer's own machine takes for itself -- a
/// gesture, a system hotkey -- so it never reaches the window showing the far
/// screen. Pressing the button sends the same chord as ordinary key events to
/// the machine being worked on. Nothing here reads or synthesises a local event:
/// the sequence is produced whole and handed to the input path that already
/// carries typing.
public enum ShortcutStripAction: CaseIterable, Equatable, Sendable {
    case missionControl
    case applicationWindows
    case desktopLeft
    case desktopRight
    case showDesktop
    case spotlight
    case launchpad
    case switchApp
    case lockScreen
    case quitApp

    /// The button's own label. Short: the strip is one row across the top of a
    /// window whose whole point is the picture underneath it.
    public var title: String {
        switch self {
        case .missionControl: "Mission Control"
        case .applicationWindows: "App Windows"
        case .desktopLeft: "Desktop Left"
        case .desktopRight: "Desktop Right"
        case .showDesktop: "Show Desktop"
        case .spotlight: "Spotlight"
        case .launchpad: "Launchpad"
        case .switchApp: "Switch App"
        case .lockScreen: "Lock Screen"
        case .quitApp: "Quit App"
        }
    }

    /// The SF Symbol drawn on the button, chosen to match the glyph macOS
    /// itself uses for the same idea where one exists.
    public var symbolName: String {
        switch self {
        case .missionControl: "rectangle.3.group"
        case .applicationWindows: "macwindow.stack"
        case .desktopLeft: "arrow.left.square"
        case .desktopRight: "arrow.right.square"
        case .showDesktop: "menubar.dock.rectangle"
        case .spotlight: "magnifyingglass"
        case .launchpad: "square.grid.3x3.fill"
        case .switchApp: "arrow.left.arrow.right.square"
        case .lockScreen: "lock.fill"
        case .quitApp: "xmark.circle"
        }
    }

    /// What is sent, in the spelling macOS itself uses for a chord.
    public var chordDescription: String {
        switch self {
        case .missionControl: "Control-Up"
        case .applicationWindows: "Control-Down"
        case .desktopLeft: "Control-Left"
        case .desktopRight: "Control-Right"
        case .showDesktop: "F11"
        case .spotlight: "Command-Space"
        case .launchpad: "the Launchpad key"
        case .switchApp: "Command-Tab"
        case .lockScreen: "Control-Command-Q"
        case .quitApp: "Command-Q"
        }
    }

    /// Names both halves of what a press does, because neither is obvious from
    /// a two-word label: which keys go out, and which machine receives them.
    public func tooltip(hostName: String) -> String {
        "Sends \(chordDescription) to \(hostName)"
    }

    /// Locking the far machine, or quitting the app in front of it, is disruptive
    /// enough that a mis-click must not do it. Everything else fires at once.
    public var needsConfirmation: Bool {
        self == .lockScreen || self == .quitApp
    }

    public func confirmation(hostName: String) -> ShortcutStripConfirmation? {
        switch self {
        case .lockScreen:
            ShortcutStripConfirmation(question: "Lock \(hostName)?", confirmTitle: "Lock")
        case .quitApp:
            ShortcutStripConfirmation(question: "Quit the app in front on \(hostName)?", confirmTitle: "Quit")
        default:
            nil
        }
    }

    /// The whole chord, in order: each modifier down, the main key down and up,
    /// then the modifiers up in the reverse of the order they went down. Built
    /// as one array and sent in one call, so a chord cannot be half-delivered
    /// and leave a modifier held on a machine nobody is sitting at.
    public func events() -> [SensoriumInputEvent] {
        var events: [SensoriumInputEvent] = []
        var held: CanvasModifierFlags = []
        for keyCode in chord.modifierKeyCodes {
            held.insert(Self.flag(forModifier: keyCode))
            events.append(.key(keyCode: keyCode, isDown: true, modifiers: held))
        }
        events.append(.key(keyCode: chord.keyCode, isDown: true, modifiers: held))
        events.append(.key(keyCode: chord.keyCode, isDown: false, modifiers: held))
        for keyCode in chord.modifierKeyCodes.reversed() {
            held.remove(Self.flag(forModifier: keyCode))
            events.append(.key(keyCode: keyCode, isDown: false, modifiers: held))
        }
        return events
    }

    private struct Chord {
        let modifierKeyCodes: [UInt16]
        let keyCode: UInt16
    }

    private var chord: Chord {
        switch self {
        case .missionControl: Chord(modifierKeyCodes: [VirtualKey.control], keyCode: VirtualKey.arrowUp)
        case .applicationWindows: Chord(modifierKeyCodes: [VirtualKey.control], keyCode: VirtualKey.arrowDown)
        case .desktopLeft: Chord(modifierKeyCodes: [VirtualKey.control], keyCode: VirtualKey.arrowLeft)
        case .desktopRight: Chord(modifierKeyCodes: [VirtualKey.control], keyCode: VirtualKey.arrowRight)
        case .showDesktop: Chord(modifierKeyCodes: [], keyCode: VirtualKey.f11)
        case .spotlight: Chord(modifierKeyCodes: [VirtualKey.command], keyCode: VirtualKey.space)
        case .launchpad: Chord(modifierKeyCodes: [], keyCode: VirtualKey.launchpad)
        case .switchApp: Chord(modifierKeyCodes: [VirtualKey.command], keyCode: VirtualKey.tab)
        case .lockScreen:
            Chord(modifierKeyCodes: [VirtualKey.control, VirtualKey.command], keyCode: VirtualKey.letterQ)
        case .quitApp: Chord(modifierKeyCodes: [VirtualKey.command], keyCode: VirtualKey.letterQ)
        }
    }

    private static func flag(forModifier keyCode: UInt16) -> CanvasModifierFlags {
        switch keyCode {
        case VirtualKey.command: .command
        case VirtualKey.control: .control
        case VirtualKey.shift: .shift
        case VirtualKey.option: .option
        default: []
        }
    }
}

/// Carbon virtual key codes, the vocabulary the protocol's `keyCode` already
/// speaks. `launchpad` is the exception: macOS reports 131 for that key, and
/// Carbon has no constant for it.
private enum VirtualKey {
    static let letterQ: UInt16 = 12
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let command: UInt16 = 55
    static let shift: UInt16 = 56
    static let option: UInt16 = 58
    static let control: UInt16 = 59
    static let f11: UInt16 = 103
    static let arrowLeft: UInt16 = 123
    static let arrowRight: UInt16 = 124
    static let arrowDown: UInt16 = 125
    static let arrowUp: UInt16 = 126
    static let launchpad: UInt16 = 131
}
