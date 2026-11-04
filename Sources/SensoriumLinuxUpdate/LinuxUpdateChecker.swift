import Foundation

public enum LinuxUpdateCheckResult: Equatable, Sendable {
    /// Nothing to install: the running version is current, the release has
    /// no signed Linux manifest yet, or its manifest format is one this
    /// viewer does not read.
    case upToDate
    /// The release page could not be reached. Not a failure, and nothing is
    /// recorded.
    case unreachable
    case failed(LinuxUpdateFailure)
    case available(LinuxUpdateManifest)
    /// A release already recorded as bad, with the recorded reason.
    case givenUp(LinuxUpdateManifest, reason: String)
    /// A release that failed in a way that could pass on another try, and
    /// waits for the next scheduled check before it is tried again.
    case heldBack(LinuxUpdateManifest)
}

/// One check, as sections 3.1 and 11.2 of `docs/self-update-design.md`
/// describe: fetch the manifest and its signature, verify, parse, and
/// decide.
public struct LinuxUpdateChecker: Sendable {
    let runningVersion: LinuxUpdateVersion
    let transport: any LinuxUpdateTransport
    let stateStore: LinuxUpdateStateStore
    let publicKey: Data
    let now: @Sendable () -> Date

    public init(
        runningVersion: LinuxUpdateVersion,
        transport: any LinuxUpdateTransport,
        stateStore: LinuxUpdateStateStore,
        publicKey: Data = LinuxUpdatePublicKey.rawRepresentation,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runningVersion = runningVersion
        self.transport = transport
        self.stateStore = stateStore
        self.publicKey = publicKey
        self.now = now
    }

    public func check() async -> LinuxUpdateCheckResult {
        let manifestData: Data
        let signatureData: Data
        do {
            manifestData = try await transport.fetch(LinuxUpdateReleaseLocation.manifestURL, maximumBytes: LinuxUpdateReleaseLocation.maximumSmallFileBytes)
            signatureData = try await transport.fetch(LinuxUpdateReleaseLocation.signatureURL, maximumBytes: LinuxUpdateReleaseLocation.maximumSmallFileBytes)
        } catch LinuxUpdateTransportError.badStatus(404) {
            // The release is published before its Linux manifest is signed
            // and uploaded; until then there is nothing to offer.
            return recordingCheckTime(.upToDate)
        } catch {
            return .unreachable
        }

        guard LinuxUpdateSignature.isValid(signatureFile: signatureData, for: manifestData, publicKey: publicKey) else {
            return recordingCheckTime(.failed(.signatureInvalid))
        }
        let manifest: LinuxUpdateManifest
        do {
            manifest = try LinuxUpdateManifest.parse(manifestData)
        } catch LinuxUpdateManifestError.unsupportedFormat {
            return recordingCheckTime(.upToDate)
        } catch {
            return recordingCheckTime(.failed(.manifestInvalid))
        }

        let state = stateStore.load()
        let decision = LinuxUpdateDecision.decide(
            offered: manifest.version,
            running: runningVersion,
            highestSeen: state.highestVersionSeen
        )
        let result: LinuxUpdateCheckResult
        switch decision {
        case let .wentBackwards(highestSeen):
            result = .failed(.wentBackwards(highestSeen: highestSeen, offered: manifest.version))
        case .upToDate:
            result = .upToDate
        case .update:
            if let record = state.failure(version: manifest.version, sha256: manifest.sha256), record.kind == .badRelease {
                result = .givenUp(manifest, reason: record.reason)
            } else if state.isHeldBack(version: manifest.version, sha256: manifest.sha256, now: now()) {
                result = .heldBack(manifest)
            } else {
                result = .available(manifest)
            }
        }
        _ = try? stateStore.update { state in
            state.lastCheck = now()
            state.highestVersionSeen = max(state.highestVersionSeen ?? manifest.version, manifest.version)
        }
        return result
    }

    private func recordingCheckTime(_ result: LinuxUpdateCheckResult) -> LinuxUpdateCheckResult {
        _ = try? stateStore.update { $0.lastCheck = now() }
        return result
    }
}
