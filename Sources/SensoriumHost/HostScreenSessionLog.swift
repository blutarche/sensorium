import Foundation

/// What happened, not what was seen or typed. When nobody is in the room to
/// refuse a host-screen session, this record is the only remaining control:
/// an owner who suspects a stolen key needs somewhere to look. It therefore
/// never carries input content, frame data, or a network address -- only
/// who, which display, and when.
public struct HostScreenSessionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The name the person at this machine gave this device while arming
    /// it -- the same value `HostScreenDeviceArming.deviceName` already
    /// carries, never a value read back from the connection itself.
    public var deviceName: String
    /// `HostScreenArmingPresentation`'s own wording for the target, e.g.
    /// "Built-in Display" -- not a `CGDirectDisplayID`, which is not stable
    /// across sleep or replug and would make an old record unreadable.
    public var displayLabel: String
    public var startedAt: Date
    public var outcome: HostScreenSessionOutcome?
    /// Every time the viewer changed this display's own resolution while the
    /// session ran, in the order it happened -- the one way a host-screen
    /// session alters the machine it runs on, so an owner reading this back
    /// sees it rather than having to infer it. Optional, not an empty array,
    /// so a record written before this existed still reads.
    public var displayModeChanges: [String]?

    public init(
        id: UUID = UUID(),
        deviceName: String,
        displayLabel: String,
        startedAt: Date,
        outcome: HostScreenSessionOutcome? = nil,
        displayModeChanges: [String]? = nil
    ) {
        self.id = id
        self.deviceName = deviceName
        self.displayLabel = displayLabel
        self.startedAt = startedAt
        self.outcome = outcome
        self.displayModeChanges = displayModeChanges
    }
}

/// How a recorded session ended. `nil` on `HostScreenSessionRecord.outcome`
/// is deliberately not a third case here: it means "still open," and the
/// only two ways a reader should ever see it are mid-session in the process
/// that is still running it, or the instant
/// `reconcileAbandonedSessionsAtLaunch()` reconciles a record a *previous*
/// process never got back to -- see its own documentation for why that
/// reconciliation exists.
public enum HostScreenSessionOutcome: Codable, Equatable, Sendable {
    /// The Stop control, or an equivalent orderly teardown, actually ran.
    case stopped(at: Date)
    /// This process's own store found the record still open at launch, which
    /// means the process that began it never called `endSession` -- a crash,
    /// a force quit, or a power loss. There is no true stop time to report,
    /// so none is invented; the record says plainly that the session did not
    /// end cleanly rather than leaving an entry that looks perpetually live.
    case endedWithoutCleanStop
}

