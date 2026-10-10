import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// `SharpScreenManager` against a fake headless host that behaves the way a
/// real one was observed to: creating the sharp screen takes the placeholder
/// away, and releasing it brings the placeholder back under a new display ID.
/// No real display is created; every wait is a few milliseconds.

/// A host with no monitor, as the window server presents it.
final class FakeHeadlessHost: VirtualDisplayCreating {
    private(set) var placeholderID: UInt32 = 4
    private(set) var sharpID: UInt32?
    private var nextSharpID: UInt32 = 20
    private(set) var attemptedIdentities: [CanvasDisplayIdentity] = []
    private(set) var attemptedConfigurations: [VirtualCanvasConfiguration] = []
    private(set) var destroyedHandles: [VirtualDisplayHandle] = []
    var refusesCreation = false
    /// The sharp screen reads online but with no display mode, the way a
    /// bare process once read a new virtual display back.
    var sharpScreenReportsNoMode = false
    var sharpScreenNeverComesOnline = false
    var monitorConnected = false
    /// The sharp screen is gone from the display list while this process
    /// still holds it.
    var sharpScreenVanished = false

    func create(
        configuration: VirtualCanvasConfiguration,
        identity: CanvasDisplayIdentity
    ) throws -> VirtualDisplayHandle {
        attemptedIdentities.append(identity)
        attemptedConfigurations.append(configuration)
        if refusesCreation {
            throw CoreGraphicsVirtualDisplayError.creationFailed
        }
        let id = nextSharpID
        nextSharpID += 1
        sharpID = id
        return VirtualDisplayHandle(rawValue: id)
    }

    func destroy(_ handle: VirtualDisplayHandle) {
        destroyedHandles.append(handle)
        if sharpID == handle.rawValue {
            sharpID = nil
            sharpScreenVanished = false
            placeholderID += 2
        }
    }

    func metrics(for handle: VirtualDisplayHandle) throws -> VirtualDisplayMetrics {
        throw CoreGraphicsVirtualDisplayError.metricsUnavailable
    }

    func read() -> [DisplaySnapshot] {
        var displays: [DisplaySnapshot] = []
        if monitorConnected {
            displays.append(monitorSnapshot(id: 2))
        }
        if let sharpID, !sharpScreenNeverComesOnline, !sharpScreenVanished {
            if sharpScreenReportsNoMode {
                displays.append(DisplaySnapshot(
                    id: sharpID, pixelWidth: 0, pixelHeight: 0, modeWidth: 0, modeHeight: 0,
                    modePixelWidth: 0, modePixelHeight: 0, bounds: .zero, online: true,
                    builtin: false, main: true,
                    vendorNumber: CanvasDisplayIdentity.vendorID,
                    modelNumber: CanvasDisplayIdentity.productID,
                    serialNumber: SharpScreen.identity.serialNumber
                ))
            } else {
                displays.append(sharpScreenSnapshot(id: sharpID))
            }
        }
        if sharpID == nil, !monitorConnected {
            displays.append(placeholderSnapshot(id: placeholderID))
        }
        return displays
    }
}

/// Every lease's lost-handler call, in order.
@MainActor
final class SharpScreenLossRecorder {
    private(set) var reasons: [String] = []
    func record(_ reason: String) { reasons.append(reason) }
}

@MainActor
func makeSharpScreenManager(
    host: FakeHeadlessHost,
    log: DiagnosticsRecorder = DiagnosticsRecorder(),
    shutdown: CanvasShutdown? = nil,
    runtimeAvailable: Bool = true,
    captureResolvable: @escaping @MainActor (UInt32) async -> Bool = { _ in true },
    releaseGraceSeconds: Double = 0.05
) -> SharpScreenManager {
    SharpScreenManager(
        creator: host,
        displays: { host.read() },
        isRuntimeAvailable: { runtimeAvailable },
        isCaptureResolvable: captureResolvable,
        shutdown: shutdown,
        log: { log.record($0) },
        readinessBoundSeconds: 0.05,
        releaseGraceSeconds: releaseGraceSeconds,
        pollSeconds: 0.005
    )
}

