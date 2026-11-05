import Foundation
import SensoriumLinuxUpdate

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func installationForHandoff(_ directory: URL) -> LinuxUpdateInstallation {
    let installation = LinuxUpdateInstallation(dataRoot: directory.appendingPathComponent("sensorium", isDirectory: true))
    expect(installation.installability() == .updatable, "a fresh data root is updatable")
    placeVersion("0.5.0", in: installation)
    pointCurrent(at: "0.5.0", in: installation)
    return installation
}

/// `versions/<version>/Sensorium` as a shell script: `body` runs once the
/// script has checked it was started the way the old viewer starts a new
/// one, naming `oldProcess` and a ready file inside a handoff folder of
/// `installation`.
private func stagedScript(
    _ text: String,
    in installation: LinuxUpdateInstallation,
    oldProcess: pid_t,
    body: String,
    mode: mode_t = 0o755
) -> LinuxStagedUpdate {
    let folder = installation.versionDirectory(for: version(text))
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    chmod(folder.path, 0o700)
    let binary = folder.appendingPathComponent("Sensorium")
    let handoffPrefix = installation.dataRoot.path + "/.handoff-"
    writeFile(
        """
        #!/bin/sh
        [ "$#" -eq 3 ] && [ "$1" = --replacing ] && [ "$2" = "\(oldProcess)" ] || exit 9
        case "$3" in "\(handoffPrefix)"*/update-ready.json) ;; *) exit 8 ;; esac
        \(body)
        """,
        to: binary,
        mode: mode
    )
    return LinuxStagedUpdate(version: version(text), sha256: sampleDigest, executable: binary)
}

private func reportReady(version text: String, processIdentifier: String = "$$") -> String {
    "printf '{\"processIdentifier\":%s,\"version\":\"\(text)\"}' \(processIdentifier) > \"$3.partial\" && mv \"$3.partial\" \"$3\""
}

private func handoffFolders(in installation: LinuxUpdateInstallation) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: installation.dataRoot.path)) ?? []).filter { $0.hasPrefix(".handoff-") }
}

private func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

func testLaunchCommandRoutesTheSelfTestAndTheReplacingLaunch() {
    expect(LinuxUpdateLaunchCommand.parse(["--update-self-test"]) == .selfTest, "--update-self-test alone is the self-test")
    expect(
        LinuxUpdateLaunchCommand.parse(["--update-self-test", "enter"]) == .normal(["--update-self-test", "enter"]),
        "only the exact self-test form is the self-test"
    )
    let readyFile = "/home/someone/.local/share/sensorium/.handoff-1/update-ready.json"
    expect(
        LinuxUpdateLaunchCommand.parse(["--replacing", "4242", readyFile]) == .replacing(pid: 4242, readyFile: URL(fileURLWithPath: readyFile)),
        "--replacing <pid> <ready file> names the process it replaces and where to report"
    )
    for refused in [
        ["--replacing", "0", readyFile],
        ["--replacing", "-1", readyFile],
        ["--replacing", "x", readyFile],
        ["--replacing", "4242", "update-ready.json"],
        ["--replacing", "4242", "/update-ready.json"],
        ["--replacing", "4242", "/tmp/other.json"],
        ["--replacing", "4242", "/tmp/../tmp/update-ready.json"],
        ["--replacing", "4242", "/tmp//update-ready.json"],
        ["--replacing", "4242"],
        ["--replacing", "4242", readyFile, "enter"]
    ] {
        expect(LinuxUpdateLaunchCommand.parse(refused) == .normal(refused), "\(refused) is not a replacing launch")
    }
    expect(LinuxUpdateLaunchCommand.parse([]) == .normal([]), "no arguments is a plain launch")
    expect(
        LinuxUpdateLaunchCommand.replacingArguments(pid: 7, readyFile: URL(fileURLWithPath: readyFile)) == ["--replacing", "7", readyFile],
        "the replacing arguments read back as they parse"
    )
}

