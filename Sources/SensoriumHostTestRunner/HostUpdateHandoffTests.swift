import Foundation
import SensoriumHost
import SensoriumUpdate

private func ownerOnlyFolder(_ label: String) -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
}

private func sampleReport(port: UInt16) -> UpdateReadyReport {
    HostUpdateReadyReport.make(
        version: UpdateVersion("0.5.0")!,
        permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted),
        loginItemStatus: UpdateReadyReport.LoginItemStatus.enabled,
        certificateHash: Data(repeating: 0x11, count: 32),
        approvedDeviceKeys: [Data(repeating: 0x22, count: 32)],
        listening: HostListeningValues(tailnetAddress: "100.64.1.2", port: port, interfaceName: "utun4", allowsLocalNetwork: false)
    )
}

/// The new instance reports ready once, from its first listener ready, and
/// keeps serving whatever happens to the report.
@MainActor
func runHostUpdateRelaunchReporterTests() {
    let ready = HostListenerReady(address: "100.64.1.2", port: 7777, certificateHash: Data(repeating: 0x11, count: 32))

    do {
        let folder = ownerOnlyFolder("host-update-ready")
        let readyFile = folder.appendingPathComponent(UpdateHandoff.readyFileName)
        var built: [HostListenerReady] = []
        var logged: [String] = []
        let reporter = HostUpdateRelaunchReporter(
            relaunch: HostUpdateRelaunch(replacedProcess: 4242, readyFile: readyFile),
            makeReport: { values in
                built.append(values)
                return sampleReport(port: values.port)
            },
            log: { logged.append($0) }
        )
        expect(reporter.listenerReady(ready), "the first listener ready is the one that reports")
        let written = UpdateReadyReport.read(from: readyFile)
        expect(written != nil, "the ready file is written")
        expect(written?.processIdentifier == getpid(), "the report names this process, the one the old instance launched")
        expect(written?.host?.port == 7777, "the report carries this instance's own running values")
        var rebuilt = ready
        rebuilt.port = 7778
        expect(!reporter.listenerReady(rebuilt), "a listener rebuilt later reports nothing more")
        expect(UpdateReadyReport.read(from: readyFile)?.host?.port == 7777, "the report written first stands")
        expect(built.count == 1, "the report is built once")
        expect(logged.contains("reported ready as the replacement for an earlier host"), "the report is logged, got \(logged)")
        print("PASS: the replacing host reports ready once, from its first listener ready")
    }

    do {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-update-missing-\(UUID().uuidString)", isDirectory: true)
        var logged: [String] = []
        let reporter = HostUpdateRelaunchReporter(
            relaunch: HostUpdateRelaunch(replacedProcess: 4242, readyFile: folder.appendingPathComponent(UpdateHandoff.readyFileName)),
            makeReport: { sampleReport(port: $0.port) },
            log: { logged.append($0) }
        )
        expect(reporter.listenerReady(ready), "a report that cannot be written still counts as the first ready")
        expect(!FileManager.default.fileExists(atPath: folder.path), "no folder is made for a ready file")
        expect(
            logged.contains { $0.hasPrefix("could not report ready") },
            "a report that could not be written is logged, got \(logged)"
        )
        print("PASS: a ready file that cannot be written is logged and the host keeps running")
    }
}

@MainActor
private final class FakeLaunchedApp: UpdateLaunchedApp {
    let processIdentifier: pid_t
    var hasExited = false
    var quitRequests = 0

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    func requestQuit() { quitRequests += 1 }
    func forceQuit() { hasExited = true }
}

@MainActor
private final class FakeLauncher: UpdateAppLaunching {
    var launches: [(URL, [String])] = []
    var fails = false
    var reportFrom: pid_t?
    let app = FakeLaunchedApp(processIdentifier: 5151)

    func launch(appAt url: URL, arguments: [String]) async throws -> any UpdateLaunchedApp {
        launches.append((url, arguments))
        if fails {
            throw CocoaError(.fileNoSuchFile)
        }
        if let reportFrom, case let .replacing(_, readyFile) = UpdateLaunchCommand.parse(arguments) {
            try UpdateHandoff.reportReady(sampleReport(port: 7777), to: readyFile, processIdentifier: reportFrom)
        }
        return app
    }
}

private struct FixedRequirement: UpdateRequirementChecking {
    let satisfied: Bool
    func isSatisfied(byBundleAt url: URL) -> Bool { satisfied }
}

