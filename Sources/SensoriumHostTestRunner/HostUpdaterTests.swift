import Foundation
import SensoriumHost
import SensoriumUpdate

private func scratchFolder(_ label: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-\(label)-\(UUID().uuidString)", isDirectory: true)
}

/// The host window's one update line, in the words section 1.3 of
/// `docs/self-update-design.md` gives it.
func runHostUpdateStatusLineTests() {
    let running = UpdateVersion("0.4.0")!
    let newer = UpdateVersion("0.5.0")!

    expect(
        HostUpdateStatusLine.line(for: .current, runningVersion: running) == "Sensorium Host 0.4.0, up to date",
        "current"
    )
    expect(
        HostUpdateStatusLine.line(for: .waiting(newer), runningVersion: running)
            == "Sensorium Host 0.5.0 will install when no machine is connected",
        "waiting"
    )
    expect(
        HostUpdateStatusLine.line(for: .failed(reason: "the new version did not start in time"), runningVersion: running)
            == "Sensorium Host could not update: the new version did not start in time. It keeps running 0.4.0.",
        "failed, with the core's plain reason"
    )
    expect(
        HostUpdateStatusLine.line(for: .notUpdatable, runningVersion: running)
            == "Move Sensorium Host to Applications and open it again to receive updates.",
        "not updatable"
    )
    print("PASS: the four host update lines read exactly as the design gives them")

    expect(
        HostUpdateStatusLine.line(for: .ready(newer), runningVersion: running)
            == HostUpdateStatusLine.line(for: .waiting(newer), runningVersion: running),
        "a staged host update is the waiting line"
    )
    expect(HostUpdateStatusLine.line(for: .checking, runningVersion: running) == nil, "checking keeps the line it had")
    expect(
        HostUpdateStatusLine.line(for: .downloading(newer), runningVersion: running) == nil,
        "downloading keeps the line it had"
    )
    print("PASS: checking and downloading leave the line as it was")
}

/// **Install updates automatically**, kept in its own owner-only file.
func runHostUpdatePreferenceTests() {
    expect(HostUpdatePreferenceFileCoding.decode(Data("not json".utf8)) == true, "an unreadable file reads as on")
    expect(HostUpdatePreferenceFileCoding.decode(Data()) == true, "an empty file reads as on")
    expect(
        HostUpdatePreferenceFileCoding.decode(HostUpdatePreferenceFileCoding.encode(false)!) == false,
        "a recorded off reads back as off"
    )
    expect(
        HostUpdatePreferenceFileCoding.decode(HostUpdatePreferenceFileCoding.encode(true)!) == true,
        "a recorded on reads back as on"
    )
    print("PASS: the preference reads as on unless off was recorded")

    let folder = scratchFolder("host-update-preferences")
    let url = folder.appendingPathComponent(FileHostUpdatePreferenceStore.fileName)
    expect(FileHostUpdatePreferenceStore.fileName == "host-update-preferences.json", "the file name says whose it is")
    let store = FileHostUpdatePreferenceStore(url: url)
    expect(store.installsAutomatically(), "nothing recorded reads as on")
    expect((try? store.remember(installsAutomatically: false)) != nil, "turning it off is saved")
    expect(!FileHostUpdatePreferenceStore(url: url).installsAutomatically(), "off survives a fresh store, as at relaunch")
    let fileMode = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue
    let folderMode = ((try? FileManager.default.attributesOfItem(atPath: folder.path))?[.posixPermissions] as? NSNumber)?.intValue
    expect(fileMode == 0o600, "the file is readable by its owner alone, got \(String(fileMode ?? -1, radix: 8))")
    expect(folderMode == 0o700, "a folder the store makes is its owner's alone")
    expect((try? store.remember(installsAutomatically: true)) != nil, "turning it on is saved")
    expect(FileHostUpdatePreferenceStore(url: url).installsAutomatically(), "turning it back on is remembered too")
    print("PASS: the checkbox's state round-trips through an owner-only file")

    let blocked = FileHostUpdatePreferenceStore(url: URL(fileURLWithPath: "/dev/null/host-update-preferences.json"))
    var threw = false
    do {
        try blocked.remember(installsAutomatically: false)
    } catch {
        threw = true
    }
    expect(threw, "a preference that could not be saved says so, so the window can tell the person")
    print("PASS: a preference that could not be saved is reported, not dropped")
}

