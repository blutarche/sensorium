import Foundation
import SensoriumCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The separate checks of staging: section 3.2 and section 11.4 steps 1 and
/// 3 of `docs/self-update-design.md`.
public enum LinuxUpdateStaging {
    public static let selfTestTimeout: TimeInterval = 10
    public static let selfTestArgument = "--update-self-test"

    /// How much of the self-test's output is read. Only its first line
    /// counts.
    static let maximumSelfTestOutput = 4096

    private static let selfTestOutputName = ".self-test-output"

    /// The size, then the SHA-256. The file is mapped rather than read, and
    /// the manifest's size cap bounds it.
    public static func verifyDownload(at file: URL, size: Int64, sha256: String) -> LinuxUpdateFailure? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == size else {
            return .sizeMismatch
        }
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else {
            return .downloadFailed
        }
        let digest = SensoriumCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
        return digest == sha256 ? nil : .digestMismatch
    }

    /// Runs `executable` with `--update-self-test` alone. It must exit 0
    /// within `timeout`, and the first line it prints must be exactly
    /// `Sensorium <version>`. Its output goes to a file beside it, removed
    /// afterwards, so a child that keeps the output open cannot stall the
    /// wait.
    public static func runSelfTest(
        executable: URL,
        version: LinuxUpdateVersion,
        timeout: TimeInterval = selfTestTimeout
    ) async -> LinuxUpdateFailure? {
        await LinuxUpdateChildProcess.offThePool {
            selfTest(executable: executable, version: version, timeout: timeout)
        }
    }

    private static func selfTest(executable: URL, version: LinuxUpdateVersion, timeout: TimeInterval) -> LinuxUpdateFailure? {
        let output = executable.deletingLastPathComponent().appendingPathComponent(selfTestOutputName)
        unlink(output.path)
        let descriptor = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return .stagingFailed }
        defer { unlink(output.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = [selfTestArgument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .selfTestFailed(status: -1)
        }

        switch LinuxUpdateChildProcess.wait(for: process, timeout: timeout) {
        case .timedOut:
            return .selfTestTimedOut
        case let .exited(status) where status != 0:
            return .selfTestFailed(status: status)
        case let .signaled(signal):
            return .selfTestFailed(status: signal)
        case .exited:
            break
        }

        var buffer = [UInt8](repeating: 0, count: maximumSelfTestOutput)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, $0.count, 0) }
        guard count >= 0 else { return .stagingFailed }
        let printed = Data(buffer.prefix(count))
        let firstLine = printed.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        let expected = "Sensorium \(version)"
        guard Data(firstLine) == Data(expected.utf8) else {
            return .wrongArchiveContents("the new binary does not report itself as \(expected)")
        }
        return nil
    }
}
