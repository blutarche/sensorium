#if os(macOS)
import Foundation

/// A release this app may install: the manifest's version and this app's
/// entry in it.
public struct UpdateOffer: Equatable, Sendable {
    public let version: UpdateVersion
    public let app: UpdateManifest.App

    public init(version: UpdateVersion, app: UpdateManifest.App) {
        self.version = version
        self.app = app
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    /// Nothing to install: the running version is current, the release
    /// needs a newer macOS, or its manifest format is one this app does not
    /// read.
    case upToDate
    /// The release page could not be reached. Not a failure, and nothing is
    /// recorded.
    case unreachable
    case failed(UpdateFailure)
    case available(UpdateOffer)
    /// A release already recorded as bad, with the recorded reason.
    case givenUp(UpdateOffer, reason: String)
    /// A release that failed in a way that could pass on another try, and
    /// waits for the next scheduled check before it is tried again.
    case heldBack(UpdateOffer)
}

/// One check, as section 3.1 of `docs/self-update-design.md` describes:
/// fetch the manifest and its signature, verify, parse, and decide.
public struct UpdateChecker: Sendable {
    let role: UpdateAppRole
    let runningVersion: UpdateVersion
    let transport: any UpdateTransport
    let stateStore: UpdateStateStore
    let publicKey: Data
    let system: OperatingSystemVersion
    let now: @Sendable () -> Date

    public init(
        role: UpdateAppRole,
        runningVersion: UpdateVersion,
        transport: any UpdateTransport = URLSessionUpdateTransport(),
        stateStore: UpdateStateStore,
        publicKey: Data = UpdatePublicKey.rawRepresentation,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.role = role
        self.runningVersion = runningVersion
        self.transport = transport
        self.stateStore = stateStore
        self.publicKey = publicKey
        self.system = system
        self.now = now
    }

    public func check() async -> UpdateCheckResult {
        let manifestData: Data
        let signatureData: Data
        do {
            manifestData = try await transport.fetch(UpdateReleaseLocation.manifestURL, maximumBytes: UpdateReleaseLocation.maximumSmallFileBytes)
            signatureData = try await transport.fetch(UpdateReleaseLocation.signatureURL, maximumBytes: UpdateReleaseLocation.maximumSmallFileBytes)
        } catch {
            return .unreachable
        }

        guard UpdateSignature.isValid(signatureFile: signatureData, for: manifestData, publicKey: publicKey) else {
            return recordingCheckTime(.failed(.signatureInvalid))
        }
        let manifest: UpdateManifest
        do {
            manifest = try UpdateManifest.parse(manifestData)
        } catch UpdateManifestError.unsupportedFormat {
            return recordingCheckTime(.upToDate)
        } catch {
            return recordingCheckTime(.failed(.manifestInvalid))
        }

        let state = stateStore.load()
        let decision = UpdateDecision.decide(
            offered: manifest.version,
            minimumMacOS: manifest.minimumMacOS,
            running: runningVersion,
            highestSeen: state.highestVersionSeen,
            system: system
        )
        let offer = UpdateOffer(version: manifest.version, app: manifest.app(role))
        let result: UpdateCheckResult
        switch decision {
        case .requiresNewerMacOS:
            return recordingCheckTime(.upToDate)
        case let .wentBackwards(highestSeen):
            result = .failed(.wentBackwards(highestSeen: highestSeen, offered: manifest.version))
        case .upToDate:
            result = .upToDate
        case .update:
            if let record = state.failure(version: offer.version, sha256: offer.app.sha256), record.kind == .badRelease {
                result = .givenUp(offer, reason: record.reason)
            } else if state.isHeldBack(version: offer.version, sha256: offer.app.sha256, now: now()) {
                result = .heldBack(offer)
            } else {
                result = .available(offer)
            }
        }
        _ = try? stateStore.update { state in
            state.lastCheck = now()
            state.highestVersionSeen = max(state.highestVersionSeen ?? manifest.version, manifest.version)
        }
        return result
    }

    private func recordingCheckTime(_ result: UpdateCheckResult) -> UpdateCheckResult {
        _ = try? stateStore.update { $0.lastCheck = now() }
        return result
    }
}
#endif
