import Foundation
import SensoriumCore

/// Whether the one-time "open at login, on by default" registration has
/// already run on this machine.
public struct HostAutoLoginDefaultApplied: Codable, Equatable, Sendable {
    public var applied: Bool
    public init(applied: Bool = false) {
        self.applied = applied
    }
}

/// Where the one-time default's own "has this run" flag is read and written.
/// Mirrors `HostScreenArmingStore`'s file-based pattern: a missing file is
/// the ordinary first run, and an unreadable one counts as already applied
/// rather than as a fresh machine, so a launch can never re-register over
/// whatever the owner has since chosen -- through this app's own switch or
/// through System Settings directly.
public final class HostAutoLoginDefaultAppliedStore {
    private let url: URL
    private let log: (String) -> Void
    private var reportedUnreadableFile = false

    public init(url: URL, log: @escaping (String) -> Void = { print("Sensorium host: \($0)") }) {
        self.url = url
        self.log = log
    }

    public func load() -> HostAutoLoginDefaultApplied {
        guard let data = try? Data(contentsOf: url) else {
            return HostAutoLoginDefaultApplied(applied: false)
        }
        guard let record = try? JSONDecoder().decode(HostAutoLoginDefaultApplied.self, from: data) else {
            if !reportedUnreadableFile {
                reportedUnreadableFile = true
                log(
                    "the auto-login default record at \(url.path) could not be read. "
                        + "Treating the one-time default as already applied."
                )
            }
            return HostAutoLoginDefaultApplied(applied: true)
        }
        return record
    }

    public func markApplied() throws {
        let data = try JSONEncoder().encode(HostAutoLoginDefaultApplied(applied: true))
        try OwnerOnlyFileWrite.write(data, to: url)
    }
}

/// Applies the "open at login, on by default" choice exactly once, on the
/// first launch that has not yet applied it. Every later launch leaves
/// whatever the owner's own choice stands, whether made through this app's
/// switch or directly in System Settings.
public enum HostAutoLoginDefaultRegistration {
    /// Marks the default applied before registering, if the store has not
    /// already marked it, then registers: "register once" means this app
    /// tries the default exactly once, not that it retries on every later
    /// launch. The switch in the host window is how the owner retries by
    /// hand. Marking applied comes first because a `register()` that
    /// succeeded but was never recorded would register again on every later
    /// launch too, once for every launch until the store could persist it.
    /// Returns the first error `markApplied()` or `register()` threw, so a
    /// caller can surface it, or `nil` when nothing needed doing or
    /// registration succeeded.
    @discardableResult
    public static func applyIfNeeded(
        registering: any HostAutoLoginRegistering,
        store: HostAutoLoginDefaultAppliedStore
    ) -> Error? {
        guard !store.load().applied else {
            return nil
        }
        do {
            try store.markApplied()
        } catch {
            return error
        }
        do {
            try registering.register()
        } catch {
            return error
        }
        return nil
    }
}
