import Foundation
import SensoriumClient
import SensoriumCore

/// A compositor that records the inhibitor requests instead of answering
/// them, so the interceptor's own state is checkable without a seat or a
/// surface.
@MainActor
private final class ScriptedShortcutInhibitor: WaylandShortcutInhibiting {
    private(set) var requestCount = 0
    private(set) var destroyCount = 0

    func requestShortcutInhibitor() -> Bool {
        requestCount += 1
        return true
    }

    func destroyShortcutInhibitor() {
        destroyCount += 1
    }
}

/// The Wayland side of shortcut forwarding: the compositor is asked to stop
/// taking its own chords, and only once it says it has do reserved chords
/// count as claimed here.
@MainActor
func testWaylandShortcutInterceptorTests() {
    let compositor = ScriptedShortcutInhibitor()
    let interceptor = WaylandShortcutInterceptor(inhibiting: compositor)
    var claimed: [KeyChord] = []
    var degraded: [String] = []
    let quit = KeyChord(keyCode: 12, modifiers: [.command])

    do {
        try interceptor.start({ chord, _ in
            claimed.append(chord)
            return true
        }, onDegraded: { degraded.append($0) })
    } catch {
        expect(false, "starting the Wayland shortcut interceptor threw \(error)")
        return
    }
    expect(compositor.requestCount == 1, "starting asks the compositor to inhibit its shortcuts")
    expect(
        !interceptor.claim(chord: quit, isDown: true),
        "a chord arriving before the compositor answered is not claimed"
    )
    expect(claimed.isEmpty, "a chord arriving before the compositor answered never reaches the forwarder")

    interceptor.inhibitorBecameActive()
    expect(interceptor.claim(chord: quit, isDown: true), "an inhibited chord is claimed for the host")
    expect(claimed == [quit], "an inhibited chord reaches the forwarder")

    interceptor.inhibitorBecameInactive()
    expect(
        degraded == ["the compositor is keeping its shortcuts; reserved chords stay local until the viewer window is focused again"],
        "a compositor keeping its shortcuts is reported once"
    )
    expect(!interceptor.claim(chord: quit, isDown: true), "a chord is not claimed while the compositor keeps its own")
    expect(claimed == [quit], "a chord the compositor kept never reaches the forwarder")
    expect(
        compositor.destroyCount == 1,
        "an inhibitor the compositor stopped honouring is destroyed, since a surface may hold only one"
    )

    interceptor.keyboardDidEnter()
    expect(compositor.requestCount == 2, "the inhibitor is asked for again the next time this window is typed into")
    interceptor.inhibitorBecameActive()
    interceptor.keyboardDidEnter()
    expect(compositor.requestCount == 2, "an inhibitor that is already held is not asked for twice")

    interceptor.stop()
    expect(compositor.destroyCount == 2, "stopping destroys the inhibitor")
    interceptor.stop()
    expect(compositor.destroyCount == 2, "stopping twice destroys nothing twice")
    expect(!interceptor.claim(chord: quit, isDown: true), "a stopped interceptor claims nothing")

    print("PASS: the Wayland shortcut interceptor claims reserved chords only while the compositor is inhibited, and reports when it is not")
}

/// Regression test: a fresh `start()` must not inherit `isInhibitActive` from
/// an inhibitor a previous session left active. Without resetting the flag, a
/// chord could be claimed for the host before the new inhibitor's own
/// `active` event ever arrives.
@MainActor
func testWaylandShortcutInterceptorRestartTests() {
    let compositor = ScriptedShortcutInhibitor()
    let interceptor = WaylandShortcutInterceptor(inhibiting: compositor)
    let quit = KeyChord(keyCode: 12, modifiers: [.command])

    do {
        try interceptor.start({ _, _ in true }, onDegraded: { _ in })
    } catch {
        expect(false, "starting the Wayland shortcut interceptor threw \(error)")
        return
    }
    interceptor.inhibitorBecameActive()
    expect(interceptor.claim(chord: quit, isDown: true), "an inhibited chord is claimed for the host")

    do {
        try interceptor.start({ _, _ in true }, onDegraded: { _ in })
    } catch {
        expect(false, "restarting the Wayland shortcut interceptor threw \(error)")
        return
    }
    expect(
        !interceptor.claim(chord: quit, isDown: true),
        "a chord arriving before the new inhibitor's own active event is not claimed, even though the previous one was active"
    )

    print("PASS: restarting the Wayland shortcut interceptor does not carry over a previous inhibitor's active state")
}

/// A second display window has its own surface, so it needs its own inhibitor
/// to keep the compositor's shortcuts away while it has the keyboard. It
/// shares the session's forwarder with the first window, so a chord it
/// receives is claimed through the same handler.
@MainActor
func testWaylandShortcutInterceptorFollowerTests() {
    let primaryCompositor = ScriptedShortcutInhibitor()
    let secondCompositor = ScriptedShortcutInhibitor()
    let primary = WaylandShortcutInterceptor(inhibiting: primaryCompositor)
    let second = WaylandShortcutInterceptor(inhibiting: secondCompositor, leader: primary)
    var claimed: [KeyChord] = []
    var degraded: [String] = []
    let quit = KeyChord(keyCode: 12, modifiers: [.command])

    second.keyboardDidEnter()
    expect(secondCompositor.requestCount == 0, "a second window asks for nothing while no session is forwarding shortcuts")

    do {
        try primary.start({ chord, _ in
            claimed.append(chord)
            return true
        }, onDegraded: { degraded.append($0) })
    } catch {
        expect(false, "starting the Wayland shortcut interceptor threw \(error)")
        return
    }
    expect(secondCompositor.requestCount == 0, "starting the session asks for the first window's inhibitor only")

    second.keyboardDidEnter()
    expect(secondCompositor.requestCount == 1, "the second window asks the compositor to inhibit when it gets the keyboard")
    expect(!second.claim(chord: quit, isDown: true), "a chord before the compositor answered the second window is not claimed")

    second.inhibitorBecameActive()
    expect(second.claim(chord: quit, isDown: true), "a chord in the second window is claimed for the host")
    expect(claimed == [quit], "it reaches the session's forwarder")
    expect(!primary.claim(chord: quit, isDown: true), "the first window's own inhibitor state is untouched")

    second.inhibitorBecameInactive()
    expect(degraded.count == 1, "the second window losing its inhibitor is reported through the session")
    expect(secondCompositor.destroyCount == 1, "and destroys the second window's inhibitor, not the first window's")
    expect(primaryCompositor.destroyCount == 0, "the first window's inhibitor is left alone")

    primary.stop()
    second.keyboardDidEnter()
    expect(secondCompositor.requestCount == 1, "once the session stops forwarding the second window asks for nothing")

    print("PASS: a second display window inhibits the compositor's shortcuts through the session's forwarder")
}
