import Foundation
#if os(Linux)
import CGLib
import CGLibDispatchBridge
import SensoriumLinuxHost

/// The Linux host.
///
///     sensorium-host --serve [--allow-screen-sharing]
///
/// runs the host with no window, for tests: it listens on this machine's
/// tailnet address, prints each pairing code and every change of state, and
/// stops cleanly on SIGTERM or SIGINT. `--allow-screen-sharing` asks the
/// desktop for the screen-sharing grant with its dialog when no saved grant
/// could be restored. Without `--serve` it opens the host window.
///
/// A desktop that cannot show the live-session indicator is offered no host
/// screen, in this mode as in any other.
///
/// `--update-self-test` and `--replacing <pid> <ready file>` are the
/// updater's own, answered before anything else reads an argument.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sensorium-host: \(message)\n".utf8))
    exit(2)
}

// The self-test a staged update is run with: it reads this host's
// identities and paired machines without changing them, and needs no
// display.
let arguments: [String]
switch LinuxHostLaunchRoute.route(Array(CommandLine.arguments.dropFirst())) {
case .updateSelfTest:
    exit(LinuxHostUpdateSelfTest.run(
        dataFolder: RestoreTokenStore.defaultDataRoot(),
        versionLine: "Sensorium Host \(LinuxHostRelease.version)"
    ))
case let .host(hostArguments, _):
    arguments = hostArguments
}

let usage = "usage: sensorium-host [--background | --serve [--allow-screen-sharing]]"
if arguments == ["--help"] {
    print(usage)
    exit(0)
}
var serve = false
var allowScreenSharing = false
var background = false
for argument in arguments {
    switch argument {
    case "--serve": serve = true
    case "--allow-screen-sharing": allowScreenSharing = true
    case "--background": background = true
    default: fail("unknown option \(argument)\n\(usage)")
    }
}
guard !(serve && background), serve || !allowScreenSharing else { fail(usage) }

// Every @MainActor job runs on the thread inside g_main_loop_run, which is
// also where the indicator's Wayland connection is driven. The attachment only
// takes while the main actor has never suspended, so nothing above awaits.
guard sensorium_attach_dispatch_main_queue() != 0 else {
    fail("the main queue could not be attached to the GLib main loop")
}

if !serve {
    exit(LinuxHostApplication(arguments: arguments).run())
}

let dataFolder = RestoreTokenStore.defaultDataRoot()
let desktop: LinuxHostDesktop
do {
    desktop = try LinuxHostPlatform.desktop(dataFolder: dataFolder)
} catch {
    fail("no desktop session to host: \(error)")
}
let runtime = LinuxHostRuntime(dataFolder: dataFolder, platform: desktop.platform)
nonisolated(unsafe) let mainLoop = g_main_loop_new(nil, 0)
var isStopping = false

func describe(_ state: HostWindowState) -> String {
    var parts = ["status: \(state.status)", "grant: \(state.grant)", "machines: \(state.machines.count)"]
    if state.desktop == .unsupported {
        parts.append("no host screen: this desktop cannot show the live-session indicator")
    }
    return parts.joined(separator: ", ")
}

var lastLine = ""
var lastCode: String?
runtime.onStateChange = { state in
    let line = describe(state)
    if line != lastLine {
        lastLine = line
        print("sensorium-host: \(line)")
    }
    if case let .showing(code, _, requester) = state.pairing, code != lastCode {
        lastCode = code
        print("sensorium-host: pairing code \(code)" + (requester.map { " for \($0)" } ?? ""))
    } else if case .idle = state.pairing {
        lastCode = nil
    }
}

@MainActor
func stopAndQuit() {
    guard !isStopping else { return }
    isStopping = true
    print("sensorium-host: stopping")
    Task { @MainActor in
        await runtime.stop()
        desktop.screenSaver.stop()
        g_main_loop_quit(mainLoop)
    }
}

for signalNumber in [SIGTERM, SIGINT] {
    g_unix_signal_add(signalNumber, { _ in
        MainActor.assumeIsolated { stopAndQuit() }
        return 1
    }, nil)
}

Task { @MainActor in
    await runtime.start()
    guard !isStopping else { return }
    if allowScreenSharing, runtime.state.grant == .needed {
        runtime.allowScreenSharing()
    }
    runtime.showPairingCode()
    print("sensorium-host: \(describe(runtime.state))")
}

g_main_loop_run(mainLoop)
g_main_loop_unref(mainLoop)
print("sensorium-host: stopped")
#else
print("sensorium-host runs on Linux only")
#endif