/// After a swap back failed, the installed app is the refused new version.
/// The host launches it anyway through the same handoff, so the Mac still
/// gets a serving host, and quits only once it reports ready.
@MainActor
func runHostUpdateSwapBackRecoveryTests() async {
    let installed = URL(fileURLWithPath: "/Applications/Sensorium Host.app", isDirectory: true)

    do {
        let folder = ownerOnlyFolder("host-update-recovery")
        let readyFile = folder.appendingPathComponent(UpdateHandoff.readyFileName)
        let launcher = FakeLauncher()
        launcher.reportFrom = 5151
        let outcome = await HostUpdateSwapBackRecovery.relaunchInstalled(
            installedAppURL: installed,
            readyFile: readyFile,
            requirement: FixedRequirement(satisfied: true),
            launcher: launcher,
            processIdentifier: 777,
            readyTimeout: .seconds(5)
        )
        expect(outcome == .ready, "the installed app reported ready, got \(outcome)")
        expect(launcher.launches.count == 1, "it is launched once")
        expect(launcher.launches.first?.0 == installed, "the app at the install path is the one launched")
        expect(
            launcher.launches.first?.1 == UpdateLaunchCommand.replacingArguments(pid: 777, readyFile: readyFile),
            "it is launched through the ordinary --replacing handoff"
        )
        print("PASS: after a failed swap back the installed app is launched through the handoff and its ready report accepted")
    }

    do {
        let folder = ownerOnlyFolder("host-update-recovery")
        let launcher = FakeLauncher()
        launcher.reportFrom = 5151
        let outcome = await HostUpdateSwapBackRecovery.relaunchInstalled(
            installedAppURL: installed,
            readyFile: folder.appendingPathComponent(UpdateHandoff.readyFileName),
            requirement: FixedRequirement(satisfied: false),
            launcher: launcher,
            processIdentifier: 777,
            readyTimeout: .seconds(5)
        )
        expect(outcome == .requirementFailed, "an installed app not signed like this one is not launched, got \(outcome)")
        expect(launcher.launches.isEmpty, "nothing is launched")
        print("PASS: an installed app that fails the signing requirement is never launched")
    }

    do {
        let folder = ownerOnlyFolder("host-update-recovery")
        let launcher = FakeLauncher()
        launcher.reportFrom = 9999
        let outcome = await HostUpdateSwapBackRecovery.relaunchInstalled(
            installedAppURL: installed,
            readyFile: folder.appendingPathComponent(UpdateHandoff.readyFileName),
            requirement: FixedRequirement(satisfied: true),
            launcher: launcher,
            processIdentifier: 777,
            readyTimeout: .milliseconds(300),
            pollInterval: .milliseconds(20)
        )
        expect(outcome == .readyLate, "a report from another process is no report, got \(outcome)")
        expect(launcher.app.quitRequests == 0, "an instance that did not report is left running, as it may yet serve")
        print("PASS: only the launched process's own report counts")
    }

    do {
        let folder = ownerOnlyFolder("host-update-recovery")
        let launcher = FakeLauncher()
        launcher.fails = true
        let outcome = await HostUpdateSwapBackRecovery.relaunchInstalled(
            installedAppURL: installed,
            readyFile: folder.appendingPathComponent(UpdateHandoff.readyFileName),
            requirement: FixedRequirement(satisfied: true),
            launcher: launcher,
            processIdentifier: 777,
            readyTimeout: .seconds(5)
        )
        expect(outcome == .launchFailed, "a launch that throws is reported, got \(outcome)")
        print("PASS: a launch that fails is reported")
    }
}

/// The built `sensoriumd` reads the update arguments before its own: an
/// unknown argument still ends it with the usage message, and the self-test
/// never reaches the `pair`/`serve` parsing.
func runHostUpdateArgumentOrderTests() {
    guard let runner = Bundle.main.executableURL else {
        expect(false, "the runner's own path is unknown")
        return
    }
    let host = runner.deletingLastPathComponent().appendingPathComponent("sensoriumd")
    expect(
        FileManager.default.isExecutableFile(atPath: host.path),
        "sensoriumd is built beside this runner at \(host.lastPathComponent); build the whole package first"
    )

    func run(_ arguments: [String], home: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = host
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try! process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    let home = ownerOnlyFolder("host-update-home")
    let bogus = run(["--bogus"], home: home)
    expect(bogus.status == 2, "an argument the host does not know still ends it with status 2, got \(bogus.status)")
    expect(bogus.output.contains("usage:"), "and with the usage message, got \(bogus.output)")

    let selfTest = run(["--update-self-test"], home: home)
    expect(selfTest.status == 0, "the self-test passes on a home with nothing in it, got \(selfTest.status): \(selfTest.output)")
    expect(!selfTest.output.contains("usage:"), "the self-test never reaches the usage message")
    let leftBehind = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
    expect(leftBehind.isEmpty, "the self-test writes nothing into the home it ran in, found \(leftBehind)")

    let support = home.appendingPathComponent("Library/Application Support/Sensorium", isDirectory: true)
    try! FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try! Data("not json".utf8).write(to: support.appendingPathComponent("host-tls-identity.json"))
    let corrupt = run(["--update-self-test"], home: home)
    expect(corrupt.status != 0, "the built host's self-test fails on its own corrupt file, got \(corrupt.status)")
    print("PASS: the built host reads --update-self-test before its own arguments, and an unknown one still exits 2")
}
