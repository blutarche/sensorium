#if os(macOS)
import Foundation
import SensoriumUpdate

func testCommandLineParsesTheTwoUpdateModesBeforeAnythingElse() {
    expect(UpdateLaunchCommand.parse(["--update-self-test"]) == .selfTest, "--update-self-test alone is the self-test")
    let ready = "/private/var/folders/xy/T/TemporaryItems/stage/update-ready.json"
    expect(
        UpdateLaunchCommand.parse(["--replacing", "4242", ready]) == .replacing(pid: 4242, readyFile: URL(fileURLWithPath: ready)),
        "--replacing names the old process and the ready file"
    )
    expect(UpdateLaunchCommand.parse([]) == .normal([]), "no arguments is a normal launch")
    expect(UpdateLaunchCommand.parse(["serve", "7300"]) == .normal(["serve", "7300"]), "other arguments pass through untouched")

    for malformed in [
        ["--update-self-test", "extra"],
        ["--replacing"],
        ["--replacing", "4242"],
        ["--replacing", "0", ready],
        ["--replacing", "-5", ready],
        ["--replacing", "abc", ready],
        ["--replacing", "4242", "relative/update-ready.json"],
        ["--replacing", "4242", "/private/var/folders/xy/T/other.json"],
        ["--replacing", "4242", "/update-ready.json"],
        ["--replacing", "4242", "/private/var/folders/xy/T/../update-ready.json"],
        ["--replacing", "4242", "/private/var/folders/xy/./T/update-ready.json"],
        ["--replacing", "4242", "/private/var//folders/xy/T/update-ready.json"],
        ["--replacing", "4242", "/private/var/folders/xy/T/update-ready.json/"],
        ["--replacing", "4242", ready, "extra"],
        ["serve", "--update-self-test"]
    ] {
        expect(UpdateLaunchCommand.parse(malformed) == .normal(malformed), "\(malformed) is left for the app's own usage message")
    }
    let pair = UpdateLaunchCommand.replacingArguments(pid: 77, readyFile: URL(fileURLWithPath: ready))
    expect(UpdateLaunchCommand.parse(pair) == .replacing(pid: 77, readyFile: URL(fileURLWithPath: ready)), "the arguments the installer passes parse back")
}

func testWaitingForTheOldProcessReturnsOnceItExits() async {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["0.3"]
    try! child.run()
    let start = Date()
    await UpdateHandoff.waitForExit(of: child.processIdentifier, pollInterval: .seconds(60))
    let waited = Date().timeIntervalSince(start)
    expect(waited >= 0.2, "the wait lasts until the process exits")
    expect(waited < 5, "the exit event ends the wait without waiting for the next poll")

    let gone = Process()
    gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! gone.run()
    endProcess(gone, terminating: false)
    let goneStart = Date()
    await UpdateHandoff.waitForExit(of: gone.processIdentifier)
    expect(Date().timeIntervalSince(goneStart) < 2, "a process that already exited is not waited for")
}

/// A folder made owner-only, as a staging folder is.
func makeOwnerOnlyFolder(_ url: URL) -> URL {
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    chmod(url.path, 0o700)
    return url
}

func testFinishingTheHandoffRemovesOnlyAStagingFolder() async {
    let directory = makeTemporaryDirectory("finish")
    defer { removeTemporaryDirectory(directory) }
    let running = makeAppBundle(in: makeOwnerOnlyFolder(directory.appendingPathComponent("Applications", isDirectory: true)), signingIdentifier: nil, marker: "new")
    let staging = makeOwnerOnlyFolder(directory.appendingPathComponent("stage", isDirectory: true))
    makeAppBundle(in: staging, signingIdentifier: nil, marker: "old")
    let ready = staging.appendingPathComponent(UpdateHandoff.readyFileName)
    try! UpdateHandoff.reportReady(sampleReport(version: "0.5.0"), to: ready)

    let gone = Process()
    gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! gone.run()
    endProcess(gone, terminating: false)
    let finished = await UpdateHandoff.finishReplacing(
        oldProcess: gone.processIdentifier,
        readyFile: ready,
        appName: fixtureAppName,
        bundleIdentifier: fixtureIdentifier,
        runningAppURL: running
    )
    expect(finished, "the new instance removes the staging folder once the old process has exited")
    expect(!FileManager.default.fileExists(atPath: staging.path), "the staging folder holding the old app is gone")
    expect(marker(of: running) == "new", "the running app is untouched")
}

/// What a fake sleeper was asked to wait for, from whichever task asked.
private final class RequestedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var all: [Duration] {
        lock.withLock { durations }
    }

    func record(_ duration: Duration) {
        lock.withLock { durations.append(duration) }
    }
}

