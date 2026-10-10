#if os(macOS)
import CryptoKit
import Foundation

/// A new version unpacked and checked, waiting to be swapped in.
public struct StagedUpdate: Equatable, Sendable {
    public let version: UpdateVersion
    public let sha256: String
    /// The owner-only staging folder. After the swap it holds the old app.
    public let directory: URL
    /// The staged app, named like the installed one.
    public let appURL: URL

    /// Where the new instance reports that it is serving.
    public var readyFileURL: URL {
        directory.appendingPathComponent(UpdateHandoff.readyFileName)
    }

    public init(version: UpdateVersion, sha256: String, directory: URL, appURL: URL) {
        self.version = version
        self.sha256 = sha256
        self.directory = directory
        self.appURL = appURL
    }
}

/// Downloads a release and stages it, as sections 3.2 and 3.3 of
/// `docs/self-update-design.md` describe. Any failure removes what it made.
public struct UpdateStager: Sendable {
    let installedAppURL: URL
    let bundleIdentifier: String
    let transport: any UpdateTransport
    let requirement: any UpdateRequirementChecking
    let selfTestTimeout: Duration

    /// `requirement` is `CodeRequirementCheck.runningApp()` in the apps.
    public init(
        installedAppURL: URL,
        bundleIdentifier: String,
        transport: any UpdateTransport = URLSessionUpdateTransport(),
        requirement: any UpdateRequirementChecking,
        selfTestTimeout: Duration = UpdateStaging.selfTestTimeout
    ) {
        self.installedAppURL = installedAppURL
        self.bundleIdentifier = bundleIdentifier
        self.transport = transport
        self.requirement = requirement
        self.selfTestTimeout = selfTestTimeout
    }

    public func stage(_ offer: UpdateOffer) async -> Result<StagedUpdate, UpdateFailure> {
        guard offer.app.bundleIdentifier == bundleIdentifier else {
            return .failure(.wrongBundleContents("the release names another bundle identifier"))
        }
        guard let downloadDirectory = try? UpdateStaging.makeStagingDirectory(appropriateFor: installedAppURL) else {
            return .failure(.stagingFailed)
        }
        defer { try? FileManager.default.removeItem(at: downloadDirectory) }

        let zip = downloadDirectory.appendingPathComponent(offer.app.file)
        do {
            try await transport.download(
                UpdateReleaseLocation.downloadURL(version: offer.version, app: offer.app),
                to: zip,
                maximumBytes: offer.app.size
            )
        } catch UpdateTransportError.tooLarge {
            return .failure(.sizeMismatch)
        } catch {
            return .failure(.downloadFailed)
        }
        if let failure = UpdateStaging.verifyDownload(at: zip, size: offer.app.size, sha256: offer.app.sha256) {
            return .failure(failure)
        }

        guard let directory = try? UpdateStaging.makeStagingDirectory(appropriateFor: installedAppURL) else {
            return .failure(.stagingFailed)
        }
        let result = await unpackAndCheck(zip, into: directory, version: offer.version)
        switch result {
        case let .success(appURL):
            return .success(StagedUpdate(version: offer.version, sha256: offer.app.sha256, directory: directory, appURL: appURL))
        case let .failure(failure):
            try? FileManager.default.removeItem(at: directory)
            return .failure(failure)
        }
    }

    private func unpackAndCheck(_ zip: URL, into directory: URL, version: UpdateVersion) async -> Result<URL, UpdateFailure> {
        guard await UpdateStaging.unzip(zip, into: directory) else {
            return .failure(.wrongBundleContents("the zip could not be unpacked"))
        }
        let validated = UpdateStaging.validateBundle(
            in: directory,
            appName: installedAppURL.lastPathComponent,
            bundleIdentifier: bundleIdentifier,
            version: version
        )
        guard case let .success(appURL) = validated else {
            return validated
        }
        guard requirement.isSatisfied(byBundleAt: appURL) else {
            return .failure(.requirementFailed)
        }
        if let failure = await UpdateStaging.runSelfTest(appURL: appURL, timeout: selfTestTimeout) {
            return .failure(failure)
        }
        return .success(appURL)
    }
}

/// The separate steps of staging.
public enum UpdateStaging {
    public static let selfTestTimeout: Duration = .seconds(10)
    public static let selfTestArgument = "--update-self-test"