/// A build without a bundle version, as `swift run` makes, has no updater:
/// no scheduler, no request, no line.
func runHostUpdateBundleTests() {
    expect(HostUpdateBundle.read(infoDictionary: nil) == nil, "no Info.plist at all is no updater")
    expect(
        HostUpdateBundle.read(infoDictionary: ["CFBundleIdentifier": "com.sensorium.host"]) == nil,
        "no CFBundleShortVersionString is no updater"
    )
    expect(
        HostUpdateBundle.read(infoDictionary: [
            "CFBundleIdentifier": "com.sensorium.host",
            "CFBundleShortVersionString": "dev"
        ]) == nil,
        "a version that is not one this app can compare is no updater"
    )
    expect(
        HostUpdateBundle.read(infoDictionary: ["CFBundleShortVersionString": "0.4.0"]) == nil,
        "no bundle identifier is no updater: nothing could be checked against it"
    )
    expect(
        HostUpdateBundle.read(infoDictionary: [
            "CFBundleIdentifier": "com.sensorium.host",
            "CFBundleShortVersionString": "0.4.0"
        ]) == HostUpdateBundle(version: UpdateVersion("0.4.0")!, bundleIdentifier: "com.sensorium.host"),
        "a packaged app's version and identifier are read"
    )
    print("PASS: only a packaged app's Info.plist yields an updater")

    var made = 0
    let none = HostUpdateBundle.makeUpdater(infoDictionary: ["CFBundleIdentifier": "com.sensorium.host"]) { bundle in
        made += 1
        return bundle.version
    }
    expect(none == nil && made == 0, "without a version nothing is built, so nothing can make a request")
    let some = HostUpdateBundle.makeUpdater(infoDictionary: [
        "CFBundleIdentifier": "com.sensorium.host",
        "CFBundleShortVersionString": "0.4.0"
    ]) { bundle in
        made += 1
        return bundle.version
    }
    expect(some == UpdateVersion("0.4.0") && made == 1, "with a version the updater is built once")
    print("PASS: the updater is inert without a bundle version")
}