/// A running app in its own folder, and a staging folder holding the ready
/// file and the old app, as an install leaves them.
private func makeHandoffFolders(_ label: String) -> (directory: URL, running: URL, staging: URL, ready: URL) {
    let directory = makeTemporaryDirectory(label)
    let running = makeAppBundle(in: makeOwnerOnlyFolder(directory.appendingPathComponent("Applications", isDirectory: true)), signingIdentifier: nil, marker: "new")
    let staging = makeOwnerOnlyFolder(directory.appendingPathComponent("stage", isDirectory: true))
    makeAppBundle(in: staging, signingIdentifier: nil, marker: "old")
    let ready = staging.appendingPathComponent(UpdateHandoff.readyFileName)
    try! UpdateHandoff.reportReady(sampleReport(version: "0.5.0"), to: ready)
    return (directory, running, staging, ready)
}

private func startSleeping(seconds: String) -> Process {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = [seconds]
    try! child.run()
    return child
}

func testAReplacedProcessThatQuitsInTimeIsNotEnded() async {
    let folders = makeHandoffFolders("quits-in-time")
    defer { removeTemporaryDirectory(folders.directory) }
    let child = startSleeping(seconds: "0.3")
    var lookedUp: [pid_t] = []
    var ended: [pid_t] = []
    var lines: [String] = []

    let finished = await UpdateHandoff.finishReplacing(
        oldProcess: child.processIdentifier,
        readyFile: folders.ready,
        appName: fixtureAppName,
        bundleIdentifier: fixtureIdentifier,
        runningAppURL: folders.running,
        log: { lines.append($0) },
        sleep: { try? await Task.sleep(for: $0) },
        runningBundleIdentifier: { pid in
            lookedUp.append(pid)
            return fixtureIdentifier
        },
        forceQuit: { ended.append($0) }
    )
    expect(lookedUp.isEmpty && ended.isEmpty, "a process that quits within the limit is neither looked up nor ended")
    expect(lines.isEmpty, "nothing is logged, got \(lines)")
    expect(finished && !FileManager.default.fileExists(atPath: folders.staging.path), "the staging folder is removed")
}

func testAReplacedProcessStillRunningAfterThirtySecondsIsEndedOnlyIfItIsThisApp() async {
    func finish(runningBundleIdentifier: String?) async -> (finished: Bool, child: pid_t, ended: [pid_t], stagingAtEnd: [Bool], lines: [String], sleeps: [Duration], stagingRemains: Bool) {
        let folders = makeHandoffFolders("still-running")
        defer { removeTemporaryDirectory(folders.directory) }
        let child = startSleeping(seconds: "60")
        defer { endProcess(child) }
        let sleeps = RequestedSleeps()
        var ended: [pid_t] = []
        var stagingAtEnd: [Bool] = []
        var lines: [String] = []
        let finished = await UpdateHandoff.finishReplacing(
            oldProcess: child.processIdentifier,
            readyFile: folders.ready,
            appName: fixtureAppName,
            bundleIdentifier: fixtureIdentifier,
            runningAppURL: folders.running,
            log: { lines.append($0) },
            sleep: { sleeps.record($0) },
            runningBundleIdentifier: { pid in
                expect(pid == child.processIdentifier, "the replaced process is the one looked up")
                return runningBundleIdentifier
            },
            forceQuit: { pid in
                ended.append(pid)
                stagingAtEnd.append(FileManager.default.fileExists(atPath: folders.staging.path))
            }
        )
        expect(child.isRunning, "the replaced process was still running when the limit passed")
        return (finished, child.processIdentifier, ended, stagingAtEnd, lines, sleeps.all, FileManager.default.fileExists(atPath: folders.staging.path))
    }

    let same = await finish(runningBundleIdentifier: fixtureIdentifier)
    expect(same.sleeps == [.seconds(30)], "the replaced process is given 30 seconds, got \(same.sleeps)")
    expect(same.ended == [same.child], "a replaced process still running this app after 30 seconds is ended once")
    expect(same.stagingAtEnd == [true], "it is ended before the staging folder is removed")
    expect(same.lines.count == 1 && same.lines[0].contains("30 seconds"), "ending it is logged in one line, got \(same.lines)")
    expect(same.finished && !same.stagingRemains, "then the staging folder is removed")

    let reused = await finish(runningBundleIdentifier: "com.example.other")
    expect(reused.ended.isEmpty, "a process identifier now used by another app is not ended")
    expect(reused.finished && !reused.stagingRemains, "the replaced process is gone, so the staging folder is removed")

    let gone = await finish(runningBundleIdentifier: nil)
    expect(gone.ended.isEmpty, "a process identifier with no running app behind it is not ended")
    expect(gone.finished && !gone.stagingRemains, "the replaced process is gone, so the staging folder is removed")
}

