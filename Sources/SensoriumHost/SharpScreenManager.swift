import AppKit
import Foundation
import SensoriumCore

/// One live host-screen session's hold on the sharp screen. Released when
/// that session ends; releasing it more than once counts once.
@MainActor
public final class SharpScreenLease {
    public let displayID: UInt32
    private weak var manager: SharpScreenManager?
    private let key: Int

    init(displayID: UInt32, manager: SharpScreenManager, key: Int) {
        self.displayID = displayID
        self.manager = manager
        self.key = key
    }

    public func release() {
        manager?.endLease(key)
        manager = nil
    }
}

/// Owns the sharp screen (`SharpScreen`) for this whole host process: at most
/// one at a time, shared by every live host-screen session that uses it.
///
/// A session admitted on macOS's placeholder screen asks for a lease. The
/// first one creates the sharp screen and waits for it to be usable; any
/// other session starting meanwhile waits for the same one. When the last
/// lease is released the display stays for a grace period, so a viewer that
/// reconnects straight away finds the same display, and is released after
/// it. Every display created here is also recorded in `CanvasShutdown`, so
/// quitting the host releases it like a canvas.
@MainActor
public final class SharpScreenManager {
    /// Why a session on the sharp screen ended when a monitor came online.
    public static let monitorConnectedReason = "A monitor was connected to the host."
    /// Why a session on the sharp screen ended when it went away on its own.
    public static let vanishedReason = "The host's sharp screen went away."

    public enum LeaseOutcome: Sendable {
        /// The admitted display is not the placeholder, so the session
        /// streams it as it is.
        case notNeeded
        case leased(SharpScreenLease)
        /// A sharp screen was needed but could not be made usable. It has
        /// been released again, and the session streams the placeholder.
        case failed
    }

    private let creator: any VirtualDisplayCreating
    private let displays: @MainActor () -> [DisplaySnapshot]
    private let isRuntimeAvailable: @MainActor () -> Bool
    private let isCaptureResolvable: @MainActor (UInt32) async -> Bool
    private let shutdown: CanvasShutdown?
    private let log: @MainActor (String) -> Void
    private let readinessBoundSeconds: Double
    private let releaseGraceSeconds: Double
    private let pollSeconds: Double
    private let wait: @MainActor (Double) async -> Void
    private let now: @MainActor () -> Double