    /// The size, then the SHA-256 read in chunks so a large zip is never
    /// held in memory whole.
    public static func verifyDownload(at file: URL, size: Int64, sha256: String) -> UpdateFailure? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.int64Value == size else {
            return .sizeMismatch
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return .downloadFailed
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256 ? nil : .digestMismatch
    }

    /// A new, empty, owner-only folder in the temporary items folder of the
    /// installed app's volume, so the swap is a rename within one volume.
    public static func makeStagingDirectory(appropriateFor installedAppURL: URL) throws -> URL {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: installedAppURL,
            create: true
        )
        guard chmod(directory.path, 0o700) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory
    }

    /// No quarantine attribute and no access control list is carried over
    /// from the zip.
    public static func unzip(_ zip: URL, into directory: URL) async -> Bool {
        let outcome = await ChildProcess.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", "--noqtn", "--noacl", zip.path, directory.path],
            timeout: nil
        )
        return outcome == .exited(0)
    }

    /// The folder must hold exactly one item: a real folder named `appName`,
    /// with the expected bundle identifier and version, in which no symbolic
    /// link leads outside the app and nothing is a device, other special
    /// file, or a file with a second hard link. Returns the app.
    public static func validateBundle(
        in directory: URL,
        appName: String,
        bundleIdentifier: String,
        version: UpdateVersion
    ) -> Result<URL, UpdateFailure> {
        func refuse(_ why: String) -> Result<URL, UpdateFailure> {
            .failure(.wrongBundleContents(why))
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return refuse("the staging folder cannot be read")
        }
        guard names == [appName] else {
            return refuse("the zip must hold exactly one item, \(appName)")
        }
        let app = directory.appendingPathComponent(appName, isDirectory: true)
        guard fileType(app.path) == S_IFDIR else {
            return refuse("\(appName) is not a folder")
        }
        guard let plistData = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return refuse("the app has no readable Info.plist")
        }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            return refuse("the app's bundle identifier is not \(bundleIdentifier)")
        }
        guard plist["CFBundleShortVersionString"] as? String == version.description else {
            return refuse("the app's version is not \(version)")
        }
        guard let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != "..",
              fileType(app.appendingPathComponent("Contents/MacOS/\(executable)").path) == S_IFREG else {
            return refuse("the app's executable is missing")
        }
        guard let root = realPath(app.path) else {
            return refuse("the app's location cannot be resolved")
        }
        if let why = firstUnsafeEntry(in: app.path, root: root) {
            return refuse(why)
        }
        return .success(app)
    }

    /// Runs the staged app's executable with `--update-self-test` alone. It
    /// must exit 0 within `timeout`.
    public static func runSelfTest(appURL: URL, timeout: Duration) async -> UpdateFailure? {
        guard let plistData = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String else {
            return .wrongBundleContents("the app's executable is missing")
        }
        let outcome = await ChildProcess.run(
            appURL.appendingPathComponent("Contents/MacOS/\(executable)"),
            arguments: [selfTestArgument],
            timeout: timeout
        )
        switch outcome {
        case .exited(0):
            return nil
        case let .exited(status), let .signaled(status):
            return .selfTestFailed(status: status)
        case .timedOut:
            return .selfTestTimedOut
        case .couldNotStart:
            return .selfTestFailed(status: -1)
        }
    }

    private static func fileType(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Walks the tree without following any symbolic link. A link is judged
    /// by where the kernel resolves it, so a chain of links, or a `..` after
    /// a link, cannot lead outside unseen. A link that resolves to nothing
    /// is refused, since where it would lead cannot be checked.
    private static func firstUnsafeEntry(in directory: String, root: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return "a folder inside the app cannot be read"
        }
        for name in names {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else {
                return "an item inside the app cannot be read"
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                if let why = firstUnsafeEntry(in: path, root: root) {
                    return why
                }
            case S_IFREG:
                if info.st_nlink > 1 {
                    return "\(name) has a second hard link"
                }
            case S_IFLNK:
                guard let target = realPath(path), target == root || target.hasPrefix(root + "/") else {
                    return "the symbolic link \(name) leads outside the app"
                }
            default:
                return "\(name) is a device or other special file"
            }
        }
        return nil
    }
}
#endif
