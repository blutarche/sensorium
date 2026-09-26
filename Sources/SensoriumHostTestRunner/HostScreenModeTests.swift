import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// The host screen's display mode, as far as `HostSessionController` owns
/// it: which modes a live session is offered, what a pick does, what every
/// refusal is, and the one thing the whole feature rests on -- the display
/// goes back to the mode it was on when the session ends, however it ends.
///
/// `HostScreenModeControlling` is a fake throughout. The real controller
/// reconfigures a physical display, which no test in this repository may
/// do; what can be verified without one -- how a mode is named and ordered
/// -- is `HostScreenModePresentation`, exercised at the bottom of this file.
@MainActor
private func hostScreenModeTestDisplay(id: UInt32 = 7) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 3840,
        pixelHeight: 2160,
        modeWidth: 3840,
        modeHeight: 2160,
        modePixelWidth: 3840,
        modePixelHeight: 2160,
        bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

private final class LongIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

private let nativeMode = HostScreenModeEntry(
    modeID: "3840x2160@3840x2160@60",
    width: 3840,
    height: 2160,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: false
)

private let readableMode = HostScreenModeEntry(
    modeID: "3840x2160@1920x1080@60",
    width: 1920,
    height: 1080,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: true
)

@MainActor
private func makeModeFixture(
    restorePolicy: HostScreenModeRestorePolicy = .standard
) -> (
    controller: HostSessionController,
    modes: FakeHostScreenModeController,
    display: DisplaySnapshot,
    log: DiagnosticsRecorder
) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let display = hostScreenModeTestDisplay()
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel Laptop Pro",
            armedAt: Date()
        )
    ])
    let modes = FakeHostScreenModeController()
    modes.modesByDisplay[display.id] = [nativeMode, readableMode]
    modes.currentModeIDByDisplay[display.id] = nativeMode.modeID
    let log = DiagnosticsRecorder()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceActivitySignal: LongIdleSignal(),
        hostScreenModeController: modes,
        hostScreenModeRestorePolicy: restorePolicy,
        log: { log.record($0) }
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    return (controller, modes, display, log)
}

/// Takes the fixture's controller all the way to a live host-screen
/// session, which is the state every mode operation requires.
@MainActor
private func admitHostScreenSession(_ controller: HostSessionController) {
    guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(),
          let entry = displays.first else {
        expect(false, "the mode fixture's own offer names the armed display")
        return
    }
    let response = try! controller.handle(.hostScreenRequest(
        token: entry.opaqueToken,
        resumeTicket: nil
    ))
    guard case .hostScreenReady = response else {
        expect(false, "the mode fixture's own request is admitted -- got: \(String(describing: response))")
        return
    }
}