func testReadyReportIsWrittenOnlyIntoAnOwnerOnlyFolder() {
    let directory = makeTemporaryDirectory("ready")
    defer { removeTemporaryDirectory(directory) }
    let installation = installationForHandoff(directory)

    let folder = try! LinuxUpdateHandoff.makeFolder(in: installation)
    expect(folder.deletingLastPathComponent().standardizedFileURL == installation.dataRoot.standardizedFileURL, "the handoff folder is in the data root")
    expect(folder.lastPathComponent.hasPrefix(".handoff-"), "and is named as a handoff folder")
    expect(posixMode(of: folder) == 0o700, "and is owner-only")
    let readyFile = folder.appendingPathComponent(LinuxUpdateHandoff.readyFileName)
    expect(LinuxUpdateHandoff.readReport(at: readyFile) == nil, "there is no report until one is written")

    do {
        try LinuxUpdateHandoff.reportReady(version: version("0.6.0"), to: readyFile, processIdentifier: 31)
    } catch {
        expect(false, "a report is written into the owner-only folder, got \(error)")
    }
    expect(
        LinuxUpdateHandoff.readReport(at: readyFile) == LinuxUpdateReadyReport(processIdentifier: 31, version: version("0.6.0")),
        "the report names the process and its version"
    )
    expect(posixMode(of: readyFile) == 0o600, "and is owner-only")

    let missing = directory.appendingPathComponent("missing", isDirectory: true).appendingPathComponent(LinuxUpdateHandoff.readyFileName)
    expect((try? LinuxUpdateHandoff.reportReady(version: version("0.6.0"), to: missing)) == nil, "no folder is made for a report")
    expect(fileType(of: missing.deletingLastPathComponent()) == nil, "and the missing folder stays missing")

    let open = directory.appendingPathComponent("open", isDirectory: true)
    try! FileManager.default.createDirectory(at: open, withIntermediateDirectories: false)
    chmod(open.path, 0o755)
    let openFile = open.appendingPathComponent(LinuxUpdateHandoff.readyFileName)
    expect((try? LinuxUpdateHandoff.reportReady(version: version("0.6.0"), to: openFile)) == nil, "a folder others may read is refused")
    expect(fileType(of: openFile) == nil, "and nothing is written there")

    let link = directory.appendingPathComponent("link", isDirectory: true)
    expect(symlink(folder.path, link.path) == 0, "a test can link to the handoff folder")
    expect(
        (try? LinuxUpdateHandoff.reportReady(version: version("0.6.0"), to: link.appendingPathComponent(LinuxUpdateHandoff.readyFileName))) == nil,
        "a folder reached through a symbolic link is refused"
    )

    writeFile("{ not json", to: readyFile, mode: 0o600)
    expect(LinuxUpdateHandoff.readReport(at: readyFile) == nil, "an unreadable report reads as none")
}

