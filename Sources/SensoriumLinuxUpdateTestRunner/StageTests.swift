import Foundation
import SensoriumCore
import SensoriumLinuxUpdate

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func hexDigest(_ data: Data) -> String {
    SensoriumCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
}

func testDownloadIsCheckedForSizeAndDigest() {
    let directory = makeTemporaryDirectory("download")
    defer { removeTemporaryDirectory(directory) }
    let file = directory.appendingPathComponent("Sensorium-0.6.0-linux-x86_64.tar.gz")
    let bytes = Data((0..<100_000).map { UInt8($0 % 251) })
    try! bytes.write(to: file)
    let digest = hexDigest(bytes)

    expect(LinuxUpdateStaging.verifyDownload(at: file, size: Int64(bytes.count), sha256: digest) == nil, "a download of the right size and digest passes")
    expect(
        LinuxUpdateStaging.verifyDownload(at: file, size: Int64(bytes.count) + 1, sha256: digest) == .sizeMismatch,
        "a download of another size is refused before it is hashed"
    )
    expect(
        LinuxUpdateStaging.verifyDownload(at: file, size: Int64(bytes.count), sha256: String(repeating: "0", count: 64)) == .digestMismatch,
        "a download with another digest is refused"
    )
    expect(
        LinuxUpdateStaging.verifyDownload(at: directory.appendingPathComponent("missing"), size: 1, sha256: digest) == .sizeMismatch,
        "a download that is not there is refused"
    )
}

/// A shell script standing in for a staged binary.
private func writeScript(_ body: String, in directory: URL) -> URL {
    let url = directory.appendingPathComponent("Sensorium")
    writeFile("#!/bin/sh\n\(body)\n", to: url, mode: 0o755)
    return url
}

func testSelfTestPassesFailsAndTimesOut() async {
    let directory = makeTemporaryDirectory("self-test")
    defer { removeTemporaryDirectory(directory) }
    let expected = version("0.6.0")
    let argumentCheck = "[ \"$#\" -eq 1 ] && [ \"$1\" = --update-self-test ] || exit 9"

    func selfTest(_ body: String, timeout: TimeInterval = LinuxUpdateStaging.selfTestTimeout) async -> LinuxUpdateFailure? {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let binary = writeScript(body, in: folder)
        let failure = await LinuxUpdateStaging.runSelfTest(executable: binary, version: expected, timeout: timeout)
        let left = try! FileManager.default.contentsOfDirectory(atPath: folder.path)
        expect(left == ["Sensorium"], "the self-test leaves only the binary in its folder, found \(left)")
        return failure
    }

    expect(LinuxUpdateStaging.selfTestTimeout == 10, "the self-test has 10 seconds")
    expect(LinuxUpdateStaging.selfTestArgument == "--update-self-test", "the self-test argument is --update-self-test")

    let passed = await selfTest("\(argumentCheck)\necho 'Sensorium 0.6.0'\necho 'more output'")
    expect(passed == nil, "a binary that prints its version and exits 0 passes, got \(String(describing: passed))")

    let failed = await selfTest("\(argumentCheck)\necho 'Sensorium 0.6.0'\nexit 3")
    expect(failed == .selfTestFailed(status: 3), "a binary that exits with an error fails, got \(String(describing: failed))")

    let crashed = await selfTest("\(argumentCheck)\nkill -SEGV $$")
    guard case .selfTestFailed = crashed else {
        return expect(false, "a binary that ends on a signal fails, got \(String(describing: crashed))")
    }

    let wrongVersion = await selfTest("\(argumentCheck)\necho 'Sensorium 0.5.9'")
    guard case .wrongArchiveContents = wrongVersion else {
        return expect(false, "a binary that reports another version is the wrong file, got \(String(describing: wrongVersion))")
    }
    for output in ["", "echo 'Sensorium  0.6.0'", "echo 'sensorium 0.6.0'", "echo 'Sensorium 0.6.0 '", "printf 'Sensorium 0.6.0\\r\\n'", "echo 'banner'; echo 'Sensorium 0.6.0'"] {
        let result = await selfTest("\(argumentCheck)\n\(output)")
        guard case .wrongArchiveContents = result else {
            return expect(false, "a first line other than exactly 'Sensorium 0.6.0' is refused (\(output)), got \(String(describing: result))")
        }
    }

    let started = Date()
    let hung = await selfTest("\(argumentCheck)\necho 'Sensorium 0.6.0'\nexec sleep 30", timeout: 0.5)
    expect(hung == .selfTestTimedOut, "a binary that does not exit in time times out, got \(String(describing: hung))")
    expect(Date().timeIntervalSince(started) < 5, "a timed-out self-test is ended, not waited for")

    let missing = await LinuxUpdateStaging.runSelfTest(executable: directory.appendingPathComponent("missing"), version: expected)
    guard case .selfTestFailed = missing else {
        return expect(false, "a binary that cannot start fails, got \(String(describing: missing))")
    }
}
