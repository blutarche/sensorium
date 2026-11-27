#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumHost
import SensoriumLinuxHost

private func testTheSelfTestAndTheReplacingLaunchAreRoutedBeforeAnythingElse() async {
    expect(LinuxHostLaunchRoute.route(["--update-self-test"]) == .updateSelfTest, "the self-test is its own launch")
    let readyFile = URL(fileURLWithPath: "/home/ada/.local/share/sensorium-host/.handoff-1/update-ready.json")
    expect(
        LinuxHostLaunchRoute.route(["--replacing", "42", readyFile.path])
            == .host(arguments: ["--background"], replacing: LinuxHostReplacement(pid: 42, readyFile: readyFile)),
        "a replacing launch starts the host in the background, naming the process it replaces"
    )
    expect(LinuxHostLaunchRoute.route(["--serve"]) == .host(arguments: ["--serve"], replacing: nil), "anything else is the host's own")
    expect(
        LinuxHostLaunchRoute.route(["--replacing", "42"]) == .host(arguments: ["--replacing", "42"], replacing: nil),
        "and so is a replacing launch with no ready file"
    )
}

private func testAReplacingLaunchIsHonouredOnlyFromTheHostThatStartedItForThisVersion() async {
    let readyFile = URL(fileURLWithPath: "/home/ada/.local/share/sensorium-host/.handoff-1/update-ready.json")
    let replacement = LinuxHostReplacement(pid: 42, readyFile: readyFile)
    func verdict(parent: pid_t, pending: String?) -> LinuxHostReplacementVerdict {
        LinuxHostLaunchRoute.verdict(for: replacement, parentProcess: parent, pendingVersion: pending, runningVersion: "0.9.0")
    }
    expect(verdict(parent: 42, pending: "0.9.0") == .relaunch, "the replaced host as parent and a pending switch to this version is an update relaunch")
    guard case let .ordinary(parentReason) = verdict(parent: 7, pending: "0.9.0") else {
        return expect(false, "a parent that is not the replaced host is an ordinary launch")
    }
    expect(parentReason.contains("parent"), "and says it was the parent, saw \(parentReason)")
    guard case let .ordinary(noneReason) = verdict(parent: 42, pending: nil) else {
        return expect(false, "no pending switch is an ordinary launch")
    }
    expect(noneReason.contains("pending"), "and says no switch was pending, saw \(noneReason)")
    expect(verdict(parent: 42, pending: "0.8.0") != .relaunch, "a switch to another version is an ordinary launch")
}

/// Every name, size, mode and modification time, so a write or a removal
/// anywhere in the folder shows.
private func snapshot(_ directory: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.sorted().map { name in
        let attributes = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)) ?? [:]
        return [
            name,
            String(describing: attributes[.size] ?? "-"),
            String(describing: attributes[.posixPermissions] ?? "-"),
            String(describing: attributes[.modificationDate] ?? "-")
        ].joined(separator: " ")
    }
}

private func testTheHostSelfTestReadsWhatTheHostServesWithAndWritesNothing() async {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-host-self-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    var lines: [String] = []
    let empty = LinuxHostUpdateSelfTest.run(dataFolder: folder, versionLine: "Sensorium Host 0.8.0") { lines.append($0) }
    expect(empty == 0, "a host with nothing saved yet passes")
    expect(lines.first == "Sensorium Host 0.8.0", "and prints its version first, saw \(lines)")
    expect(!FileManager.default.fileExists(atPath: folder.path), "and makes no data folder")

    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let device = try! FileDeviceIdentityStore(url: folder.appendingPathComponent(LinuxHostDataFiles.deviceIdentity)).loadOrCreate()
    _ = try! FileHostTLSIdentityStore(url: folder.appendingPathComponent(LinuxHostDataFiles.tlsIdentity), commonName: "Sensorium Host").loadOrCreate()
    FileApprovedDeviceStore(url: folder.appendingPathComponent(LinuxHostDataFiles.approvedDevices)).save([device.publicKey])
    let before = snapshot(folder)
    lines = []
    let saved = LinuxHostUpdateSelfTest.run(dataFolder: folder, versionLine: "Sensorium Host 0.8.0") { lines.append($0) }
    expect(saved == 0, "a host that reads its identities and paired machines passes, saw \(lines)")
    expect(lines.first == "Sensorium Host 0.8.0", "and prints its version first")
    expect(snapshot(folder) == before, "and leaves every file as it was")

    let tls = folder.appendingPathComponent(LinuxHostDataFiles.tlsIdentity)
    let good = try! Data(contentsOf: tls)
    var stored = try! JSONSerialization.jsonObject(with: good) as! [String: String]
    stored["privateKey"] = Data(repeating: 4, count: 97).base64EncodedString()
    try! JSONSerialization.data(withJSONObject: stored).write(to: tls)
    lines = []
    expect(
        LinuxHostUpdateSelfTest.run(dataFolder: folder, versionLine: "Sensorium Host 0.8.0") { lines.append($0) } == 1,
        "a TLS key that does not match its certificate fails, saw \(lines)"
    )
    try! good.write(to: tls)

    try! Data("not a list".utf8).write(to: folder.appendingPathComponent(LinuxHostDataFiles.approvedDevices))
    expect(
        LinuxHostUpdateSelfTest.run(dataFolder: folder, versionLine: "Sensorium Host 0.8.0") { _ in } == 1,
        "paired machines that cannot be read fail rather than read as none"
    )
}

func hostUpdateLaunchTests() -> [NamedTest] { [
    ("the self-test and the replacing launch are routed before anything else", testTheSelfTestAndTheReplacingLaunchAreRoutedBeforeAnythingElse),
    ("a replacing launch is honoured only from the host that started it for this version", testAReplacingLaunchIsHonouredOnlyFromTheHostThatStartedItForThisVersion),
    ("the host self-test reads what the host serves with and writes nothing", testTheHostSelfTestReadsWhatTheHostServesWithAndWritesNothing)
] }
#endif
