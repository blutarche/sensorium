#if os(Linux)

import Foundation
import SensoriumLinuxHost

// Opens one portal session on a nested, throwaway desktop, reads 60 frames,
// moves the pointer and types one key, and reports what the portal did. It
// refuses to run unless both the D-Bus address and the Wayland display are
// named explicitly, so it can never reach a real seat by default. It never
// calls the screen saver's Lock.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
guard let busAddress = environment["DBUS_SESSION_BUS_ADDRESS"], !busAddress.isEmpty,
      let display = environment["WAYLAND_DISPLAY"], !display.isEmpty,
      environment["SENSORIUM_PROBE_NESTED"] == "1" else {
    fail("set DBUS_SESSION_BUS_ADDRESS and WAYLAND_DISPLAY to a nested session and SENSORIUM_PROBE_NESTED=1")
}
guard let dataHome = environment["XDG_DATA_HOME"], dataHome.contains("scratch") else {
    fail("XDG_DATA_HOME must point at a scratch directory")
}

do {
    let bus = try GDBusConnecting.connect(address: busAddress)
    print("bus: connected as \(bus.uniqueName)")
    let store = RestoreTokenStore()
    print("restore token before: \(store.load() == nil ? "none" : "present")")

    let saver = ScreenSaverClient(bus: bus)
    print("locked: \(saver.isScreenLocked())")
    print("idle before: \(saver.currentReading())")

    let client = PortalSessionClient(bus: bus, tokenStore: store)
    let session = try await client.openSession()
    print("grant: devices=\(session.grant.devices.rawValue) streams=\(session.grant.streams)")
    print("restore token after: \(store.load() == nil ? "none" : "present")")
    guard let stream = session.grant.streams.first else {
        await session.close()
        fail("the grant named no stream")
    }

    let descriptor = try await session.openPipeWireRemote()
    let counter = FrameCounter()
    let capture = try PipeWireCapture(
        descriptor: descriptor,
        stream: stream,
        onFrame: { counter.record($0) },
        onState: { print("state: \($0)") }
    )
    try capture.start()

    // Move the pointer and press a key once frames are flowing.
    let deadline = Date().addingTimeInterval(20)
    var injected = false
    while counter.count < 60, Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
        if !injected, counter.count > 0 {
            injected = true
            let size = stream.size ?? PortalSize(width: 100, height: 100)
            try session.notifyPointerMotionAbsolute(
                stream: stream.nodeID, x: Double(size.width) / 2, y: Double(size.height) / 2
            )
            try session.notifyKeyboardKeycode(evdevKeycode: 30, pressed: true)
            try session.notifyKeyboardKeycode(evdevKeycode: 30, pressed: false)
            print("injected: pointer move and key A")
            try await Task.sleep(nanoseconds: 500_000_000)
            print("idle after input: \(saver.currentReading())")
        }
    }
    capture.stop()
    print("frames: \(counter.count) first=\(counter.summary)")
    await session.close()
    print("session closed")
    exit(counter.count >= 60 ? 0 : 2)
} catch {
    fail("\(error)")
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var first: CapturedFrame?

    var count: Int { lock.withLock { frames } }
    var summary: String {
        lock.withLock {
            guard let first else { return "none" }
            let bytes = first.pixels?.count ?? 0
            let nonBlack = first.pixels?.contains { $0 != 0 } ?? false
            return "\(first.width)x\(first.height) stride=\(first.stride) format=\(first.format) bytes=\(bytes) nonBlack=\(nonBlack)"
        }
    }

    func record(_ frame: CapturedFrame) {
        lock.withLock {
            frames += 1
            if first == nil, frame.pixels != nil { first = frame }
        }
    }
}

#else

print("SensoriumPortalProbe runs only on Linux")

#endif
