#if os(Linux)

import Foundation
import SensoriumCore
import SensoriumHost

/// Builds each connection's input injector on its portal grant. It builds
/// one only for the requested monitor while that grant covers keyboard and
/// pointer.
@MainActor
public final class PortalInputInjectorFactory: InputInjectingFactory {
    private let grantState: PortalGrantState
    private let generation: UInt64?
    private let observer: PortalInputPostObserver

    /// `observer` sees every post, so local-activity readings can discount
    /// the host's own input.
    public init(grantState: PortalGrantState, observer: PortalInputPostObserver = PortalInputPostObserver()) {
        self.grantState = grantState
        generation = grantState.live?.generation
        self.observer = observer
    }

    public var isAvailable: Bool {
        guard let live = grantState.live, live.generation == generation else { return false }
        return live.grantsInput && !live.routableMonitors.isEmpty
    }

    public func make(canvasDisplayID: UInt32, sessionKind: InputSessionKind) throws -> any InputInjecting {
        guard sessionKind == .hostScreen,
              let live = grantState.live,
              live.generation == generation,
              live.grantsInput,
              let geometry = live.routableMonitors.first(where: { $0.geometry.displayIdentity == canvasDisplayID })?.geometry else {
            throw HostSessionControllerError.inputInjectionUnavailable
        }
        let sink = GrantBoundInputSink(inner: live.sink, grantState: grantState, generation: live.generation)
        return PortalHostInputInjector(PortalInputInjector(sink: sink, geometry: geometry, observer: observer))
    }
}

/// The shared session's view of one portal injector.
@MainActor
final class PortalHostInputInjector: InputInjecting {
    private let injector: PortalInputInjector

    init(_ injector: PortalInputInjector) {
        self.injector = injector
    }

    func inject(_ event: SensoriumInputEvent) throws {
        try injector.inject(event)
    }
}

/// Passes input to the portal only while the grant it was built under is
/// still the open one.
private struct GrantBoundInputSink: PortalInputSink {
    let inner: any PortalInputSink
    let grantState: PortalGrantState
    let generation: UInt64

    private func requireOpen() throws {
        guard grantState.isCurrent(generation) else {
            throw PortalError.sessionClosed
        }
    }

    func notifyPointerMotionAbsolute(stream: UInt32, x: Double, y: Double) throws {
        try requireOpen()
        try inner.notifyPointerMotionAbsolute(stream: stream, x: x, y: y)
    }

    func notifyPointerMotion(dx: Double, dy: Double) throws {
        try requireOpen()
        try inner.notifyPointerMotion(dx: dx, dy: dy)
    }

    func notifyPointerButton(evdevButton: Int32, pressed: Bool) throws {
        try requireOpen()
        try inner.notifyPointerButton(evdevButton: evdevButton, pressed: pressed)
    }

    func notifyPointerAxis(dx: Double, dy: Double, finish: Bool) throws {
        try requireOpen()
        try inner.notifyPointerAxis(dx: dx, dy: dy, finish: finish)
    }

    func notifyPointerAxisDiscrete(axis: PortalAxis, steps: Int32) throws {
        try requireOpen()
        try inner.notifyPointerAxisDiscrete(axis: axis, steps: steps)
    }

    func notifyKeyboardKeycode(evdevKeycode: Int32, pressed: Bool) throws {
        try requireOpen()
        try inner.notifyKeyboardKeycode(evdevKeycode: evdevKeycode, pressed: pressed)
    }
}

#endif