func testTheReadyFileIsWrittenOnlyIntoAnOwnerOnlyFolder() {
    let directory = makeTemporaryDirectory("ready-folder")
    defer { removeTemporaryDirectory(directory) }
    let report = sampleReport(version: "0.5.0")
    func refusal(_ readyFile: URL) -> UpdateReadyFileError? {
        do {
            try UpdateHandoff.reportReady(report, to: readyFile)
            return nil
        } catch let error as UpdateReadyFileError {
            return error
        } catch {
            return .couldNotWrite(errno: -1)
        }
    }

    let stage = makeOwnerOnlyFolder(directory.appendingPathComponent("stage", isDirectory: true))
    expect(refusal(stage.appendingPathComponent(UpdateHandoff.readyFileName)) == nil, "an owner-only folder of this user's takes the ready file")
    expect(posixMode(of: stage) == 0o700, "the folder keeps its mode")

    let missing = directory.appendingPathComponent("missing", isDirectory: true)
    expect(refusal(missing.appendingPathComponent(UpdateHandoff.readyFileName)) == .folderMissing, "a missing folder is refused")
    expect(!FileManager.default.fileExists(atPath: missing.path), "a missing folder is not created")

    for mode: mode_t in [0o755, 0o770, 0o711, 0o1700] {
        let loose = directory.appendingPathComponent("mode-\(String(mode, radix: 8))", isDirectory: true)
        try! FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        chmod(loose.path, mode)
        expect(refusal(loose.appendingPathComponent(UpdateHandoff.readyFileName)) == .notOwnerOnly, "a folder with mode \(String(mode, radix: 8)) is refused")
        expect(posixMode(of: loose) == Int(mode), "a refused folder keeps its mode \(String(mode, radix: 8))")
        expect(try! FileManager.default.contentsOfDirectory(atPath: loose.path).isEmpty, "nothing is written into a folder with mode \(String(mode, radix: 8))")
    }

    let target = makeOwnerOnlyFolder(directory.appendingPathComponent("target", isDirectory: true))
    let link = directory.appendingPathComponent("link", isDirectory: true)
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    expect(refusal(link.appendingPathComponent(UpdateHandoff.readyFileName)) == .notAFolder, "a symbolic link to an owner-only folder is refused")
    expect(try! FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty, "nothing is written through the link")

    let file = directory.appendingPathComponent("file")
    try! Data("x".utf8).write(to: file)
    expect(refusal(file.appendingPathComponent(UpdateHandoff.readyFileName)) == .notAFolder, "a file in place of the folder is refused")

    if getuid() != 0 {
        // A system folder: opened to read its owner and mode, never written.
        expect(refusal(URL(fileURLWithPath: "/usr/\(UpdateHandoff.readyFileName)")) == .notOwnedByThisUser, "a folder another user owns is refused")
    } else {
        print("SKIP: running as root, which owns the system folders")
    }
}