@MainActor
func runHostScreenModeTests() async {
    do {
        // A live session is offered the display's own modes
        let fixture = makeModeFixture()
        admitHostScreenSession(fixture.controller)
        guard case let .hostScreenModeList(modes, currentModeID) = fixture.controller.hostScreenModeListMessage() else {
            expect(false, "a live host-screen session has a mode list to send")
            return
        }
        expect(
            modes == [nativeMode, readableMode],
            "the list is exactly what the mode controller reports for this session's own display, unfiltered and unreordered by the session controller"
        )
        expect(
            currentModeID == nativeMode.modeID,
            "and it names the mode the display is on right now, read from the display rather than remembered"
        )
        expect(
            fixture.modes.listedDisplayIDs.allSatisfy { $0 == fixture.display.id },
            "every mode operation names this session's own display and no other"
        )
        print("PASS: a live host-screen session is offered its own display's modes and the one it is currently on")
    }

    do {
        // A pick is applied, and answered with the new geometry
        let fixture = makeModeFixture()
        admitHostScreenSession(fixture.controller)
        let response = try! fixture.controller.handle(.hostScreenModeRequest(modeID: readableMode.modeID))
        guard case let .hostScreenModeApplied(geometry, currentModeID) = response else {
            expect(false, "a pick of an offered mode is applied -- got: \(String(describing: response))")
            return
        }
        expect(
            geometry == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2.0),
            "the answer carries the display's own new geometry: the points it now lays out in, and the real pixels behind them as its backing scale"
        )
        expect(currentModeID == readableMode.modeID, "and names the mode it is now on")
        expect(
            fixture.modes.applied.count == 1
                && fixture.modes.applied[0].modeID == readableMode.modeID
                && fixture.modes.applied[0].displayID == fixture.display.id,
            "exactly one mode was set, on this session's own display"
        )
        expect(
            fixture.log.messages.contains { $0.contains("host screen mode changed to 1920x1080 (3840x2160) for Kestrel Laptop Pro") },
            "and the person reading the host log is told what changed and for whom -- got: \(fixture.log.messages)"
        )
        // The list is re-read from the display afterwards, never from what
        // the request asked for.
        guard case let .hostScreenModeList(_, listedCurrent) = fixture.controller.hostScreenModeListMessage() else {
            expect(false, "a live session still has a mode list after a change")
            return
        }
        expect(listedCurrent == readableMode.modeID, "the next list names the mode now current")
        print("PASS: a viewer's pick of an offered mode is applied to this session's display and answered with the new geometry")
    }

    do {
        // No live host-screen session: nothing is touched
        let fixture = makeModeFixture()
        let response = try! fixture.controller.handle(.hostScreenModeRequest(modeID: readableMode.modeID))
        expect(
            response == .hostScreenModeRefused(reason: HostScreenModeRefusalReason.notLive),
            "a mode request with no host-screen session live is refused as not live -- got: \(String(describing: response))"
        )
        expect(
            fixture.modes.applied.isEmpty && fixture.modes.restoredDisplayIDs.isEmpty,
            "and reaches no display at all: a connection with no admitted host screen can never configure one"
        )
        expect(
            fixture.controller.hostScreenModeListMessage() == nil,
            "nor is there any mode list to offer a session that is not streaming a host screen"
        )
        print("PASS: a mode request outside a live host-screen session is refused and touches no display")
    }

    do {
        // A mode this session was never offered
        let fixture = makeModeFixture()
        admitHostScreenSession(fixture.controller)
        let response = try! fixture.controller.handle(.hostScreenModeRequest(modeID: "1280x720@1280x720@60"))
        expect(
            response == .hostScreenModeRefused(reason: HostScreenModeRefusalReason.unknown),
            "a mode identifier this display never offered is refused as unknown -- got: \(String(describing: response))"
        )
        expect(
            fixture.modes.applied.isEmpty,
            "and nothing is set: a viewer cannot describe a mode into existence, only name one already offered"
        )
        print("PASS: a mode identifier the host never offered is refused, and no display is reconfigured")
    }

    do {
        // The display refuses the mode
        let fixture = makeModeFixture()
        admitHostScreenSession(fixture.controller)
        fixture.modes.applyResult = false
        let response = try! fixture.controller.handle(.hostScreenModeRequest(modeID: readableMode.modeID))
        expect(
            response == .hostScreenModeRefused(reason: HostScreenModeRefusalReason.failed),
            "a mode the display would not take is refused as failed -- got: \(String(describing: response))"
        )
        _ = try! fixture.controller.handle(.goodbye(reason: "client-quit"))
        expect(
            fixture.modes.restoredDisplayIDs.isEmpty,
            "and the session's end restores nothing: this session never changed the mode, so there is nothing of its own to put back"
        )
        print("PASS: a mode the display refuses is reported as failed, and leaves nothing for the session's end to undo")
    }

    do {
        // The session ends: the display goes back
        let fixture = makeModeFixture()
        admitHostScreenSession(fixture.controller)
        _ = try! fixture.controller.handle(.hostScreenModeRequest(modeID: readableMode.modeID))
        _ = try! fixture.controller.handle(.goodbye(reason: "transport-lost"))
        expect(
            fixture.modes.restoredDisplayIDs == [fixture.display.id],
            "the session ending puts this session's own display back, exactly once -- got: \(fixture.modes.restoredDisplayIDs)"
        )
        expect(
            fixture.modes.currentModeIDByDisplay[fixture.display.id] == nativeMode.modeID,
            "and back on the mode it was on before this session ever touched it"
        )
        expect(
            fixture.log.messages.contains { $0.contains("host screen mode restored to 3840x2160") },
            "and says so in the host log -- got: \(fixture.log.messages)"
        )
        print("PASS: a host-screen session that changed its display's mode puts that mode back when it ends")
    }

    do {
        // Two changes, one restore, to the mode before the first
        let fixture = makeModeFixture()
        admitHostScreenSession(fixture.controller)
        _ = try! fixture.controller.handle(.hostScreenModeRequest(modeID: readableMode.modeID))
        _ = try! fixture.controller.handle(.hostScreenModeRequest(modeID: nativeMode.modeID))
        _ = try! fixture.controller.handle(.hostScreenModeRequest(modeID: readableMode.modeID))
        _ = try! fixture.controller.handle(.goodbye(reason: "client-quit"))
        expect(
            fixture.modes.currentModeIDByDisplay[fixture.display.id] == nativeMode.modeID,
            "however many times a session changes the mode, what it restores is the one the display had before the first change"
        )
        print("PASS: several mode changes in one session still restore the mode the display started on")
    }

    do {
        // A session that never changed anything restores nothing
        let fixture = makeModeFixture()
        admitHostScreenSession(fixture.controller)
        _ = try! fixture.controller.handle(.goodbye(reason: "client-quit"))
        expect(
            fixture.modes.restoredDisplayIDs.isEmpty,
            "a session that never changed a mode has nothing to restore, and must not reconfigure a display on its way out"
        )
        print("PASS: a host-screen session that changed no mode reconfigures nothing when it ends")
    }

    do {
        // A refused restore keeps what the display must go back to
        let modes = FakeHostScreenModeController()
        let displayID: UInt32 = 9
        modes.modesByDisplay[displayID] = [nativeMode, readableMode]
        modes.currentModeIDByDisplay[displayID] = nativeMode.modeID
        expect(modes.apply(modeID: readableMode.modeID, to: displayID), "the fixture's own display takes the mode it is handed")
        modes.restoreFailuresRemaining = 2
        expect(
            modes.restore(displayID: displayID) == false,
            "a display that will not take the mode back right now says so"
        )
        expect(
            modes.displaysAwaitingRestore == [displayID],
            "and what it must go back to is still remembered, because a restore that did not happen is not a restore that is no longer owed -- got: \(modes.displaysAwaitingRestore)"
        )
        await modes.restoreEverythingRetrying(
            policy: HostScreenModeRestorePolicy(attempts: 5, delaySeconds: 0.01)
        )
        expect(
            modes.currentModeIDByDisplay[displayID] == nativeMode.modeID,
            "a display that refused the first attempts is put back by a later one -- got: \(String(describing: modes.currentModeIDByDisplay[displayID]))"
        )
        expect(
            modes.displaysAwaitingRestore.isEmpty,
            "and only a restore that actually took makes the display stop being owed one"
        )
        print("PASS: a restore the display refuses keeps the mode it owes and is made good by a later attempt")
    }

    do {
        // A session-end restore the display refuses is retried
        let fixture = makeModeFixture(
            restorePolicy: HostScreenModeRestorePolicy(attempts: 5, delaySeconds: 0.01)
        )
        admitHostScreenSession(fixture.controller)
        _ = try! fixture.controller.handle(.hostScreenModeRequest(modeID: readableMode.modeID))
        fixture.modes.restoreFailuresRemaining = 2
        _ = try! fixture.controller.handle(.goodbye(reason: "transport-lost"))
        expect(
            fixture.log.messages.contains { $0.contains("host screen mode could not be restored to 3840x2160 yet; will retry") },
            "the person reading the host log is told the display did not go back yet, rather than nothing at all -- got: \(fixture.log.messages)"
        )
        let wentBack = await waitUntil(timeoutSeconds: 2) {
            fixture.modes.currentModeIDByDisplay[fixture.display.id] == nativeMode.modeID
        }
        expect(
            wentBack,
            "and a display that refused the restore at the moment the session ended is put back by a later attempt -- got: \(String(describing: fixture.modes.currentModeIDByDisplay[fixture.display.id]))"
        )
        expect(
            fixture.log.messages.contains { $0.contains("host screen mode restored to 3840x2160") },
            "which says so too, so the log ends with what the display is actually on -- got: \(fixture.log.messages)"
        )
        print("PASS: a display that will not take its mode back when the session ends is put back by a later attempt")
    }

    do {
        // Naming and ordering, the part no display is needed for
        let hiDPI = HostScreenModePresentation.entry(
            width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 59.97
        )
        expect(hiDPI.isHiDPI, "a mode whose pixels outnumber its points is a HiDPI mode")
        expect(
            hiDPI.modeID == HostScreenModePresentation.entry(
                width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 59.97
            ).modeID,
            "the same mode is named the same way every time it is listed, so a viewer's pick from one list still resolves in the next"
        )
        expect(
            hiDPI.modeID != HostScreenModePresentation.entry(
                width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 59.97
            ).modeID,
            "and two modes drawn at the same pixels but laid out differently are named differently"
        )
        let sorted = HostScreenModePresentation.sorted([
            HostScreenModePresentation.entry(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60),
            HostScreenModePresentation.entry(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
            HostScreenModePresentation.entry(width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        ])
        expect(
            sorted.map { $0.width } == [3840, 1920, 1280],
            "the sharpest modes head the list, and a \"looks like\" mode sits with the pixels it is drawn at -- got: \(sorted.map { $0.width })"
        )
        print("PASS: a display mode is named from what it is, and the list is ordered sharpest first")
    }

    do {
        // Collapsing macOS's per-refresh-rate duplicates
        // A 4K 240Hz display, as CGDisplayCopyAllDisplayModes with
        // kCGDisplayShowDuplicateLowResolutionModes actually reports it: one
        // mode per (logical size, refresh rate), so every "looks like" size
        // appears four times. Real pixels: 3008x1692 -> 6016x3384,
        // 2560x1440 -> 5120x2880, 3840x2160 -> 3840x2160 (native, non-HiDPI),
        // 3360x1890 -> 6720x3780 (only one refresh rate offered).
        func mode(_ width: Int, _ height: Int, _ pixelWidth: Int, _ pixelHeight: Int, _ refreshRate: Double) -> HostScreenModeEntry {
            HostScreenModePresentation.entry(
                width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshRate: refreshRate
            )
        }
        let current = mode(2048, 1152, 4096, 2304, 240)
        let raw: [HostScreenModeEntry] = [
            mode(3008, 1692, 6016, 3384, 240),
            mode(3008, 1692, 6016, 3384, 165),
            mode(3008, 1692, 6016, 3384, 120),
            mode(3008, 1692, 6016, 3384, 60),
            mode(2560, 1440, 5120, 2880, 240),
            mode(2560, 1440, 5120, 2880, 165),
            mode(2560, 1440, 5120, 2880, 120),
            mode(2560, 1440, 5120, 2880, 60),
            mode(3840, 2160, 3840, 2160, 120),
            mode(3840, 2160, 3840, 2160, 100),
            mode(3840, 2160, 3840, 2160, 60),
            mode(3840, 2160, 3840, 2160, 30),
            mode(3360, 1890, 6720, 3780, 60),
            current
        ]
        let collapsed = HostScreenModePresentation.collapsed(
            raw, currentModeID: current.modeID, nativePixelWidth: 3840, nativePixelHeight: 2160
        )
        expect(
            collapsed == [
                mode(3360, 1890, 6720, 3780, 60),
                mode(3008, 1692, 6016, 3384, 240),
                mode(2560, 1440, 5120, 2880, 240),
                current,
                mode(3840, 2160, 3840, 2160, 120)
            ],
            "each logical size collapses to one entry -- the refresh rate matching the display's current rate where offered, else the group's highest -- and the list is ordered HiDPI first, then by logical size descending -- got: \(collapsed)"
        )
        expect(
            collapsed.contains(current),
            "the display's own current mode always survives collapsing, whatever the preference rules would otherwise have picked for its size"
        )
        print("PASS: macOS's one-mode-per-refresh-rate duplicates collapse to one entry per logical size, current mode preferred, ordered HiDPI first then by size")
    }

    do {
        // Equal refresh rates: the entry matching native pixels wins
        // Two representations of the same logical size at the same refresh
        // rate -- one drawn at exactly the display's native pixel count, one
        // resampled from a different real pixel size -- collapse to the one
        // that matches the display's own pixels.
        func mode(_ width: Int, _ height: Int, _ pixelWidth: Int, _ pixelHeight: Int, _ refreshRate: Double) -> HostScreenModeEntry {
            HostScreenModePresentation.entry(
                width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshRate: refreshRate
            )
        }
        let nativeMatch = mode(1920, 1080, 3840, 2160, 60)
        let resampled = mode(1920, 1080, 3200, 1800, 60)
        let collapsed = HostScreenModePresentation.collapsed(
            [resampled, nativeMatch], currentModeID: nil, nativePixelWidth: 3840, nativePixelHeight: 2160
        )
        expect(
            collapsed == [nativeMatch],
            "at an equal refresh rate, the entry whose real pixels match the display's own is preferred over one resampled from a different pixel count -- got: \(collapsed)"
        )
        print("PASS: two entries of one logical size at one refresh rate collapse to the one matching the display's native pixel size")
    }
}