/// `HostUpdater` drives the core's scheduler from the window's checkbox,
/// **Check for Updates…** and the host's own status.
@MainActor
func runHostUpdaterTests() async {
    let running = UpdateVersion("0.4.0")!
    let newer = UpdateVersion("0.5.0")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let hosting = HostOperatorStatus(connection: .hosting(address: "100.64.1.2"), permissions: granted)
    let serving = HostOperatorStatus(connection: .serving(peerName: "Kestrel Laptop"), permissions: granted)

    final class Probe {
        var checks = 0
        var stages = 0
        var installs = 0
        var idle = true
        var result: UpdateCheckResult = .upToDate
        var logged: [String] = []
    }

    func staged(_ version: UpdateVersion) -> StagedUpdate {
        let directory = scratchFolder("host-update-staged")
        return StagedUpdate(
            version: version,
            sha256: String(repeating: "a", count: 64),
            directory: directory,
            appURL: directory.appendingPathComponent("Sensorium Host.app", isDirectory: true)
        )
    }

    func updater(
        _ probe: Probe,
        preferences: any HostUpdatePreferenceStoring = InMemoryHostUpdatePreferenceStore(),
        installability: UpdateInstallability = .updatable,
        outcome: UpdateHandoffOutcome = .handedOff
    ) -> HostUpdater {
        HostUpdater(version: running, preferences: preferences, log: { probe.logged.append($0) }) { automatic, log in
            HostUpdater.makeScheduler(
                automaticUpdates: automatic,
                installability: installability,
                stateStore: UpdateStateStore(role: .host, directory: scratchFolder("host-update-state")),
                check: {
                    probe.checks += 1
                    return probe.result
                },
                stage: { offer in
                    probe.stages += 1
                    return .success(staged(offer.version))
                },
                isIdle: { probe.idle },
                install: { _ in
                    probe.installs += 1
                    return outcome
                },
                log: log,
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
            )
        }
    }

    func offer(_ version: UpdateVersion) -> UpdateOffer {
        let digest = String(repeating: "a", count: 64)
        let json = """
        {"format":1,"version":"\(version)","minimumMacOS":"13.0","apps":{\
        "viewer":{"bundleIdentifier":"com.sensorium.viewer","file":"Sensorium-\(version).zip","size":1,"sha256":"\(digest)"},\
        "host":{"bundleIdentifier":"com.sensorium.host","file":"Sensorium-Host-\(version).zip","size":1,"sha256":"\(digest)"}}}
        """
        let manifest = try! UpdateManifest.parse(Data(json.utf8))
        return UpdateOffer(version: manifest.version, app: manifest.host)
    }

    do {
        let probe = Probe()
        let host = updater(probe)
        expect(host.line == "Sensorium Host 0.4.0, up to date", "before any check the line is the current one")
        var lines: [String] = []
        host.onLineChange = { lines.append($0) }
        host.start()
        expect(await waitUntil(timeoutSeconds: 5) { probe.checks == 1 }, "starting with the checkbox on checks at once")
        expect(lines.isEmpty, "a check that finds nothing leaves the line as it was, with no flicker through checking")
        expect(
            probe.logged.contains("checking for updates") && probe.logged.contains("update check: up to date"),
            "the check and its result are logged, got \(probe.logged)"
        )
        print("PASS: a host with the checkbox on checks at launch and logs the check")
    }

    do {
        let probe = Probe()
        let host = updater(probe, preferences: InMemoryHostUpdatePreferenceStore(installsAutomatically: false))
        expect(!host.installsAutomatically, "the checkbox starts as it was saved")
        host.start()
        try? await Task.sleep(for: .milliseconds(50))
        expect(probe.checks == 0, "with the checkbox off the host makes no update request at all")
        print("PASS: with the checkbox off the host makes no request")
    }

    do {
        let probe = Probe()
        let preferences = InMemoryHostUpdatePreferenceStore()
        let host = updater(probe, preferences: preferences)
        expect((try? host.setInstallsAutomatically(false)) != nil, "the store accepts off")
        expect(!preferences.installsAutomatically(), "turning the checkbox off is saved")
        host.start()
        try? await Task.sleep(for: .milliseconds(50))
        expect(probe.checks == 0, "turned off before launch's check, nothing is asked")
        expect((try? host.setInstallsAutomatically(true)) != nil, "the store accepts on")
        expect(await waitUntil(timeoutSeconds: 5) { probe.checks == 1 }, "turning it back on checks at once")
        expect(preferences.installsAutomatically(), "turning it on is saved")
        print("PASS: the checkbox turns automatic checks off and on, and is saved")
    }

    do {
        let probe = Probe()
        let host = updater(probe, preferences: InMemoryHostUpdatePreferenceStore(installsAutomatically: false))
        host.start()
        probe.result = .available(offer(newer))
        probe.idle = false
        host.checkForUpdates()
        expect(await waitUntil(timeoutSeconds: 5) { probe.stages == 1 }, "Check for Updates… checks even with the checkbox off")
        expect(
            host.line == "Sensorium Host 0.5.0 will install when no machine is connected",
            "a staged update on a busy host waits, got \(host.line)"
        )
        expect(probe.installs == 0, "nothing installs while a machine is connected")
        expect(
            probe.logged.contains("downloading Sensorium Host 0.5.0")
                && probe.logged.contains("staged Sensorium Host 0.5.0"),
            "the download and its result are logged, got \(probe.logged)"
        )

        host.hostStatusChanged(serving, now: now)
        try? await Task.sleep(for: .milliseconds(20))
        expect(probe.installs == 0, "a session going on is no moment to install")
        probe.idle = true
        host.hostStatusChanged(hosting, now: now)
        expect(await waitUntil(timeoutSeconds: 5) { probe.installs == 1 }, "the session ending installs the waiting update")
        print("PASS: an update waits while a machine is connected and installs once it disconnects")
    }

    do {
        let probe = Probe()
        let host = updater(probe, outcome: .rolledBack(.readyLate))
        probe.result = .available(offer(newer))
        host.start()
        expect(await waitUntil(timeoutSeconds: 5) { probe.installs == 1 }, "an idle host installs at once")
        expect(
            await waitUntil(timeoutSeconds: 5) { host.line == "Sensorium Host 0.5.0 will install when no machine is connected" },
            "a failure that could pass on another try keeps the waiting line, got \(host.line)"
        )
        print("PASS: a failure that could pass on another try keeps the waiting line")
    }

    do {
        let probe = Probe()
        let host = updater(probe)
        probe.result = .heldBack(offer(newer))
        host.start()
        expect(
            await waitUntil(timeoutSeconds: 5) { host.line == "Sensorium Host 0.5.0 will install when no machine is connected" },
            "a release held back until the next check keeps the waiting line, got \(host.line)"
        )
        expect(probe.stages == 0 && probe.installs == 0, "and is neither downloaded nor installed")
        expect(
            probe.logged.contains("update check: Sensorium Host 0.5.0 failed recently and is tried again at the next check"),
            "a held-back release is logged, got \(probe.logged)"
        )
        print("PASS: a release held back until the next check keeps the waiting line and downloads nothing")
    }

    do {
        let probe = Probe()
        let host = updater(probe)
        probe.result = .givenUp(offer(newer), reason: "the new version is not signed like this one")
        host.start()
        expect(
            await waitUntil(timeoutSeconds: 5) {
                host.line == "Sensorium Host could not update: the new version is not signed like this one. It keeps running 0.4.0."
            },
            "a release given up on shows the failed line, got \(host.line)"
        )
        expect(
            probe.logged.contains("update check: Sensorium Host 0.5.0 was given up on: the new version is not signed like this one"),
            "a given-up release is logged, got \(probe.logged)"
        )
        print("PASS: a release given up on shows the failed line")
    }

    do {
        let probe = Probe()
        let host = updater(probe, installability: .notUpdatable(.translocated))
        expect(
            host.line == "Move Sensorium Host to Applications and open it again to receive updates.",
            "an app that cannot replace itself says so from the start"
        )
        print("PASS: an app run from where it cannot be replaced shows the not-updatable line at once")
    }

    do {
        let probe = Probe()
        let host = updater(probe)
        host.showInstallFailure(reason: "the new version is not signed like this one")
        expect(
            host.line == "Sensorium Host could not update: the new version is not signed like this one. It keeps running 0.4.0.",
            "an install failure the host itself must report shows the failed line"
        )
        probe.result = .upToDate
        host.start()
        expect(await waitUntil(timeoutSeconds: 5) { probe.checks == 1 }, "the scheduler still runs")
        expect(
            host.line.hasPrefix("Sensorium Host could not update:"),
            "the failed line stays for the rest of this process's life"
        )
        print("PASS: an install failure the host reports itself holds the failed line")
    }
}

