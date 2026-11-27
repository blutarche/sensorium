#if os(Linux)
import Foundation
import Glibc
import SensoriumLinuxHost

private func makeExecutable(at url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("#!/bin/sh\n".utf8).write(to: url)
    chmod(url.path, 0o755)
}

private func entryLines(_ autostart: HostAutostart) -> [String] {
    let text = (try? String(contentsOf: autostart.entryFile, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
}

private func testOpenAtLoginRunsTheInstalledVersionOnceTheHostHasUpdated() async {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-autostart-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let dataRoot = scratch.appendingPathComponent("share with space/sensorium-host", isDirectory: true)
    let packaged = scratch.appendingPathComponent("usr/bin/sensorium-host")
    let autostart = HostAutostart(
        environment: ["XDG_CONFIG_HOME": scratch.appendingPathComponent("config").path],
        home: scratch,
        dataRoot: dataRoot,
        packagedExecutable: packaged
    )
    expect(
        autostart.entryFile.path == scratch.appendingPathComponent("config/autostart/com.sensorium.host.desktop").path,
        "the entry is the host's own under the autostart folder"
    )
    expect(autostart.state == .notAvailable, "with no host binary there is nothing to open at login")

    makeExecutable(at: packaged)
    expect(autostart.state == .off, "a packaged host can be opened at login")
    try! autostart.setEnabled(true)
    expect(autostart.state == .on, "and is once turned on")
    expect(entryLines(autostart).contains("Exec=\(packaged.path) --background"), "running the packaged binary in the background, saw \(entryLines(autostart))")
    expect(entryLines(autostart).contains("TryExec=\(packaged.path)"), "and only while it is there")

    try! autostart.repointIfEnabled()
    expect(entryLines(autostart).contains("Exec=\(packaged.path) --background"), "with no installed version the entry stays as it was")

    let version = dataRoot.appendingPathComponent("versions/0.8.0/sensorium-host")
    makeExecutable(at: version)
    try! FileManager.default.createSymbolicLink(
        atPath: dataRoot.appendingPathComponent("current").path,
        withDestinationPath: "versions/0.8.0"
    )
    let current = dataRoot.appendingPathComponent("current/sensorium-host").path
    expect(autostart.executable.path == current, "once the host has updated itself it runs current")
    try! autostart.repointIfEnabled()
    let quoted = "\"\(current)\""
    expect(entryLines(autostart).contains("Exec=\(quoted) --background"), "an entry that is on now runs current, quoted, saw \(entryLines(autostart))")
    expect(entryLines(autostart).contains("TryExec=\(current)"), "and only while it is there")

    try! autostart.setEnabled(false)
    expect(autostart.state == .off, "turning it off removes the entry")
    try! autostart.repointIfEnabled()
    expect(!FileManager.default.fileExists(atPath: autostart.entryFile.path), "and an update writes none")

    try! FileManager.default.removeItem(at: packaged)
    expect(autostart.state == .off, "an updated host can be opened at login without the package's binary")
    try! autostart.setEnabled(true)
    expect(entryLines(autostart).contains("Exec=\(quoted) --background"), "and turning it on later runs current")
}

func hostAutostartTests() -> [NamedTest] { [
    ("Open at login runs the installed version once the host has updated", testOpenAtLoginRunsTheInstalledVersionOnceTheHostHasUpdated)
] }
#endif