func testTheStagingFolderIsRemovedOnlyWhenItIsOne() {
    let directory = makeTemporaryDirectory("remove-staging")
    defer { removeTemporaryDirectory(directory) }
    let runningFolder = makeOwnerOnlyFolder(directory.appendingPathComponent("Running", isDirectory: true))
    let running = makeAppBundle(in: runningFolder, signingIdentifier: nil, marker: "new")

    /// A staging folder as the installer leaves it, changed by `change`.
    func staging(_ label: String, _ change: (URL) -> Void = { _ in }) -> URL {
        let folder = makeOwnerOnlyFolder(directory.appendingPathComponent(label, isDirectory: true))
        makeAppBundle(in: folder, signingIdentifier: nil, marker: "old")
        try! UpdateHandoff.reportReady(sampleReport(version: "0.5.0"), to: folder.appendingPathComponent(UpdateHandoff.readyFileName))
        change(folder)
        return folder
    }
    func expectKept(
        _ folder: URL,
        readyFile: URL? = nil,
        bundleIdentifier: String? = fixtureIdentifier,
        runningAppURL: URL? = nil,
        because reason: String,
        _ what: String
    ) {
        let before = try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        var lines: [String] = []
        let removed = UpdateHandoff.removeStagingFolder(
            holding: readyFile ?? folder.appendingPathComponent(UpdateHandoff.readyFileName),
            appName: fixtureAppName,
            bundleIdentifier: bundleIdentifier,
            runningAppURL: runningAppURL ?? running,
            log: { lines.append($0) }
        )
        expect(!removed, "\(what) is not removed")
        expect(FileManager.default.fileExists(atPath: folder.path), "\(what) is still there")
        expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) == before, "nothing in \(what) is touched")
        expect(lines.count == 1 && lines[0].contains(reason), "the refusal of \(what) is logged as '\(reason)', got \(lines)")
    }

    let good = staging("good")
    var lines: [String] = []
    expect(
        UpdateHandoff.removeStagingFolder(holding: good.appendingPathComponent(UpdateHandoff.readyFileName), appName: fixtureAppName, bundleIdentifier: fixtureIdentifier, runningAppURL: running, log: { lines.append($0) }),
        "a staging folder holding the ready file and the old app is removed"
    )
    expect(!FileManager.default.fileExists(atPath: good.path) && lines.isEmpty, "it is gone, and nothing is logged")

    let named = staging("named")
    expectKept(named, readyFile: named.appendingPathComponent("other.json"), because: UpdateHandoff.readyFileName, "a folder named by a file that is not the ready file")
    expectKept(staging("loose") { chmod($0.path, 0o755) }, because: "not owner-only", "a folder that is not owner-only")
    expectKept(staging("extra") { try! Data("keep".utf8).write(to: $0.appendingPathComponent("document.txt")) }, because: "holds", "a folder holding anything else")
    expectKept(staging("app-only") { try! FileManager.default.removeItem(at: $0.appendingPathComponent(UpdateHandoff.readyFileName)) }, because: "holds", "a folder holding the app without the ready file")
    expectKept(staging("ready-only") { try! FileManager.default.removeItem(at: $0.appendingPathComponent(fixtureAppName)) }, because: "holds", "a folder holding the ready file alone")
    expectKept(staging("other-name") { folder in
        try! FileManager.default.moveItem(at: folder.appendingPathComponent(fixtureAppName), to: folder.appendingPathComponent("Other.app"))
    }, because: "holds", "a folder holding an app of another name")
    let elsewhere = makeOwnerOnlyFolder(directory.appendingPathComponent("elsewhere", isDirectory: true))
    makeAppBundle(in: elsewhere, signingIdentifier: nil)
    expectKept(staging("linked-app") { folder in
        try! FileManager.default.removeItem(at: folder.appendingPathComponent(fixtureAppName))
        try! FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(fixtureAppName), withDestinationURL: elsewhere.appendingPathComponent(fixtureAppName))
    }, because: "not a folder", "a folder whose app is a symbolic link")
    expectKept(staging("other-identifier") { folder in
        try! FileManager.default.removeItem(at: folder.appendingPathComponent(fixtureAppName))
        makeAppBundle(in: folder, identifier: "com.example.other", signingIdentifier: nil)
    }, because: "identifier", "a folder holding another app under the same name")
    expectKept(staging("unknown-identifier"), bundleIdentifier: nil, because: "identifier", "a folder checked by an app that does not know its own identifier")

    let linkedFolder = directory.appendingPathComponent("linked-folder", isDirectory: true)
    let linkTarget = staging("link-target")
    try! FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: linkTarget)
    expectKept(linkTarget, readyFile: linkedFolder.appendingPathComponent(UpdateHandoff.readyFileName), because: "not a folder", "a folder reached through a symbolic link")

    // The folder a running app sits in, as Applications holds one app.
    let applications = makeOwnerOnlyFolder(directory.appendingPathComponent("Applications", isDirectory: true))
    let installed = makeAppBundle(in: applications, signingIdentifier: nil, marker: "new")
    let applicationsReady = applications.appendingPathComponent(UpdateHandoff.readyFileName)
    chmod(applications.path, 0o755)
    expect((try? UpdateHandoff.reportReady(sampleReport(version: "0.5.0"), to: applicationsReady)) == nil, "no ready file is written into an Applications folder")
    expectKept(applications, runningAppURL: installed, because: "not owner-only", "an Applications folder holding only the app")
    chmod(applications.path, 0o700)
    try! UpdateHandoff.reportReady(sampleReport(version: "0.5.0"), to: applicationsReady)
    expectKept(applications, runningAppURL: installed, because: "running app", "the folder holding the running app, even one owner-only that holds the ready file and the app alone")

    if getuid() != 0 {
        // A system folder: only its owner is read, before anything is listed.
        expectKept(URL(fileURLWithPath: "/usr"), because: "owned", "a folder another user owns")
    } else {
        print("SKIP: running as root, which owns the system folders")
    }
}
#endif