/// Every step lands in the host's log with nothing that identifies a machine.
func runHostUpdateLogLineTests() {
    let newer = UpdateVersion("0.5.0")!
    let lines = [
        HostUpdateLog.describe(.upToDate),
        HostUpdateLog.describe(.unreachable),
        HostUpdateLog.describe(UpdateCheckResult.failed(.signatureInvalid)),
        HostUpdateLog.describe(UpdateHandoffOutcome.handedOff),
        HostUpdateLog.describe(UpdateHandoffOutcome.rolledBack(.readyMismatch("host"))),
        HostUpdateLog.describe(UpdateHandoffOutcome.rollbackRelaunchFailed(.readyLate)),
        HostUpdateLog.describe(UpdateHandoffOutcome.swapBackFailed(.requirementFailed)),
        HostUpdateLog.describe(UpdateHandoffOutcome.notUpdatable(.folderNotWritable)),
        HostUpdateLog.describe(UpdateHandoffOutcome.failed(.swapFailed)),
        HostUpdateLog.describeStage(.failure(.digestMismatch), version: newer)
    ]
    expect(lines[0] == "update check: up to date", "up to date, got \(lines[0])")
    expect(lines[1] == "update check: the release page could not be reached", "unreachable, got \(lines[1])")
    expect(lines[3] == "the new version reported ready; quitting", "handed off, got \(lines[3])")
    expect(lines[4].contains("readyMismatch(\"host\")") && lines[4].contains("rolled back"), "rollback, got \(lines[4])")
    expect(lines[6].hasPrefix("UPDATE FAILED"), "a swap back that failed is logged loudly, got \(lines[6])")
    for line in lines {
        expect(!line.contains("100.64."), "no address is logged: \(line)")
    }
    print("PASS: each update step has its own log line, with no address in it")
}
