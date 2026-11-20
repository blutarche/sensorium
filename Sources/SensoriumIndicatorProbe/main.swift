import Foundation
#if os(Linux)
import CGLib
import SensoriumLinuxHost

/// Shows the live-session indicator for a sample device name, so it can be
/// looked at without a session. Test scaffolding, not part of the product.
///
///     SensoriumIndicatorProbe --png PATH [--device NAME] [--appearance dark|light] [--scale F]
///
/// draws the corner pill into a PNG and exits.
///
///     SensoriumIndicatorProbe --show [--device NAME] [--seconds N]
///
/// shows the pill and the tray item on the Wayland display this process was
/// started in, and stops after N seconds or when Stop is pressed. It refuses to
/// run unless `WAYLAND_DISPLAY` names a socket explicitly, so a forgotten
/// variable can never put the pill on the desktop of whoever is logged in.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
    exit(2)
}

var device = "Studio Desktop"
var appearance = IndicatorAppearance.dark
var scale = 1.0
var seconds = 8
var png: String?
var show = false

var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    func value() -> String {
        guard let next = arguments.popFirst() else { fail("\(flag) needs a value") }
        return next
    }
    switch flag {
    case "--device": device = value()
    case "--appearance":
        guard let chosen = IndicatorAppearance(rawValue: value()) else { fail("--appearance is dark or light") }
        appearance = chosen
    case "--scale":
        guard let chosen = Double(value()), chosen > 0 else { fail("--scale needs a positive number") }
        scale = chosen
    case "--seconds":
        guard let chosen = Int(value()), chosen > 0 else { fail("--seconds needs a positive number") }
        seconds = chosen
    case "--png": png = value()
    case "--show": show = true
    default: fail("unknown option \(flag)")
    }
}

var shownIndicator: LinuxHostIndicator?
nonisolated(unsafe) var mainLoop: OpaquePointer?

func endRun(_ reason: String) {
    print("probe: \(reason)")
    MainActor.assumeIsolated {
        shownIndicator?.hide()
        shownIndicator = nil
    }
    if let mainLoop { g_main_loop_quit(mainLoop) }
}

@MainActor
func runShow(display: String) {
    let indicator = LinuxHostIndicator(appearance: appearance)
    shownIndicator = indicator
    indicator.onStop = {
        // Answers Stop the way the host does: by hiding at once.
        endRun("Stop pressed")
    }
    do {
        try indicator.show(deviceName: device)
    } catch {
        fail("the indicator could not be shown: \(error)")
    }
    let shape = IndicatorPillRenderer.layout(for: device)
    print("probe: indicator shown on \(display) for \(device)")
    print("probe: pill \(shape.logicalWidth)x\(shape.logicalHeight) points, Stop at \(shape.layout.stopRect)")
    mainLoop = g_main_loop_new(nil, 0)
    g_timeout_add_seconds(UInt32(seconds), { _ in
        endRun("time is up")
        return 0
    }, nil)
    for signalNumber in [SIGTERM, SIGINT] {
        g_unix_signal_add(signalNumber, { _ in
            endRun("signal received")
            return 0
        }, nil)
    }
    g_main_loop_run(mainLoop)
    print("probe: ended")
}

if let png {
    let bitmap = IndicatorPillRenderer.render(deviceName: device, appearance: appearance, scale: scale)
    guard IndicatorPillRenderer.writePNG(bitmap, to: png) else { fail("could not write \(png)") }
    print("probe: wrote \(bitmap.pixelWidth)x\(bitmap.pixelHeight) pixels to \(png)")
} else if show {
    let display = ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] ?? ""
    guard !display.isEmpty, display != "wayland-0" else {
        fail("refusing to run: WAYLAND_DISPLAY is '\(display)', which is not an explicitly chosen nested socket")
    }
    runShow(display: display)
} else {
    fail("give --png PATH or --show")
}
#else
print("probe: the indicator probe runs on Linux only")
#endif
