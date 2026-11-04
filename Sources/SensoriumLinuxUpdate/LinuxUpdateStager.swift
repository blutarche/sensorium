import Foundation

/// Downloads a release and puts it in place, tested, as section 11.4 steps 1
/// to 3 of `docs/self-update-design.md` describe. It does not switch
/// `current`. Any failure removes what it made.
public struct LinuxUpdateStager: Sendable {
    let installation: LinuxUpdateInstallation
    let transport: any LinuxUpdateTransport
    let selfTestTimeout: TimeInterval
    let gzip: URL

    public init(
        installation: LinuxUpdateInstallation,
        transport: any LinuxUpdateTransport,
        selfTestTimeout: TimeInterval = LinuxUpdateStaging.selfTestTimeout,
        gzip: URL = LinuxUpdateArchive.defaultGzip
    ) {
        self.installation = installation
        self.transport = transport
        self.selfTestTimeout = selfTestTimeout
        self.gzip = gzip
    }

    /// `manifest` is one whose signature has verified.
    public func stage(_ manifest: LinuxUpdateManifest) async -> Result<LinuxStagedUpdate, LinuxUpdateFailure> {
        guard let staging = try? installation.makeStagingDirectory() else {
            return .failure(.stagingFailed)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(manifest.file)
        do {
            try await transport.download(LinuxUpdateReleaseLocation.downloadURL(for: manifest), to: archive, maximumBytes: manifest.size)
        } catch LinuxUpdateTransportError.tooLarge {
            return .failure(.sizeMismatch)
        } catch {
            return .failure(.downloadFailed)
        }
        let gzip = gzip
        let verified = await LinuxUpdateChildProcess.offThePool { () -> Result<URL, LinuxUpdateFailure> in
            if let failure = LinuxUpdateStaging.verifyDownload(at: archive, size: manifest.size, sha256: manifest.sha256) {
                return .failure(failure)
            }
            let extracted = LinuxUpdateArchive.extract(archive, into: staging, gzip: gzip)
            // Removed before the self-test, so the folder moved into place
            // holds the binary alone.
            try? FileManager.default.removeItem(at: archive)
            return extracted
        }
        let binary: URL
        switch verified {
        case let .success(extracted):
            binary = extracted
        case let .failure(failure):
            return .failure(failure)
        }

        if let failure = await LinuxUpdateStaging.runSelfTest(executable: binary, version: manifest.version, timeout: selfTestTimeout) {
            return .failure(failure)
        }
        guard let placed = installation.moveIntoPlace(staging, as: manifest.version) else {
            return .failure(.stagingFailed)
        }
        return .success(LinuxStagedUpdate(
            version: manifest.version,
            sha256: manifest.sha256,
            executable: placed.appendingPathComponent(LinuxUpdateInstallation.executableName)
        ))
    }
}
