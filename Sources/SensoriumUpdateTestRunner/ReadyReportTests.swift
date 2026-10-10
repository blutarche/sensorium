#if os(macOS)
import Foundation
import SensoriumUpdate

func sampleHostValues() -> UpdateReadyReport.Host {
    UpdateReadyReport.Host(
        identityFingerprint: "f1e2d3c4b5a69788",
        pairedMachinesDigest: sampleDigest,
        tailnetAddress: "100.64.1.10",
        port: 7300,
        interfaceName: "utun4",
        allowsLocalNetwork: false
    )
}

func sampleReport(version: String = "0.4.0", host: UpdateReadyReport.Host? = sampleHostValues()) -> UpdateReadyReport {
    UpdateReadyReport(
        version: UpdateVersion(version)!,
        screenRecordingGranted: true,
        accessibilityGranted: true,
        loginItemStatus: UpdateReadyReport.LoginItemStatus.enabled,
        host: host
    )
}

/// Writes `report` as JSON with no process identifier, as no current
/// writer would.
func writeReportWithoutProcess(_ report: UpdateReadyReport, to file: URL) {
    var report = report
    report.processIdentifier = nil
    try! JSONEncoder().encode(report).write(to: file)
}

func testReadyReportRoundTripsOwnerOnly() {
    let directory = makeTemporaryDirectory("ready")
    defer { removeTemporaryDirectory(directory) }
    chmod(directory.path, 0o700)
    let file = directory.appendingPathComponent(UpdateHandoff.readyFileName)
    expect(UpdateReadyReport.read(from: file) == nil, "a missing ready file reads as not ready")

    let report = sampleReport(version: "0.5.0")
    expect(report.processIdentifier == nil, "a report names no process until it is written")
    try! UpdateHandoff.reportReady(report, to: file)
    var written = report
    written.processIdentifier = getpid()
    expect(UpdateReadyReport.read(from: file) == written, "a ready report reads back as written, naming the process that wrote it")
    expect(posixMode(of: file) == 0o600, "the ready file is owner-only")
    expect(try! FileManager.default.contentsOfDirectory(atPath: directory.path) == [UpdateHandoff.readyFileName], "an atomic write leaves no temporary file")

    let viewer = UpdateReadyReport(version: UpdateVersion("0.5.0")!, screenRecordingGranted: nil, accessibilityGranted: nil, loginItemStatus: "notRegistered", host: nil)
    try! UpdateHandoff.reportReady(viewer, to: file, processIdentifier: 4321)
    expect(UpdateReadyReport.read(from: file)?.processIdentifier == 4321, "the writer's process identifier is recorded")
    var writtenViewer = viewer
    writtenViewer.processIdentifier = 4321
    expect(UpdateReadyReport.read(from: file) == writtenViewer, "a viewer's report, with no permissions or host block, round-trips")

    writeReportWithoutProcess(sampleReport(version: "0.5.0"), to: file)
    expect(UpdateReadyReport.read(from: file)?.processIdentifier == nil, "a report that names no process reads with none")

    try! Data(repeating: 0x20, count: 70_000).write(to: file)
    expect(UpdateReadyReport.read(from: file) == nil, "an oversized ready file is not read")
}

func testReadyReportIsAcceptedOnlyWhenNothingGotWorse() {
    let baseline = sampleReport(version: "0.4.0")
    let expected = UpdateVersion("0.5.0")!
    func accepted(_ report: UpdateReadyReport) -> Bool {
        report.mismatch(comparedWith: baseline, expectedVersion: expected) == nil
    }
    func modified(_ change: (inout UpdateReadyReport) -> Void) -> UpdateReadyReport {
        var report = sampleReport(version: "0.5.0")
        change(&report)
        return report
    }
    func host(_ change: (inout UpdateReadyReport.Host) -> Void) -> UpdateReadyReport {
        modified { report in
            var values = sampleHostValues()
            change(&values)
            report.host = values
        }
    }

    expect(accepted(sampleReport(version: "0.5.0")), "the new version reporting every value unchanged is accepted")
    expect(!accepted(sampleReport(version: "0.4.0")), "a report from the old version is refused")
    expect(!accepted(sampleReport(version: "0.5.1")), "a report from any other version is refused")

    expect(!accepted(modified { $0.screenRecordingGranted = false }), "Screen Recording going from granted to not granted is refused")
    expect(!accepted(modified { $0.screenRecordingGranted = nil }), "Screen Recording going from granted to unknown is refused")
    expect(!accepted(modified { $0.accessibilityGranted = false }), "Accessibility going from granted to not granted is refused")
    expect(!accepted(modified { $0.loginItemStatus = UpdateReadyReport.LoginItemStatus.requiresApproval }), "Open at login going from enabled to needing approval is refused")
    expect(!accepted(modified { $0.loginItemStatus = UpdateReadyReport.LoginItemStatus.notRegistered }), "Open at login going from enabled to off is refused")

    expect(!accepted(host { $0.identityFingerprint = "0000000000000000" }), "another identity is refused")
    expect(!accepted(host { $0.pairedMachinesDigest = String(repeating: "cd", count: 32) }), "other paired machines are refused")
    expect(!accepted(host { $0.tailnetAddress = "100.64.1.11" }), "another tailnet address is refused")
    expect(!accepted(host { $0.port = 7301 }), "another port is refused")
    expect(!accepted(host { $0.interfaceName = "utun5" }), "another interface is refused")
    expect(!accepted(host { $0.interfaceName = nil }), "losing the interface is refused")
    expect(!accepted(host { $0.allowsLocalNetwork = true }), "a changed local network setting is refused")
    expect(!accepted(modified { $0.host = nil }), "a report missing the host block the old version had is refused")

    let ungranted = UpdateReadyReport(version: UpdateVersion("0.4.0")!, screenRecordingGranted: false, accessibilityGranted: nil, loginItemStatus: UpdateReadyReport.LoginItemStatus.notRegistered, host: nil)
    let improved = UpdateReadyReport(version: expected, screenRecordingGranted: true, accessibilityGranted: true, loginItemStatus: UpdateReadyReport.LoginItemStatus.enabled, host: nil)
    expect(improved.mismatch(comparedWith: ungranted, expectedVersion: expected) == nil, "a permission or login item that got better is accepted")
    let same = UpdateReadyReport(version: expected, screenRecordingGranted: false, accessibilityGranted: nil, loginItemStatus: UpdateReadyReport.LoginItemStatus.requiresApproval, host: nil)
    expect(same.mismatch(comparedWith: ungranted, expectedVersion: expected) == nil, "a login item that was not enabled before may be in any state")
    expect(!accepted(UpdateReadyReport(version: expected, screenRecordingGranted: true, accessibilityGranted: true, loginItemStatus: UpdateReadyReport.LoginItemStatus.enabled, host: nil)), "a viewer-shaped report does not satisfy a host's baseline")
}
#endif
