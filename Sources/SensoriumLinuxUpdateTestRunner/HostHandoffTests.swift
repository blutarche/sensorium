import Foundation
import SensoriumLinuxUpdate

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let serving = LinuxUpdateReadyReport.Host(
    tlsCertificateFingerprint: "aa11",
    deviceIdentityFingerprint: "bb22",
    pairedMachinesDigest: "cc33",
    listenAddress: "100.64.1.5",
    port: 7777,
    screenSharingAllowed: true
)

/// A script line that writes a ready report naming this script's process,
/// `version` and, when given, `host`.
private func reportReady(version text: String, host: LinuxUpdateReadyReport.Host?) -> String {
    var fields = "\"processIdentifier\":%s,\"version\":\"\(text)\""
    if let host {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fields += ",\"host\":" + String(decoding: try! encoder.encode(host), as: UTF8.self)
    }
    return "printf '{\(fields)}' $$ > \"$3.partial\" && mv \"$3.partial\" \"$3\""
}

func testAHostReadyReportMustKeepIdentityPairingsAddressAndScreenSharing() {
    expect(serving.mismatch(comparedWith: serving) == nil, "a host that serves the same way matches")

    var changed = serving
    changed.tlsCertificateFingerprint = "ff00"
    expect(changed.mismatch(comparedWith: serving) == "TLS identity", "a new TLS identity is refused")
    changed = serving
    changed.deviceIdentityFingerprint = "ff00"
    expect(changed.mismatch(comparedWith: serving) == "device identity", "a new device identity is refused")
    changed = serving
    changed.pairedMachinesDigest = "ff00"
    expect(changed.mismatch(comparedWith: serving) == "paired machines", "a change in the paired machines is refused")
    changed = serving
    changed.listenAddress = "100.64.1.6"
    expect(changed.mismatch(comparedWith: serving) == "listen address", "another listen address is refused")
    changed = serving
    changed.port = 7778
    expect(changed.mismatch(comparedWith: serving) == "listen address", "another port is refused")

    changed = serving
    changed.screenSharingAllowed = false
    expect(changed.mismatch(comparedWith: serving) == "screen sharing", "losing screen sharing is refused")
    var withoutSharing = serving
    withoutSharing.screenSharingAllowed = false
    expect(serving.mismatch(comparedWith: withoutSharing) == nil, "gaining screen sharing is not")

    let directory = makeTemporaryDirectory("host-report")
    defer { removeTemporaryDirectory(directory) }
    let folder = directory.appendingPathComponent("handoff", isDirectory: true)
    mkdir(folder.path, 0o700)
    let readyFile = folder.appendingPathComponent(LinuxUpdateHandoff.readyFileName)
    do {
        try LinuxUpdateHandoff.reportReady(version: version("0.8.0"), to: readyFile, processIdentifier: 42, host: serving)
    } catch {
        return expect(false, "a host's ready report is written, got \(error)")
    }
    expect(
        LinuxUpdateHandoff.readReport(at: readyFile) == LinuxUpdateReadyReport(processIdentifier: 42, version: version("0.8.0"), host: serving),
        "and reads back with its host values"
    )
    writeFile("{\"processIdentifier\":42,\"version\":\"0.8.0\"}", to: readyFile)
    expect(
        LinuxUpdateHandoff.readReport(at: readyFile) == LinuxUpdateReadyReport(processIdentifier: 42, version: version("0.8.0")),
        "a viewer's report, with no host values, still reads"
    )
}

func testAHostHandsOverOnlyToANewHostThatServesTheSameWay() async {
    let directory = makeTemporaryDirectory("host-restart")
    defer { removeTemporaryDirectory(directory) }
    let installation = installationForHandoff(directory)
    let me = getpid()
    let restart = LinuxUpdateRestart(installation: installation, readyTimeout: 1.5, quitGrace: 0.5)

    func attempt(_ host: LinuxUpdateReadyReport.Host?, then body: String = "") async -> LinuxUpdateRestartOutcome {
        let script = reportReady(version: "0.6.0", host: host) + (body.isEmpty ? "" : "\n" + body)
        let staged = stagedScript("0.6.0", in: installation, oldProcess: me, body: script)
        return await restart.run(staged, processIdentifier: me, hostBaseline: serving)
    }

    var otherPort = serving
    otherPort.port = 7778
    let moved = await attempt(otherPort)
    expect(moved == .failed(.readyMismatch("listen address")), "a new host on another port is refused, got \(moved)")
    expect(installation.currentVersion() == version("0.5.0"), "and current is switched back")
    expect(installation.pendingSwitch() == nil, "and no switch is pending")

    var lostSharing = serving
    lostSharing.screenSharingAllowed = false
    let blind = await attempt(lostSharing)
    expect(blind == .failed(.readyMismatch("screen sharing")), "a new host that lost screen sharing is refused, got \(blind)")
    expect(installation.currentVersion() == version("0.5.0"), "and current is switched back")

    let silentAboutHost = await attempt(nil)
    expect(silentAboutHost == .failed(.readyMismatch("host")), "a new host that names no host values is refused, got \(silentAboutHost)")

    // A refused report must stay refused under the lock that decides the
    // switch back, even when the new version confirms right after it.
    let confirmsAnyway = await attempt(otherPort, then: "rm -f \"\(installation.pendingMarker.path)\"\nexec sleep 30")
    expect(confirmsAnyway == .failed(.readyMismatch("listen address")), "a refused new host that confirms is still refused, got \(confirmsAnyway)")
    expect(installation.currentVersion() == version("0.5.0"), "and current goes back although the marker was already gone")
    expect(handoffFolders(in: installation).isEmpty, "the handoff folder is removed")

    let tookOver = await attempt(serving)
    expect(tookOver == .tookOver, "a new host that serves the same way takes over, got \(tookOver)")
    expect(installation.currentVersion() == version("0.6.0"), "and current names it")
}

func testTheMismatchReasonMatchesTheOtherInstallFailures() {
    let mismatch = LinuxUpdateFailure.readyMismatch("listen address")
    expect(mismatch.kind == .couldPassOnAnotherTry, "a mismatched new host could pass on another try")
    expect(mismatch.reason == LinuxUpdateFailure.readyLate.reason, "and reads like a late one: \(mismatch.reason)")
}
