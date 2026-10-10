#if os(macOS)
import CryptoKit
import Foundation

let fixtureIdentifier = "com.example.updatetest"
let fixtureAppName = "Sensorium Host.app"

enum FixtureExecutable {
    /// A copy of `/usr/bin/true`: a real Mach-O that `codesign` can sign and
    /// that exits 0 whatever its arguments.
    case trueBinary
    /// A shell script, for a self-test that fails or hangs. Never signed.
    case script(String)
}

/// Runs a command-line tool to completion and returns its exit status.
@discardableResult
func runTool(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A minimal app bundle, signed ad hoc under `signingIdentifier` unless that
/// is nil. Ad hoc signing needs no keychain identity.
@discardableResult
func makeAppBundle(
    in directory: URL,
    name: String = fixtureAppName,
    identifier: String = fixtureIdentifier,
    version: String = "0.5.0",
    executable: FixtureExecutable = .trueBinary,
    signingIdentifier: String? = fixtureIdentifier,
    marker: String? = nil
) -> URL {
    let app = directory.appendingPathComponent(name, isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try! FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleExecutable": "Fixture",
        "CFBundleIdentifier": identifier,
        "CFBundleShortVersionString": version,
        "CFBundlePackageType": "APPL"
    ]
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let executableURL = macOS.appendingPathComponent("Fixture")
    switch executable {
    case .trueBinary:
        try! FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableURL)
    case let .script(body):
        try! Data("#!/bin/sh\n\(body)\n".utf8).write(to: executableURL)
    }
    chmod(executableURL.path, 0o755)
    if let marker {
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try! Data(marker.utf8).write(to: resources.appendingPathComponent("marker"))
    }
    if let signingIdentifier {
        let status = runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", signingIdentifier, app.path])
        expect(status == 0, "codesign signs the fixture bundle ad hoc")
    }
    return app
}

func marker(of app: URL) -> String? {
    (try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/marker"))).flatMap { String(data: $0, encoding: .utf8) }
}

/// A zip holding `item` as its one top-level entry, as the release builds it.
func zipItem(_ item: URL, to zip: URL) {
    expect(runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", item.path, zip.path]) == 0, "ditto zips the fixture")
}

/// A zip whose top level is every entry of `folder`.
func zipContents(of folder: URL, to zip: URL) {
    expect(runTool("/usr/bin/ditto", ["-c", "-k", folder.path, zip.path]) == 0, "ditto zips the fixture folder")
}

func sha256Hex(of file: URL) -> String {
    SHA256.hash(data: try! Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
}

func fileSize(of file: URL) -> Int64 {
    (try! FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).int64Value
}
#endif
