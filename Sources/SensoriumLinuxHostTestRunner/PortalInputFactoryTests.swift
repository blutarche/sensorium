#if os(Linux)

import Foundation
import SensoriumCore
import SensoriumHost
import SensoriumLinuxHost

let grantedMonitor = PortalStream(
    nodeID: 57,
    id: "monitor-a",
    position: PortalPoint(x: 0, y: 0),
    size: PortalSize(width: 1920, height: 1080)
)

func liveGrant(
    devices: PortalDevices = [.keyboard, .pointer],
    streams: [PortalStream] = [grantedMonitor]
) -> PortalGrant {
    PortalGrant(
        sessionHandle: "/org/freedesktop/portal/desktop/session/1_1/a",
        devices: devices,
        streams: streams,
        restoreToken: nil
    )
}

@MainActor
private func testTheFactoryIsAvailableOnlyWhileTheGrantIsLiveWithKeyboardAndPointer() async {
    let state = PortalGrantState()
    let factory = PortalInputInjectorFactory(grantState: state)
    expect(!factory.isAvailable, "no grant yet, no injector")

    state.install(grant: liveGrant(devices: [.pointer]), sink: RecordingSink())
    expect(!factory.isAvailable, "a grant without the keyboard cannot type a password, so input is off")

    state.install(grant: liveGrant(), sink: RecordingSink())
    expect(factory.isAvailable, "a live grant with keyboard and pointer builds injectors")

    state.end()
    expect(!factory.isAvailable, "an ended portal session builds none")
}

@MainActor
private func testTheFactoryBuildsForTheGrantedMonitorAndRefusesAnythingElse() async {
    let state = PortalGrantState()
    let sink = RecordingSink()
    state.install(grant: liveGrant(), sink: sink)
    let factory = PortalInputInjectorFactory(grantState: state)
    let identity = PortalCaptureGeometry(stream: grantedMonitor)!.displayIdentity

    do {
        _ = try factory.make(canvasDisplayID: identity, sessionKind: .sessionCanvas)
        expect(false, "a session canvas has no Linux counterpart, so no injector is built for one")
    } catch {}
    do {
        _ = try factory.make(canvasDisplayID: identity &+ 1, sessionKind: .hostScreen)
        expect(false, "a display other than the granted monitor gets no injector")
    } catch {}

    do {
        let injector = try factory.make(canvasDisplayID: identity, sessionKind: .hostScreen)
        try injector.inject(.pointerMoved(x: 960, y: 540))
        try injector.inject(.key(keyCode: 0, isDown: true, modifiers: [], capsLock: false))
        try injector.inject(.key(keyCode: 0, isDown: false, modifiers: [], capsLock: false))
    } catch {
        expect(false, "the granted monitor's injector posts input, threw \(error)")
    }
    expect(
        sink.events == [.absolute(stream: 57, x: 960, y: 540), .key(30, true), .key(30, false)],
        "input reaches the portal on the granted stream in logical points, saw \(sink.events)"
    )
}

@MainActor
private func testAnInjectorStopsPostingOnceThePortalSessionEnds() async {
    let state = PortalGrantState()
    let sink = RecordingSink()
    state.install(grant: liveGrant(), sink: sink)
    let factory = PortalInputInjectorFactory(grantState: state)
    let identity = PortalCaptureGeometry(stream: grantedMonitor)!.displayIdentity
    guard let injector = try? factory.make(canvasDisplayID: identity, sessionKind: .hostScreen) else {
        expect(false, "the injector was built")
        return
    }
    state.end()
    do {
        try injector.inject(.pointerMoved(x: 10, y: 10))
        expect(false, "an injector built under an ended grant posts nothing")
    } catch {}
    expect(sink.events.isEmpty, "nothing reached the portal after the session ended")
}

func portalInputFactoryTests() -> [NamedTest] { [
    (
        "the input factory is available only while the grant is live with keyboard and pointer",
        testTheFactoryIsAvailableOnlyWhileTheGrantIsLiveWithKeyboardAndPointer
    ),
    (
        "the input factory builds for the granted monitor and refuses anything else",
        testTheFactoryBuildsForTheGrantedMonitorAndRefusesAnythingElse
    ),
    ("an injector stops posting once the portal session ends", testAnInjectorStopsPostingOnceThePortalSessionEnds)
] }

#endif