/// Host-screen session history at
/// `~/Library/Application Support/Sensorium/host-screen-sessions.log`. A
/// record is written when a session begins, not when it ends, so a process
/// that never reaches `endSession` still leaves one. Call
/// `reconcileAbandonedSessionsAtLaunch()` exactly once at process launch:
/// several instances of this store can legitimately coexist in one process,
/// and each must not mistake another's still-open record for a crash.
/// `@unchecked Sendable`: every method is a synchronous whole-file
/// read-modify-write over a `let url`.
public final class HostScreenSessionLogStore: @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Rewrites every record still open (`outcome == nil`) to
    /// `.endedWithoutCleanStop`. Safe to call whether or not there is
    /// anything to reconcile -- an ordinary shutdown leaves nothing open --
    /// and only ever correct to call at process launch, before this
    /// process's own first `beginSession`: anything open at that moment
    /// cannot belong to this run.
    public func reconcileAbandonedSessionsAtLaunch() {
        var all = load()
        var changed = false
        for index in all.indices where all[index].outcome == nil {
            all[index].outcome = .endedWithoutCleanStop
            changed = true
        }
        guard changed else { return }
        save(all)
    }

    /// Every record, oldest first. Empty, not an error, when nothing has ever
    /// been written -- host screen has never run a session on this machine.
    public func records() -> [HostScreenSessionRecord] {
        load()
    }

    /// The one line `HostScreenSessionLogPresentation` and the Host Setup
    /// window read: what to show for "last host-screen session," or `nil`
    /// when there has never been one.
    public var lastRecord: HostScreenSessionRecord? {
        records().last
    }

    /// Call the moment a host-screen session actually starts streaming.
    /// Written immediately, with `outcome` still `nil`, so a crash a moment
    /// later still leaves this machine's owner a record naming who was driving
    /// its screen and when it began -- reconciled to
    /// `.endedWithoutCleanStop` the next time
    /// `reconcileAbandonedSessionsAtLaunch()` runs, never left silently
    /// open.
    @discardableResult
    public func beginSession(
        deviceName: String,
        displayLabel: String,
        startedAt: Date
    ) -> HostScreenSessionRecord.ID {
        var all = load()
        let record = HostScreenSessionRecord(deviceName: deviceName, displayLabel: displayLabel, startedAt: startedAt)
        all.append(record)
        save(all)
        return record.id
    }

    /// Call once the session actually stopped -- the Stop control, the
    /// viewer dropping cleanly, or any other orderly teardown. Absent or
    /// already-ended records change nothing.
    public func endSession(_ id: HostScreenSessionRecord.ID, endedAt: Date) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }), all[index].outcome == nil else {
            return
        }
        all[index].outcome = .stopped(at: endedAt)
        save(all)
    }

    /// Notes a change to the host screen's own resolution against the
    /// session that made it, leaving the record open: the session did not
    /// end, only what it is streaming changed size. Absent or already-ended
    /// records change nothing.
    public func recordDisplayModeChange(_ id: HostScreenSessionRecord.ID, note: String) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }), all[index].outcome == nil else {
            return
        }
        all[index].displayModeChanges = (all[index].displayModeChanges ?? []) + [note]
        save(all)
    }

    private func load() -> [HostScreenSessionRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([HostScreenSessionRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func save(_ records: [HostScreenSessionRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

/// What the Host Setup window says about the last host-screen session.
/// Deliberately AppKit-free, so the words are testable without a window
/// server.
public enum HostScreenSessionLogPresentation {
    /// `nil` when host screen has never run on this machine.
    public static func line(
        for record: HostScreenSessionRecord?,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let record else { return nil }
        let named = "\(record.deviceName) used \(record.displayLabel)"
        switch record.outcome {
        case let .stopped(endedAt):
            let range = Self.range(from: record.startedAt, to: endedAt, locale: locale, timeZone: timeZone)
            return "\(named) \(range)."
        case .endedWithoutCleanStop:
            let started = Self.formatted(record.startedAt, locale: locale, timeZone: timeZone)
            return "\(named) from \(started). Sensorium Host stopped before the session ended, so the end time is unknown."
        case nil:
            // Still running, as far as this store's own record goes: only
            // reachable within the process that is currently serving it,
            // since `reconcileAbandonedSessionsAtLaunch()` reconciles every
            // other case before this presentation could ever read it.
            let started = Self.formatted(record.startedAt, locale: locale, timeZone: timeZone)
            return "\(named) from \(started); it is still running."
        }
    }

    /// "from 15 Nov 2023, 05:13 to 05:43" same-day, or "from 15 Nov 2023,
    /// 23:50 to 16 Nov 2023, 00:20" across midnight -- never the same date
    /// printed twice with the end time left to wrap on its own, and never an
    /// end time with nothing to say which day it fell on. Both cases share
    /// the same "from ... to ..." shape as `.endedWithoutCleanStop`'s own
    /// "from 15 Nov 2023, 05:13" -- a clean stop is not a different sentence
    /// shape from its abnormal sibling, only a longer one.
    private static func range(from start: Date, to end: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startDay = Self.dateOnly(start, locale: locale, timeZone: timeZone)
        let startTime = Self.timeOnly(start, locale: locale, timeZone: timeZone)
        let endTime = Self.timeOnly(end, locale: locale, timeZone: timeZone)
        guard calendar.isDate(start, inSameDayAs: end) else {
            let endDay = Self.dateOnly(end, locale: locale, timeZone: timeZone)
            return "from \(startDay), \(startTime) to \(endDay), \(endTime)"
        }
        return "from \(startDay), \(startTime) to \(endTime)"
    }

    private static func formatted(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        "\(Self.dateOnly(date, locale: locale, timeZone: timeZone)), \(Self.timeOnly(date, locale: locale, timeZone: timeZone))"
    }

    // Forced to the Gregorian calendar rather than left to the system
    // default: a machine set to a non-Gregorian calendar (Buddhist, Japanese,
    // Islamic, ...) would otherwise print a session year in that calendar
    // with no indication it is not the Gregorian one, on an accountability
    // record whose whole purpose is a reviewer being able to tell when
    // something happened. The locale otherwise stays the caller's own -- the
    // system's, in production -- so language and 12/24-hour convention still
    // follow it.
    private static func dateOnly(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func timeOnly(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
