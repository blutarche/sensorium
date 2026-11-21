import Foundation
#if os(Linux)
import CGLib
import CGtk4
import SensoriumLinuxHost

/// Draws every state of the Linux host's windows into PNGs, from invented
/// sample data. Test scaffolding, not part of the product.
///
///     SensoriumHostWindowProbe render <output-dir>
///
/// writes `<state>-<light|dark>-<scale>x.png` for each state in both
/// appearances. The windows are real, so this needs a display: run it against
/// a nested, headless compositor or a Broadway socket, never the desktop
/// someone is using. It refuses to run without one named explicitly. The PNGs
/// are drawn at the scale that display's output has.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "render" else {
    fail("usage: SensoriumHostWindowProbe render <output-dir>")
}
let environment = ProcessInfo.processInfo.environment
let wayland = environment["WAYLAND_DISPLAY"] ?? ""
let usesBroadway = environment["GDK_BACKEND"] == "broadway" && !(environment["BROADWAY_DISPLAY"] ?? "").isEmpty
guard usesBroadway || (!wayland.isEmpty && (wayland as NSString).lastPathComponent != "wayland-0") else {
    fail("refusing to run: no explicitly chosen nested Wayland socket or Broadway display")
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
} catch {
    fail("could not create \(directory.path): \(error)")
}
guard gtk_init_check() != 0 else { fail("GTK could not open a display") }

// MARK: - Fixtures

let now = Date(timeIntervalSince1970: 1_700_000_000)

let machineSmall = HostWindowMachine(
    id: "a", name: "Studio Laptop", isArmed: true,
    sharedDisplaysLine: "May share Built-in Display.", keyFingerprintLine: "Key 5DB742A2"
)
let machineLong = HostWindowMachine(
    id: "b", name: "workstation-west-annex-render-node-07", isArmed: false,
    sharedDisplaysLine: "May share Built-in Display.", keyFingerprintLine: "Key 91C03E7B", asksFirst: true
)

struct Fixture {
    let name: String
    let state: HostWindowState
}

let fixtures: [Fixture] = [
    Fixture(name: "empty-list", state: HostWindowState(status: .waiting)),
    Fixture(name: "two-machines", state: HostWindowState(
        status: .waiting, machines: [machineSmall, machineLong],
        lastSessionLine: "Studio Laptop, Built-in Display, 14:05."
    )),
    Fixture(name: "pairing-code", state: HostWindowState(
        status: .waiting,
        pairing: .showing(code: "418297", expiresAt: now.addingTimeInterval(272), requestingDeviceName: nil)
    )),
    Fixture(name: "grant-needed", state: HostWindowState(
        status: .waiting, grant: .needed, machines: [machineSmall]
    )),
    Fixture(name: "live-session", state: HostWindowState(
        status: .sharing(deviceName: "Studio Laptop", displayName: "Built-in Display"),
        machines: [machineSmall, machineLong]
    )),
    Fixture(name: "unsupported-desktop", state: HostWindowState(desktop: .unsupported, status: .notHosting))
]

// MARK: - Rendering

func pump(milliseconds: Int) {
    let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
    let context = g_main_context_default()
    while Date() < deadline {
        while g_main_context_iteration(context, 0) != 0 {}
        usleep(5_000)
    }
}

func scaleLabel(_ scale: Double) -> String {
    scale == scale.rounded() ? String(Int(scale)) : String(scale)
}

@MainActor
func capture(_ toplevel: UnsafeMutableRawPointer, as name: String, appearance: IndicatorAppearance) -> Bool {
    // Time to map the window and lay it out before it is drawn.
    pump(milliseconds: 600)
    let path = directory.appendingPathComponent("\(name)-\(appearance.rawValue)-pending.png").path
    let scale = sensorium_window_content_write_png(toplevel, path)
    guard scale > 0 else {
        FileHandle.standardError.write(Data("probe: \(name) drew nothing\n".utf8))
        return false
    }
    let final = directory.appendingPathComponent("\(name)-\(appearance.rawValue)-\(scaleLabel(scale))x.png").path
    try? FileManager.default.removeItem(atPath: final)
    do {
        try FileManager.default.moveItem(atPath: path, toPath: final)
    } catch {
        FileHandle.standardError.write(Data("probe: could not name \(final): \(error)\n".utf8))
        return false
    }
    print("probe: wrote \(final)")
    return true
}

@MainActor
func renderEverything() -> Int32 {
    var failures: Int32 = 0
    for appearance in [IndicatorAppearance.light, .dark] {
        for fixture in fixtures {
            let window = HostMainWindow(state: fixture.state, appearance: appearance, now: { now })
            window.show()
            if !capture(window.toplevel, as: fixture.name, appearance: appearance) { failures += 1 }
            window.hide()
            pump(milliseconds: 100)
        }
        let prompt = AskFirstPromptWindow(
            content: AskFirstPromptContent(deviceName: "Studio Laptop", displayLabel: "Built-in Display"),
            appearance: appearance, now: { now }, onOutcome: { _ in }
        )
        prompt.show()
        if !capture(prompt.toplevel, as: "ask-first-prompt", appearance: appearance) { failures += 1 }
        prompt.dismiss()
        let rename = PairedMachineRenameWindow(
            currentName: machineLong.name, appearance: appearance, onRename: { _ in }
        )
        rename.show()
        if !capture(rename.toplevel, as: "rename-sheet", appearance: appearance) { failures += 1 }
        rename.dismiss()
        pump(milliseconds: 100)
    }
    return failures
}

exit(MainActor.assumeIsolated { renderEverything() })
#else
print("probe: the host window probe runs on Linux only")
#endif