@MainActor
func runSharpScreenManagerTests() async {
    do {
        let host = FakeHeadlessHost()
        let shutdown = CanvasShutdown()
        let log = DiagnosticsRecorder()
        let manager = makeSharpScreenManager(host: host, log: log, shutdown: shutdown)
        let outcome = await manager.lease(forAdmittedDisplayID: host.placeholderID) { _ in }
        guard case let .leased(lease) = outcome else {
            expect(false, "a session admitted on the placeholder leases a sharp screen, got \(outcome)")
            return
        }
        expect(host.attemptedIdentities == [SharpScreen.identity], "it is created once, with the sharp screen's own identity")
        expect(
            host.attemptedConfigurations == [VirtualCanvasConfiguration(logicalWidth: 1920, logicalHeight: 1080, scale: 2)],
            "at 1920x1080 points and 2x, got \(host.attemptedConfigurations)"
        )
        expect(lease.displayID == host.sharpID, "the lease names the sharp screen's own display")
        expect(manager.displayID == host.sharpID, "and the manager reports it as its one sharp screen")
        expect(shutdown.liveCanvasCount == 1, "it is recorded for release at quit, like a canvas")
        expect(
            log.messages.contains { $0.contains("sharp screen") && $0.contains("ready") },
            "the host log says the sharp screen is ready, got \(log.messages)"
        )
    }
    print("PASS: a session admitted on macOS's placeholder screen gets a sharp screen, created once at 1920x1080 and 2x")

    do {
        let host = FakeHeadlessHost()
        let noRuntime = makeSharpScreenManager(host: host, runtimeAvailable: false)
        let outcome = await noRuntime.lease(forAdmittedDisplayID: host.placeholderID) { _ in }
        guard case .notNeeded = outcome else {
            expect(false, "with no virtual-display runtime the placeholder streams as it is, got \(outcome)")
            return
        }
        expect(host.attemptedIdentities.isEmpty, "and nothing is created")

        host.monitorConnected = true
        let manager = makeSharpScreenManager(host: host)
        let beside = await manager.lease(forAdmittedDisplayID: 2) { _ in }
        guard case .notNeeded = beside else {
            expect(false, "a session on a monitor streams it as it is, got \(beside)")
            return
        }
        expect(host.attemptedIdentities.isEmpty, "and nothing is created for it")

        let orphanList = FakeDisplayList([sharpScreenSnapshot(id: 30)])
        let orphanManager = SharpScreenManager(
            creator: host,
            displays: { orphanList.read() },
            isRuntimeAvailable: { true },
            isCaptureResolvable: { _ in true },
            log: { _ in }
        )
        let orphan = await orphanManager.lease(forAdmittedDisplayID: 30) { _ in }
        guard case .notNeeded = orphan else {
            expect(false, "a sharp screen an earlier host left behind streams as it is, got \(orphan)")
            return
        }
        expect(host.attemptedIdentities.isEmpty, "and is never replaced by a second one")
    }
    print("PASS: no sharp screen is created without the virtual-display runtime, beside a monitor, or over one an earlier host left behind")

    do {
        let host = FakeHeadlessHost()
        host.sharpScreenReportsNoMode = true
        let shutdown = CanvasShutdown()
        let log = DiagnosticsRecorder()
        let manager = makeSharpScreenManager(host: host, log: log, shutdown: shutdown)
        let originalPlaceholder = host.placeholderID
        let outcome = await manager.lease(forAdmittedDisplayID: originalPlaceholder) { _ in }
        guard case .failed = outcome else {
            expect(false, "a sharp screen that never reports a display mode is not used, got \(outcome)")
            return
        }
        expect(host.destroyedHandles.count == 1, "it is released again, got \(host.destroyedHandles)")
        expect(shutdown.liveCanvasCount == 0, "and no longer held for release at quit")
        expect(manager.displayID == nil, "the manager holds no sharp screen afterwards")
        let lines = log.messages.filter { $0.contains("sharp screen not used") }
        expect(lines.count == 1, "the host log says once why it was not used, got \(log.messages)")
        expect(lines.first?.contains("display mode") == true, "naming the missing display mode, got \(lines)")
        expect(
            host.read().contains { $0.id == host.placeholderID && $0.id != originalPlaceholder },
            "the placeholder is back, under a new display ID"
        )
    }
    print("PASS: a sharp screen that comes online with no display mode is released, with one log line saying why")

    do {
        let host = FakeHeadlessHost()
        host.sharpScreenNeverComesOnline = true
        let log = DiagnosticsRecorder()
        let manager = makeSharpScreenManager(host: host, log: log)
        let outcome = await manager.lease(forAdmittedDisplayID: host.placeholderID) { _ in }
        guard case .failed = outcome else {
            expect(false, "a sharp screen that never comes online is not used, got \(outcome)")
            return
        }
        expect(host.destroyedHandles.count == 1, "it is released again")
        expect(
            log.messages.filter { $0.contains("sharp screen not used") && $0.contains("online") }.count == 1,
            "with one line saying it never came online, got \(log.messages)"
        )

        let unresolvableHost = FakeHeadlessHost()
        let unresolvableLog = DiagnosticsRecorder()
        let unresolvable = makeSharpScreenManager(
            host: unresolvableHost, log: unresolvableLog, captureResolvable: { _ in false }
        )
        let notCapturable = await unresolvable.lease(forAdmittedDisplayID: unresolvableHost.placeholderID) { _ in }
        guard case .failed = notCapturable else {
            expect(false, "a sharp screen ScreenCaptureKit cannot find is not used, got \(notCapturable)")
            return
        }
        expect(unresolvableHost.destroyedHandles.count == 1, "it is released again")
        expect(
            unresolvableLog.messages.filter { $0.contains("sharp screen not used") && $0.contains("ScreenCaptureKit") }.count == 1,
            "with one line naming ScreenCaptureKit, got \(unresolvableLog.messages)"
        )

        let refusingHost = FakeHeadlessHost()
        refusingHost.refusesCreation = true
        let refusingLog = DiagnosticsRecorder()
        let refusing = makeSharpScreenManager(host: refusingHost, log: refusingLog)
        let refused = await refusing.lease(forAdmittedDisplayID: refusingHost.placeholderID) { _ in }
        guard case .failed = refused else {
            expect(false, "a sharp screen macOS refuses to create is not used, got \(refused)")
            return
        }
        expect(refusingHost.destroyedHandles.isEmpty, "and there is nothing to release")
        expect(
            refusingLog.messages.filter { $0.contains("sharp screen not used") }.count == 1,
            "with one line saying why, got \(refusingLog.messages)"
        )
    }
    print("PASS: a sharp screen that never comes online, that ScreenCaptureKit cannot find, or that macOS refuses is not used")

    do {
        let host = FakeHeadlessHost()
        let log = DiagnosticsRecorder()
        let manager = makeSharpScreenManager(host: host, log: log)
        guard case let .leased(first) = await manager.lease(forAdmittedDisplayID: host.placeholderID, onLost: { _ in }) else {
            expect(false, "the first session leases a sharp screen")
            return
        }
        // The placeholder is gone now, so a second session is admitted on the
        // sharp screen itself.
        guard case let .leased(second) = await manager.lease(forAdmittedDisplayID: first.displayID, onLost: { _ in }) else {
            expect(false, "a second session on the sharp screen shares it")
            return
        }
        expect(second.displayID == first.displayID, "both sessions hold the same sharp screen")
        expect(host.attemptedIdentities.count == 1, "only one is ever created, got \(host.attemptedIdentities.count)")

        first.release()
        _ = await waitUntil(timeoutSeconds: 0.2) { !host.destroyedHandles.isEmpty }
        expect(host.destroyedHandles.isEmpty, "it stays while one session still uses it")

        second.release()
        expect(host.destroyedHandles.isEmpty, "the last session ending does not release it at once")
        expect(manager.displayID == first.displayID, "it is still this host's sharp screen during the grace period")
        _ = await waitUntil(timeoutSeconds: 2) { !host.destroyedHandles.isEmpty }
        expect(
            host.destroyedHandles == [VirtualDisplayHandle(rawValue: first.displayID)],
            "it is released once the grace period passes, got \(host.destroyedHandles)"
        )
        expect(manager.displayID == nil, "and the manager holds none afterwards")
        expect(
            log.messages.contains { $0.contains("sharp screen \(first.displayID) released") },
            "the host log says it was released, got \(log.messages)"
        )
    }
    print("PASS: sessions share one sharp screen, and it is released only after the last one has been gone for the grace period")

    do {
        let host = FakeHeadlessHost()
        let manager = makeSharpScreenManager(host: host)
        guard case let .leased(first) = await manager.lease(forAdmittedDisplayID: host.placeholderID, onLost: { _ in }) else {
            expect(false, "a session leases a sharp screen")
            return
        }
        first.release()
        first.release()
        guard case let .leased(again) = await manager.lease(forAdmittedDisplayID: first.displayID, onLost: { _ in }) else {
            expect(false, "a reconnect within the grace period leases the same sharp screen")
            return
        }
        expect(again.displayID == first.displayID, "a reconnect within the grace period gets the same display back")
        expect(host.attemptedIdentities.count == 1, "nothing new is created for it")
        _ = await waitUntil(timeoutSeconds: 0.2) { !host.destroyedHandles.isEmpty }
        expect(host.destroyedHandles.isEmpty, "the earlier grace period does not release the display the reconnect now holds")
        again.release()
        _ = await waitUntil(timeoutSeconds: 2) { !host.destroyedHandles.isEmpty }
        expect(host.destroyedHandles.count == 1, "it is released once, after the reconnect ends too")
    }
    print("PASS: a session reconnecting within the grace period reuses the same sharp screen")

    do {
        let host = FakeHeadlessHost()
        let manager = makeSharpScreenManager(
            host: host,
            captureResolvable: { _ in
                await Task.yield()
                return true
            }
        )
        let placeholder = host.placeholderID
        async let first = manager.lease(forAdmittedDisplayID: placeholder, onLost: { _ in })
        async let second = manager.lease(forAdmittedDisplayID: placeholder, onLost: { _ in })
        let outcomes = await [first, second]
        let ids = outcomes.compactMap { outcome -> UInt32? in
            if case let .leased(lease) = outcome { return lease.displayID }
            return nil
        }
        expect(ids.count == 2, "two sessions starting together both get the sharp screen, got \(outcomes)")
        expect(Set(ids).count == 1, "the same one")
        expect(host.attemptedIdentities.count == 1, "created once, got \(host.attemptedIdentities.count)")
    }
    print("PASS: two sessions starting at the same moment share one sharp screen")

    do {
        let host = FakeHeadlessHost()
        let shutdown = CanvasShutdown()
        let manager = makeSharpScreenManager(host: host, shutdown: shutdown)
        guard case let .leased(lease) = await manager.lease(forAdmittedDisplayID: host.placeholderID, onLost: { _ in }) else {
            expect(false, "a session leases a sharp screen")
            return
        }
        shutdown.releaseEverything()
        expect(
            host.destroyedHandles == [VirtualDisplayHandle(rawValue: lease.displayID)],
            "quitting releases the sharp screen with every canvas, got \(host.destroyedHandles)"
        )
        expect(manager.displayID == nil, "and the manager holds none afterwards")
        lease.release()
        _ = await waitUntil(timeoutSeconds: 0.2) { host.destroyedHandles.count > 1 }
        expect(host.destroyedHandles.count == 1, "a session ending afterwards releases nothing a second time")
    }
    print("PASS: quitting the host releases the sharp screen, once")

    do {
        let host = FakeHeadlessHost()
        let log = DiagnosticsRecorder()
        let manager = makeSharpScreenManager(host: host, log: log, releaseGraceSeconds: 60)
        let firstLoss = SharpScreenLossRecorder()
        let secondLoss = SharpScreenLossRecorder()
        guard case let .leased(first) = await manager.lease(forAdmittedDisplayID: host.placeholderID, onLost: { firstLoss.record($0) }),
              case let .leased(second) = await manager.lease(forAdmittedDisplayID: host.sharpID ?? 0, onLost: { secondLoss.record($0) }) else {
            expect(false, "two sessions lease the sharp screen")
            return
        }

        // The sharp screen's own arrival is a display change too.
        manager.displaysChanged()
        expect(firstLoss.reasons.isEmpty && secondLoss.reasons.isEmpty, "a display change that brings no monitor ends nothing")
        expect(host.destroyedHandles.isEmpty, "and releases nothing")

        host.monitorConnected = true
        manager.displaysChanged()
        expect(
            firstLoss.reasons == [SharpScreenManager.monitorConnectedReason]
                && secondLoss.reasons == [SharpScreenManager.monitorConnectedReason],
            "every session on the sharp screen is ended once with the monitor reason, got \(firstLoss.reasons) and \(secondLoss.reasons)"
        )
        expect(SharpScreenManager.monitorConnectedReason == "A monitor was connected to the host.", "in plain words")
        expect(
            host.destroyedHandles == [VirtualDisplayHandle(rawValue: first.displayID)],
            "the sharp screen is released at once, with no grace period, got \(host.destroyedHandles)"
        )
        expect(manager.displayID == nil, "and the manager holds none")
        expect(
            log.messages.contains { $0.contains("monitor") && $0.contains("sharp screen \(first.displayID)") },
            "the host log says a monitor was connected, got \(log.messages)"
        )
        first.release()
        second.release()
        manager.displaysChanged()
        expect(host.destroyedHandles.count == 1, "nothing is released a second time")
        expect(firstLoss.reasons.count == 1 && secondLoss.reasons.count == 1, "and no session is told twice")
    }
    print("PASS: a monitor connected while the sharp screen is up ends every session on it and releases it at once")

    do {
        let host = FakeHeadlessHost()
        let manager = makeSharpScreenManager(host: host, releaseGraceSeconds: 60)
        guard case let .leased(lease) = await manager.lease(forAdmittedDisplayID: host.placeholderID, onLost: { _ in }) else {
            expect(false, "a session leases the sharp screen")
            return
        }
        lease.release()
        host.monitorConnected = true
        manager.displaysChanged()
        expect(host.destroyedHandles.count == 1, "a sharp screen in its grace period is released at once when a monitor is connected")
    }
    print("PASS: a monitor connected during the grace period releases the sharp screen at once")

    do {
        let host = FakeHeadlessHost()
        let log = DiagnosticsRecorder()
        let manager = makeSharpScreenManager(host: host, log: log)
        let loss = SharpScreenLossRecorder()
        guard case let .leased(lease) = await manager.lease(forAdmittedDisplayID: host.placeholderID, onLost: { loss.record($0) }) else {
            expect(false, "a session leases the sharp screen")
            return
        }
        host.sharpScreenVanished = true
        manager.displaysChanged()
        expect(
            loss.reasons == [SharpScreenManager.vanishedReason],
            "a sharp screen that goes away on its own ends the session on it with a plain reason, got \(loss.reasons)"
        )
        expect(manager.displayID == nil, "the manager no longer counts it as up")
        expect(
            host.destroyedHandles == [VirtualDisplayHandle(rawValue: lease.displayID)],
            "and gives back what it still held of it"
        )
        expect(
            log.messages.contains { $0.contains("sharp screen \(lease.displayID)") && $0.contains("went away") },
            "the host log says it went away, got \(log.messages)"
        )
    }
    print("PASS: a sharp screen that goes away on its own ends every session on it with a plain reason")
}
