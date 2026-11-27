#if os(Linux)
import Foundation
import SensoriumLinuxHost
import SensoriumLinuxUpdate

/// The host window's update line: the macOS host's states and words, with
/// the Linux reason a host cannot update.
@MainActor
enum HostWindowUpdateLineTests {
    static let all: [(String, () async -> Void)] = [
        ("the update line says what the host's updater is doing in the macOS host's words", testTheUpdateLineUsesTheMacOSHostsWords),
        ("the window shows the update line and marks a failure", testTheWindowShowsTheUpdateLineAndMarksAFailure)
    ]

    static func testTheUpdateLineUsesTheMacOSHostsWords() async {
        let running = LinuxUpdateVersion("0.7.0")!
        let next = LinuxUpdateVersion("0.8.0")!
        func line(_ status: LinuxUpdateStatus, answered: Bool = false) -> HostWindowUpdateLine? {
            LinuxHostUpdateStatusLine.line(for: status, runningVersion: running, upToDateAnswered: answered)
        }
        expect(line(.current) == nil, "a host that has not heard back this launch claims nothing")
        expect(
            line(.current, answered: true) == HostWindowUpdateLine(text: "Sensorium Host 0.7.0 is up to date.", isFailure: false),
            "an answered check says the running version is up to date"
        )
        expect(line(.checking) == nil && line(.downloading(next)) == nil, "checking and downloading keep the line the window had")
        expect(
            line(.waiting(next)) == HostWindowUpdateLine(text: "Sensorium Host 0.8.0 will install when no machine is connected.", isFailure: false),
            "a staged update waits for the host to be idle, including while a session runs"
        )
        expect(line(.ready(next)) == line(.waiting(next)), "and reads the same however the engine names it")
        expect(
            line(.failed(reason: "the new version did not start in time"))
                == HostWindowUpdateLine(
                    text: "Sensorium Host could not update: the new version did not start in time. It keeps running 0.7.0.",
                    isFailure: true
                ),
            "a failure says why and that the running version stays"
        )
        expect(
            line(.notUpdatable) == HostWindowUpdateLine(
                text: "Sensorium Host cannot update itself because it cannot write to its own folder.", isFailure: false
            ),
            "a host that cannot write its own folder says so"
        )
    }

    static func testTheWindowShowsTheUpdateLineAndMarksAFailure() async {
        var state = HostWindowState(status: .waiting)
        expect(HostWindowPresentation(state, now: Date()).updateLine == nil, "with no line the window shows none")
        state.updateLine = HostWindowUpdateLine(text: "Sensorium Host 0.8.0 will install when no machine is connected.", isFailure: false)
        expect(HostWindowPresentation(state, now: Date()).updateLine == state.updateLine, "the window shows the updater's line")
        state.desktop = .unsupported
        expect(
            HostWindowPresentation(state, now: Date()).updateLine == state.updateLine,
            "and still does on a desktop that cannot offer the screen, which still updates"
        )
    }
}
#endif