/// Restart Now's whole sequence against a script standing in for the new
/// viewer: switch, start with `--replacing`, wait for the ready file, and on
/// anything but the expected report, switch back and stop the new process.
func testRestartHandsOverOnlyToANewVersionThatReportsReady() async {
    let directory = makeTemporaryDirectory("restart")
    defer { removeTemporaryDirectory(directory) }
    let installation = installationForHandoff(directory)
    let me = getpid()
    let restart = LinuxUpdateRestart(installation: installation, readyTimeout: 1.5, quitGrace: 0.5)

    expect(LinuxUpdateRestart.readyTimeout == 60, "the old viewer waits 60 seconds for the ready file")
    expect(LinuxUpdateRestart.quitGrace == 10, "and gives a refused new viewer 10 seconds to quit")

    let good = stagedScript("0.6.0", in: installation, oldProcess: me, body: reportReady(version: "0.6.0"))
    let tookOver = await restart.run(good, processIdentifier: me)
    expect(tookOver == .tookOver, "a new version that reports ready with its own process and version takes over, got \(tookOver)")
    expect(installation.currentVersion() == version("0.6.0"), "current names the new version")
    expect(installation.pendingSwitch()?.version == version("0.6.0"), "and the switch waits on the new version's own confirmation")
    expect(handoffFolders(in: installation).isEmpty, "the handoff folder is removed")

    // The new version never confirmed, so its next launch would roll back;
    // put the layout back the way a confirmed 0.5.0 would leave it.
    _ = installation.rollBack(installation.pendingSwitch()!)

    // Removing the marker is what a confirmation does. The old viewer's
    // wait still runs out, and the switch it made is still undone.
    let confirmsWithoutReporting = stagedScript(
        "0.6.0", in: installation, oldProcess: me,
        body: "rm -f \"\(installation.pendingMarker.path)\"\nexec sleep 30"
    )
    let unreported = await restart.run(confirmsWithoutReporting, processIdentifier: me)
    expect(unreported == .failed(.readyLate), "a new version that confirms but never reports is late, got \(unreported)")
    expect(installation.currentVersion() == version("0.5.0"), "and current goes back although the marker was already gone")
    expect(installation.pendingSwitch() == nil, "and no switch is pending")

    let silent = stagedScript("0.6.0", in: installation, oldProcess: me, body: "echo $$ > \"\(directory.path)/silent.pid\"\nexec sleep 30")
    let started = Date()
    let late = await restart.run(silent, processIdentifier: me)
    expect(late == .failed(.readyLate), "a new version that never reports is late, got \(late)")
    expect(Date().timeIntervalSince(started) < 10, "and is given up on at the timeout")
    expect(installation.currentVersion() == version("0.5.0"), "current is switched back")
    expect(installation.pendingSwitch() == nil, "and no switch is pending")
    expect(handoffFolders(in: installation).isEmpty, "the handoff folder is removed")
    if let text = try? String(contentsOfFile: directory.appendingPathComponent("silent.pid").path, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        expect(!isAlive(pid), "the late new version is asked to quit")
    } else {
        expect(false, "the late script recorded its process")
    }

    let stubborn = stagedScript(
        "0.6.0", in: installation, oldProcess: me,
        body: "echo $$ > \"\(directory.path)/stubborn.pid\"\ntrap '' TERM\nwhile :; do sleep 0.1; done"
    )
    let refused = await restart.run(stubborn, processIdentifier: me)
    expect(refused == .failed(.readyLate), "a new version that ignores the request to quit is still late, got \(refused)")
    if let text = try? String(contentsOfFile: directory.appendingPathComponent("stubborn.pid").path, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        expect(!isAlive(pid), "and is forced to quit after the grace period")
    } else {
        expect(false, "the stubborn script recorded its process")
    }

    let otherProcess = stagedScript("0.6.0", in: installation, oldProcess: me, body: reportReady(version: "0.6.0", processIdentifier: "1"))
    let impostor = await restart.run(otherProcess, processIdentifier: me)
    expect(impostor == .failed(.readyLate), "a report naming another process is refused, got \(impostor)")
    expect(installation.currentVersion() == version("0.5.0"), "and current is switched back")

    let otherVersion = stagedScript("0.6.0", in: installation, oldProcess: me, body: reportReady(version: "0.5.0"))
    let wrong = await restart.run(otherVersion, processIdentifier: me)
    expect(wrong == .failed(.readyLate), "a report naming another version is refused, got \(wrong)")

    let crashing = stagedScript("0.6.0", in: installation, oldProcess: me, body: "exit 3")
    let crashStarted = Date()
    let crashed = await restart.run(crashing, processIdentifier: me)
    expect(crashed == .failed(.readyLate), "a new version that exits without reporting fails, got \(crashed)")
    expect(Date().timeIntervalSince(crashStarted) < 1.4, "as soon as it has exited, not at the timeout")
    expect(installation.currentVersion() == version("0.5.0"), "and current is switched back")

    let unrunnable = stagedScript("0.6.0", in: installation, oldProcess: me, body: "exit 0", mode: 0o644)
    let notLaunched = await restart.run(unrunnable, processIdentifier: me)
    expect(notLaunched == .failed(.launchFailed), "a binary that cannot be started fails to launch, got \(notLaunched)")
    expect(installation.currentVersion() == version("0.5.0") && installation.pendingSwitch() == nil, "and current is switched back")

    let absent = LinuxStagedUpdate(
        version: version("0.7.0"), sha256: sampleDigest,
        executable: installation.versionDirectory(for: version("0.7.0")).appendingPathComponent("Sensorium")
    )
    let notSwitched = await restart.run(absent, processIdentifier: me)
    expect(notSwitched == .failed(.switchFailed), "a version that is not in place is never switched to, got \(notSwitched)")
    expect(installation.currentVersion() == version("0.5.0"), "and current stays")
    expect(handoffFolders(in: installation).isEmpty, "no handoff folder is left behind by any failure")
}
