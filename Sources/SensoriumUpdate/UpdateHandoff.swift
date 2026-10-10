#if os(macOS)
import Foundation

/// What a launch was asked to do. Both apps parse this before any other
/// argument, since an argument they do not know otherwise ends them with a
/// usage message.
public enum UpdateLaunchCommand: Equatable, Sendable {
    /// Run the self-test and exit with its status.
    case selfTest
    /// This is a new instance replacing process `pid`: start normally, then
    /// write the ready report to `readyFile`.
    case replacing(pid: pid_t, readyFile: URL)
    /// Anything else, untouched, for the app's own parsing.
    case normal([String])

    public static let replacingArgument = "--replacing"

    /// `arguments` excludes the program's own path.
    public static func parse(_ arguments: [String]) -> UpdateLaunchCommand {
        if arguments == [UpdateStaging.selfTestArgument] {
            return .selfTest
        }
        if arguments.count == 3,
           arguments[0] == replacingArgument,
           let pid = pid_t(arguments[1]), pid > 0,
           isReadyFilePath(arguments[2]) {
            return .replacing(pid: pid, readyFile: URL(fileURLWithPath: arguments[2]))
        }
        return .normal(arguments)
    }

    /// An absolute path, in a folder below the root, whose last part is the
    /// ready file's name, and with no empty, `.` or `..` part, so the folder
    /// it names is the one it spells.
    private static func isReadyFilePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts.last == Substring(UpdateHandoff.readyFileName) else {
            return false
        }
        return parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func replacingArguments(pid: pid_t, readyFile: URL) -> [String] {
        [replacingArgument, String(pid), readyFile.path]
    }

    /// Runs `selfTest` and ends the process with its status. The self-test
    /// reads, without changing, the state the app needs to serve; it binds
    /// no port and writes nothing.
    public static func runSelfTest(_ selfTest: () -> Int32) -> Never {
        exit(selfTest())
    }
}

/// Why `UpdateHandoff.reportReady` wrote no ready file.
public enum UpdateReadyFileError: Error, Equatable, Sendable {
    case folderMissing
    /// The path names a symbolic link or a file, not a folder.
    case notAFolder
    case notOwnedByThisUser
    /// The folder's mode is anything but 0700.
    case notOwnerOnly
    case couldNotWrite(errno: Int32)
}

/// The new instance's side of the handoff.
public enum UpdateHandoff {
    public static let readyFileName = "update-ready.json"

    /// Written once the host's listener reports ready, or the viewer's
    /// window is up, with values read from this instance's own running
    /// state, and naming `processIdentifier`, this process.
    ///
    /// The path arrives on the command line, so the file is written only
    /// into a folder that already exists, is owned by this user and has
    /// mode 0700, as a staging folder does. No folder is ever created or
    /// changed. Otherwise this throws `UpdateReadyFileError`, and the app
    /// keeps running without reporting.
    public static func reportReady(_ report: UpdateReadyReport, to readyFile: URL, processIdentifier: pid_t = getpid()) throws {
        var report = report
        report.processIdentifier = processIdentifier
        try report.write(to: readyFile)
    }

    /// Waits for the replaced process to exit, then removes the staging
    /// folder, which holds the old app. True if the folder was removed.
    public static func finishReplacing(
        oldProcess pid: pid_t,
        readyFile: URL,
        appName: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        runningAppURL: URL = Bundle.main.bundleURL,
        log: (String) -> Void = { print("Sensorium update: \($0)") }
    ) async -> Bool {
        await waitForExit(of: pid)
        return removeStagingFolder(holding: readyFile, appName: appName, bundleIdentifier: bundleIdentifier, runningAppURL: runningAppURL, log: log)
    }

    /// Returns once process `pid` has exited.
    public static func waitForExit(of pid: pid_t, pollInterval: Duration = .milliseconds(500)) async {
        if hasExited(pid) {
            return
        }
        let waiter = ExitWaiter()
        await withCheckedContinuation { continuation in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
            waiter.arm(continuation, source: source)
            source.setEventHandler { waiter.finish() }
            source.resume()
            // A process that exited before the source was armed raises no
            // event, and a source that cannot watch it raises none either.
            Task.detached {
                while !waiter.isFinished {
                    if hasExited(pid) {
                        waiter.finish()
                        return
                    }
                    try? await Task.sleep(for: pollInterval)
                }
            }
        }
    }

    /// The path arrives on the command line, so its folder is removed only
    /// if it is one the installer made and the swap left: a real folder,
    /// owned by this user with mode 0700, holding exactly the ready file and
    /// one app named `appName` whose bundle identifier is `bundleIdentifier`,
    /// the running app's own, and not the folder `runningAppURL` sits in.
    /// Otherwise nothing is removed and `log` says why. True if the folder
    /// was removed.
    public static func removeStagingFolder(
        holding readyFile: URL,
        appName: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        runningAppURL: URL = Bundle.main.bundleURL,
        log: (String) -> Void = { print("Sensorium update: \($0)") }
    ) -> Bool {
        let directory = readyFile.deletingLastPathComponent()
        func refuse(_ why: String) -> Bool {
            log("not removing \(directory.path): \(why)")
            return false
        }
        guard readyFile.lastPathComponent == readyFileName else {
            return refuse("the ready file is not named \(readyFileName)")
        }
        var folder = stat()
        guard lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR else {
            return refuse("it is not a folder")
        }
        guard folder.st_uid == geteuid() else {
            return refuse("it is not owned by this user")
        }
        guard folder.st_mode & 0o7777 == 0o700 else {
            return refuse("it is not owner-only")
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              names.count == 2, Set(names) == [readyFileName, appName] else {
            return refuse("it holds something other than \(readyFileName) and \(appName)")
        }
        let app = directory.appendingPathComponent(appName, isDirectory: true)
        var appInfo = stat()
        guard lstat(app.path, &appInfo) == 0, appInfo.st_mode & S_IFMT == S_IFDIR else {
            return refuse("\(appName) in it is not a folder")
        }
        guard let bundleIdentifier else {
            return refuse("the running app's bundle identifier is unknown")
        }
        guard Self.bundleIdentifier(ofAppAt: app) == bundleIdentifier else {
            return refuse("\(appName) in it does not have the bundle identifier \(bundleIdentifier)")
        }
        var runningFolder = stat()
        guard stat(runningAppURL.deletingLastPathComponent().path, &runningFolder) == 0 else {
            return refuse("the running app's folder cannot be read")
        }
        guard runningFolder.st_dev != folder.st_dev || runningFolder.st_ino != folder.st_ino else {
            return refuse("it holds the running app")
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            return refuse("it could not be removed")
        }
        return true
    }

    private static func bundleIdentifier(ofAppAt app: URL) -> String? {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var info = stat()
        guard lstat(plistURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    private static func hasExited(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }
}

/// Resumes one waiter once, from whichever of the exit source and the poll
/// fires first.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var source: (any DispatchSourceProcess)?
    private var finished = false

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func arm(_ continuation: CheckedContinuation<Void, Never>, source: any DispatchSourceProcess) {
        lock.withLock {
            self.continuation = continuation
            self.source = source
        }
    }

    func finish() {
        let (continuation, source) = lock.withLock {
            defer {
                finished = true
                self.continuation = nil
                self.source = nil
            }
            return (self.continuation, self.source)
        }
        source?.cancel()
        continuation?.resume()
    }
}
#endif
