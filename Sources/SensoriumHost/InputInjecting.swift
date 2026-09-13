import SensoriumCore

/// Narrow host boundary for virtual-canvas input. Implementations must not
/// target a physical display and are activated only after macOS Accessibility
/// permission has been explicitly granted.
@MainActor
public protocol InputInjecting: AnyObject {
    func inject(_ event: SensoriumInputEvent) throws
}

/// Creates an injector only after the session owns its virtual canvas. This
/// prevents an injector from ever being initialized with a physical display ID.
@MainActor
public protocol InputInjectingFactory: AnyObject {
    func make(canvasDisplayID: UInt32) throws -> any InputInjecting
}
