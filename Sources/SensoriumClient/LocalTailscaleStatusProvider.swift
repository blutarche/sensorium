import Foundation
import SensoriumCore

/// Reads this machine's real tailnet status by asking the `tailscale` command-line
/// tool -- the same interface a person would type at a Terminal, and what
/// talks to `tailscaled`'s LocalAPI so this code never has to hold that
/// socket open itself.
///
/// Never invoked by anything in `Tests/` or a `TestRunner`: every test in
/// this repository runs against `FixtureTailnetStatusProvider`. This type is
/// exercised deliberately, on a real machine with a real tailnet -- see
/// `docs/testing.md` -- never as a side effect of running the suite.
///
/// Chose the CLI over reading `tailscaled`'s LocalAPI socket directly:
/// LocalAPI is documented by Tailscale as internal and unstable, and its
/// macOS GUI build gates access to its own signed processes, so a
/// third-party socket read is a likely refusal. Spawning this subprocess
/// needs no entitlement while Sensorium is Developer-ID signed and not
/// App-Sandboxed; adopting the App Sandbox would need this revisited. See
/// `docs/install.md`.
public struct LocalTailscaleStatusProvider: TailnetStatusProviding {
    /// Every place this machine might have the CLI, tried in order until one is
    /// actually executable. Covers both common Homebrew install prefixes and
    /// the GUI app's own bundled binary, which answers the same `status`
    /// verb Homebrew's standalone `tailscale` does.
    public static let candidateExecutablePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    ]

    private let executablePaths: [String]

    public init(executablePaths: [String] = LocalTailscaleStatusProvider.candidateExecutablePaths) {
        self.executablePaths = executablePaths
    }

    public func statusJSON() async throws -> Data {
        // `FileManager` is not `Sendable`, so `.default` is read fresh here
        // rather than held as a stored property this `Sendable` struct would
        // then have to smuggle across actors.
        guard let path = executablePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LocalTailscaleStatusProviderError.tailscaleNotFound
        }
        return try await run(path)
    }

    private func run(_ path: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let stdout = Pipe()
            process.standardOutput = stdout
            // Discarded, not surfaced: a person choosing a machine from a list
            // does not need tailscaled's own diagnostic text, only whether
            // the attempt worked -- see `TailnetDevicePickerFetchError`.
            process.standardError = Pipe()
            process.terminationHandler = { finished in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if finished.terminationStatus == 0, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(
                        throwing: LocalTailscaleStatusProviderError.processFailed(
                            exitCode: finished.terminationStatus
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LocalTailscaleStatusProviderError.launchFailed)
            }
        }
    }
}

/// Every way asking the local `tailscale` binary can fail before a byte of
/// status ever comes back. Mapped to a person-readable reason by
/// `TailnetDevicePickerLoader`, never surfaced with this case's own name.
public enum LocalTailscaleStatusProviderError: Error, Equatable, Sendable {
    /// None of `LocalTailscaleStatusProvider.candidateExecutablePaths` exists
    /// and is executable -- Tailscale is very likely not installed.
    case tailscaleNotFound
    /// The binary exists but could not even be launched.
    case launchFailed
    /// The binary ran and exited, but not with a usable answer: a non-zero
    /// exit code (tailscaled not running, most commonly) or no output at all.
    case processFailed(exitCode: Int32)
}
