import SensoriumCore

/// Narrow host boundary for virtual-canvas input. Implementations must not
/// target a physical display and are activated only after macOS Accessibility
/// permission has been explicitly granted.
@MainActor
public protocol InputInjecting: AnyObject {
    func inject(_ event: SensoriumInputEvent) throws
}

/// Thrown by an injector that deliberately posted nothing, such as a session
/// canvas while this machine is locked. Nothing changed on this machine, so
/// a caller keeps whatever it tracks as held, exactly as it would after a
/// failed post, but does not count it as a failure.
public struct InputInjectionSuppressed: Error, Equatable {
    public init() {}
}

/// Which kind of session an injector serves. Only a host-screen session may
/// reach this machine's lock screen; a session canvas's input is dropped while
/// the machine is locked.
public enum InputSessionKind: Sendable, Equatable {
    case sessionCanvas
    case hostScreen
}

/// Creates an injector only after the session owns its virtual canvas. This
/// prevents an injector from ever being initialized with a physical display ID.
@MainActor
public protocol InputInjectingFactory: AnyObject {
    func make(canvasDisplayID: UInt32, sessionKind: InputSessionKind) throws -> any InputInjecting
}
