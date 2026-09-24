import Foundation
import SensoriumClient
import SensoriumCore

#if canImport(AppKit)
import AppKit

/// A host that reports its screen locked changes nothing about where the
/// macOS viewer's keys go: the person types into the lock screen in the
/// picture, and every key, Return included, reaches the transport exactly as
/// it would at an unlocked host.
///
/// Driven through a real `CanvasSurfaceView` and the three overrides AppKit
/// calls, so a view that started holding keys back fails here.
@MainActor
func testHostScreenUnlockClientTests() async {
    let (sent, endedReason) = await runnerAfterLockedHostReport()
    expect(
        !sent.contains { if case .hostScreenUnlockRequest = $0 { true } else { false } },
        "a locked host makes the viewer send no unlock request -- sent: \(sent)"
    )
    expect(
        endedReason == "\(ControlChannelError.closed)",
        "and neither the lock report nor the unlock answer ends the session -- ended: \(endedReason ?? "<never>")"
    )

    let sink = RecordingInputSink()
    let viewport = ClientViewportController(
        mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
        pointerSink: sink
    )
    await viewport.canvasDidBecomeReady()
    let router = CanvasSurfaceEventRouter(viewport: viewport)
    await router.route(.boundsChanged(width: 1920, height: 1200))
    let view = CanvasSurfaceView(
        router: router,
        shortcutRouter: SystemShortcutRouter(mode: .remoteWhenFocused),
        accessibilityGranted: false,
        surfaceID: 0
    )
    // The window a test has no window server to make key.
    view.windowStateProvider = {
        ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    }

    func event(
        _ type: NSEvent.EventType,
        _ keyCode: UInt16,
        _ characters: String,
        _ flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// The events the view queues reach the transport on the main actor, so
    /// letting it run is what gives the sink everything it is owed.
    func settle() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    func type(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) async {
        view.keyDown(with: event(.keyDown, keyCode, characters, flags))
        view.keyUp(with: event(.keyUp, keyCode, characters, flags))
        await settle()
    }

    await type(0, "a")
    await type(36, "\r")
    view.flagsChanged(with: event(.flagsChanged, 56, "", [.shift]))
    await settle()
    await type(0, "A", [.shift])
    view.flagsChanged(with: event(.flagsChanged, 56, "", []))
    await settle()

    let keys = await sink.keys
    let expected: [SensoriumInputEvent] = [
        .key(keyCode: 0, isDown: true, modifiers: []),
        .key(keyCode: 0, isDown: false, modifiers: []),
        .key(keyCode: 36, isDown: true, modifiers: []),
        .key(keyCode: 36, isDown: false, modifiers: []),
        .key(keyCode: 56, isDown: true, modifiers: [.shift]),
        .key(keyCode: 0, isDown: true, modifiers: [.shift]),
        .key(keyCode: 0, isDown: false, modifiers: [.shift]),
        .key(keyCode: 56, isDown: false, modifiers: []),
    ]
    expect(
        keys == expected,
        "every key and modifier typed at a locked host reaches the transport unchanged -- got \(keys)"
    )
    print("PASS: the macOS key path sends a locked host every key, Return and modifiers included, and no unlock request")
}
#endif