    /// The display this manager created and has not released, ready or not.
    private var handle: VirtualDisplayHandle?
    /// Set once `handle` has passed its readiness check.
    private var isReady = false
    /// The creation and readiness wait in flight, which every session
    /// starting meanwhile joins rather than starting a second one.
    private var creation: Task<UInt32?, Never>?
    /// Each live lease's handler for the sharp screen going away under it.
    private var leases: [Int: @MainActor (String) -> Void] = [:]
    private var nextLeaseKey = 0
    private var graceRelease: Task<Void, Never>?
    private var displayChangeObserver: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - isRuntimeAvailable: whether this machine has the virtual-display
    ///     runtime at all. Asked before anything is created.
    ///   - isCaptureResolvable: whether ScreenCaptureKit can find a display,
    ///     part of deciding it is ready.
    ///   - readinessBoundSeconds: how long a new display has to become ready.
    ///   - releaseGraceSeconds: how long the display outlives its last lease.
    public init(
        creator: any VirtualDisplayCreating,
        displays: @escaping @MainActor () -> [DisplaySnapshot],
        isRuntimeAvailable: @escaping @MainActor () -> Bool,
        isCaptureResolvable: @escaping @MainActor (UInt32) async -> Bool,
        shutdown: CanvasShutdown? = nil,
        log: @escaping @MainActor (String) -> Void,
        readinessBoundSeconds: Double = 5,
        releaseGraceSeconds: Double = 10,
        pollSeconds: Double = 0.1,
        wait: @escaping @MainActor (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        now: @escaping @MainActor () -> Double = {
            Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
        }
    ) {
        self.creator = creator
        self.displays = displays
        self.isRuntimeAvailable = isRuntimeAvailable
        self.isCaptureResolvable = isCaptureResolvable
        self.shutdown = shutdown
        self.log = log
        self.readinessBoundSeconds = max(readinessBoundSeconds, 0)
        self.releaseGraceSeconds = max(releaseGraceSeconds, 0)
        self.pollSeconds = max(pollSeconds, 0.001)
        self.wait = wait
        self.now = now
    }

    /// The sharp screen's display ID while one is up and ready, `nil`
    /// otherwise.
    public var displayID: UInt32? {
        isReady ? handle?.rawValue : nil
    }

    /// Decides whether a session admitted on `admitted` streams a sharp
    /// screen instead, and if so holds one for it.
    ///
    /// A sharp screen is created only when `admitted` is macOS's placeholder
    /// by `SharpScreen.isPlaceholder` and the virtual-display runtime is
    /// present. While one is up, macOS has taken the placeholder away, so a
    /// later session is admitted on the sharp screen itself and joins it.
    /// `onLost` is called if the sharp screen goes away while this lease is
    /// held, with a plain reason for the host log.
    public func lease(
        forAdmittedDisplayID admitted: UInt32,
        onLost: @escaping @MainActor (String) -> Void
    ) async -> LeaseOutcome {
        if let creation {
            guard let id = await creation.value, displayID == id else {
                return .failed
            }
            return grant(id, onLost: onLost)
        }
        if let id = displayID {
            guard admitted == id else {
                return .notNeeded
            }
            return grant(id, onLost: onLost)
        }
        let current = displays()
        guard let display = current.first(where: { $0.id == admitted }),
              SharpScreen.isPlaceholder(display, among: current),
              isRuntimeAvailable() else {
            return .notNeeded
        }
        let task = Task { @MainActor [self] in await createAndWaitUntilReady() }
        creation = task
        let id = await task.value
        creation = nil
        guard let id, displayID == id else {
            return .failed
        }
        return grant(id, onLost: onLost)
    }

    /// Checks the sharp screen against a fresh display list. Called on every
    /// display change macOS reports, the sharp screen's own arrival
    /// included, so only a monitor coming online counts, never a change as
    /// such. A monitor ends every session on the sharp screen and releases
    /// it at once, grace period or not: a person at the host now has a
    /// screen of their own. A sharp screen missing from the list ends every
    /// session on it too, rather than leaving them waiting for a display
    /// that is not coming back.
    public func displaysChanged() {
        guard creation == nil, let handle else {
            return
        }
        let current = displays()
        if SharpScreen.hasMonitor(current) {
            log("a monitor was connected; ending every session on sharp screen \(handle.rawValue) and releasing it")
            endEveryLease(reason: Self.monitorConnectedReason)
            release(handle)
        } else if isReady, !current.contains(where: { $0.id == handle.rawValue && $0.online }) {
            log("sharp screen \(handle.rawValue) went away on its own; ending every session on it")
            endEveryLease(reason: Self.vanishedReason)
            release(handle)
        }
    }

    /// Calls `displaysChanged()` on every display change AppKit reports, for
    /// as long as this manager lives. Called once by the host process that
    /// owns it; calling it again adds nothing.
    public func observeDisplayChanges() {
        guard displayChangeObserver == nil else {
            return
        }
        // No queue, so it is delivered on the thread that posts it, which for
        // this notification is AppKit's main thread.
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysChanged()
            }
        }
    }

    private func endEveryLease(reason: String) {
        let ending = leases.values
        leases.removeAll()
        for onLost in ending {
            onLost(reason)
        }
    }

    private func grant(_ id: UInt32, onLost: @escaping @MainActor (String) -> Void) -> LeaseOutcome {
        graceRelease?.cancel()
        graceRelease = nil
        let key = nextLeaseKey
        nextLeaseKey += 1
        leases[key] = onLost
        return .leased(SharpScreenLease(displayID: id, manager: self, key: key))
    }

    fileprivate func endLease(_ key: Int) {
        guard leases.removeValue(forKey: key) != nil, leases.isEmpty, handle != nil else {
            return
        }
        graceRelease?.cancel()
        graceRelease = Task { @MainActor [weak self] in
            guard let self else { return }
            await wait(releaseGraceSeconds)
            guard !Task.isCancelled, leases.isEmpty, let handle else {
                return
            }
            release(handle)
            log(
                "sharp screen \(handle.rawValue) released: no session has used it for "
                    + Self.secondsWords(releaseGraceSeconds)
            )
        }
    }

    private func createAndWaitUntilReady() async -> UInt32? {
        let created: VirtualDisplayHandle
        do {
            created = try creator.create(configuration: SharpScreen.configuration, identity: SharpScreen.identity)
        } catch {
            logNotUsed("macOS refused to create it (\(HostOperatorLog.describe(error)))")
            return nil
        }
        handle = created
        isReady = false
        shutdown?.record(created) { [self] recorded in
            releaseAtQuit(recorded)
        }
        if let why = await waitUntilReady(created.rawValue) {
            if handle == created {
                release(created)
            }
            logNotUsed(why)
            await waitForPlaceholder()
            return nil
        }
        guard handle == created else {
            // Released while it was still being checked: the host is quitting.
            return nil
        }
        isReady = true
        log(
            "sharp screen \(created.rawValue) is ready: \(SharpScreen.configuration.logicalWidth)x"
                + "\(SharpScreen.configuration.logicalHeight) at \(SharpScreen.configuration.scale)x, "
                + "standing in for macOS's placeholder screen"
        )
        return created.rawValue
    }

    /// Waits up to `readinessBoundSeconds` for the new display to read back
    /// online with a display mode and a place on the desktop, and for
    /// ScreenCaptureKit to find it. `nil` once it is ready; otherwise the
    /// last thing still missing, in words for the host log.
    private func waitUntilReady(_ id: UInt32) async -> String? {
        let deadline = now() + readinessBoundSeconds
        var missing = "it did not come online"
        while true {
            let current = displays()
            if let display = current.first(where: { $0.id == id && $0.online }) {
                if display.modeWidth > 0, display.modeHeight > 0,
                   display.modePixelWidth > 0, display.modePixelHeight > 0,
                   display.bounds.width > 0, display.bounds.height > 0 {
                    if await isCaptureResolvable(id) {
                        return nil
                    }
                    missing = "ScreenCaptureKit could not find it"
                } else {
                    missing = "it came online but reported no display mode"
                }
            }
            guard now() < deadline else {
                return "\(missing) within \(Self.secondsWords(readinessBoundSeconds))"
            }
            await wait(pollSeconds)
        }
    }

    /// Releasing the sharp screen brings the placeholder back under a new
    /// display ID. Waits, up to the same bound, for it to be there, so a
    /// session that falls back to it finds it.
    private func waitForPlaceholder() async {
        let deadline = now() + readinessBoundSeconds
        while SharpScreen.placeholder(among: displays()) == nil, now() < deadline {
            await wait(pollSeconds)
        }
    }

    private func release(_ released: VirtualDisplayHandle) {
        shutdown?.forget(released)
        releaseAtQuit(released)
    }

    /// `CanvasShutdown` has already dropped its own record by the time it
    /// calls this.
    private func releaseAtQuit(_ released: VirtualDisplayHandle) {
        if handle == released {
            handle = nil
            isReady = false
            graceRelease?.cancel()
            graceRelease = nil
        }
        creator.destroy(released)
    }

    private func logNotUsed(_ why: String) {
        log("sharp screen not used: \(why); streaming macOS's placeholder screen instead")
    }

    private static func secondsWords(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) seconds" : "\(seconds) seconds"
    }
}
