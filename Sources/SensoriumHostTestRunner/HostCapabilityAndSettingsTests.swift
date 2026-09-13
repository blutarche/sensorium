import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

@MainActor
func runHostCapabilityAndSettingsTests() async {
    do {
        // The only two things the probe can ever report: a real handle,
        // acquired and released so nothing is left behind, or the specific
        // reason it could not be, worded for the host window rather than
        // an `Error` description a reader would not recognize.
        let workingAdapter = FakeVirtualDisplayAdapter()
        let supported = HostVirtualDisplayCapability.probe(makeAdapter: { _ in workingAdapter })
        expect(supported == .supported, "a working adapter reports the host as capable")
        expect(
            workingAdapter.acquiredConfigurations == [.remoteDefault]
                && workingAdapter.releasedHandles.count == 1,
            "the probe acquires and releases exactly one display, never keeping it"
        )

        let failingAdapter = FakeVirtualDisplayAdapter()
        failingAdapter.acquireError = CoreGraphicsVirtualDisplayError.creationFailed
        let unsupported = HostVirtualDisplayCapability.probe(makeAdapter: { _ in failingAdapter })
        guard case let .unsupported(reason) = unsupported else {
            expect(false, "a failing adapter reports the host as incapable")
            return
        }
        expect(
            !reason.isEmpty && !reason.contains("creationFailed"),
            "the reason is written for the host window, not the underlying error's own case name"
        )
        expect(
            failingAdapter.releasedHandles.isEmpty,
            "nothing is released when acquisition itself never produced a handle"
        )
    }

    print("PASS: the virtual-display capability probe reports supported or unsupported honestly, and never leaks the display it tests with")

    do {
        // A host killed mid-session leaves its canvas behind with no owner,
        // and that leftover keeps the surface's stable identity taken. The
        // next launch must start a session on the next identity instead of
        // refusing this Mac outright, and must say so once, in words that
        // name what happened.
        let surfaceZero = CanvasSurfaceID.allCases[0]
        let stable = CanvasIdentityFallback.identities(for: surfaceZero)[0]
        let firstAlternative = CanvasIdentityFallback.identities(for: surfaceZero)[1]
        expect(
            CanvasIdentityFallback.identities(for: surfaceZero).count == 13
                && stable.serialNumber == 1
                && firstAlternative.serialNumber == 17
                && CanvasIdentityFallback.identities(for: surfaceZero)[12].serialNumber == 193,
            "the sequence is the stable identity followed by twelve alternatives, a stride apart"
        )
        expect(
            Set(CanvasIdentityFallback.identities(for: surfaceZero).map(\.serialNumber))
                .isDisjoint(
                    with: Set(CanvasIdentityFallback.identities(for: CanvasSurfaceID.allCases[1]).map(\.serialNumber))
                ),
            "no alternative of one surface is ever an identity of the other"
        )

        // An identity exists for every `attempt` a caller can name, including
        // the ones no fallback sequence produces: a serial is arithmetic on a
        // fixed-width integer, and an attempt outside the range that fits has
        // to come back as the nearest one that does rather than stop the host.
        let belowRange = CanvasDisplayIdentity(surface: surfaceZero, attempt: -3)
        expect(
            belowRange.attempt == 0 && belowRange.serialNumber == stable.serialNumber,
            "an attempt below the first one is the stable identity, not a trap"
        )
        let aboveRange = CanvasDisplayIdentity(surface: surfaceZero, attempt: Int.max)
        expect(
            aboveRange.attempt == CanvasDisplayIdentity.maximumAttempt
                && aboveRange.serialNumber
                    == UInt32(surfaceZero.index) + 1
                        + UInt32(CanvasDisplayIdentity.maximumAttempt) * CanvasDisplayIdentity.attemptStride,
            "an attempt past the last serial that fits is the last one, not an overflow"
        )
        expect(
            CanvasDisplayIdentity(surface: CanvasSurfaceID.allCases[1], attempt: CanvasDisplayIdentity.maximumAttempt)
                .serialNumber > UInt32.max - CanvasDisplayIdentity.attemptStride,
            "the last attempt of the last surface still fits in the serial it is written into"
        )

        let leftover = FakeVirtualDisplayCreator()
        leftover.refusedSerials = [stable.serialNumber]
        var leftoverLog: [String] = []
        let recovering = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            creator: leftover,
            log: { leftoverLog.append($0) }
        )
        let recovered = try? recovering.acquire(configuration: .remoteDefault)
        expect(recovered != nil, "a taken stable identity does not stop the canvas being created")
        expect(
            leftover.attemptedIdentities.map(\.serialNumber) == [1, 17],
            "the refused identity is tried first, then the next one in the sequence"
        )
        expect(
            recovering.identityInUse == firstAlternative,
            "the adapter reports the identity the canvas actually presents, not the one it asked for"
        )
        expect(
            leftoverLog == [
                "session canvas identity 1 is already taken, most likely by a canvas an earlier "
                    + "host left behind; using identity 17 instead"
            ],
            "the fallback is reported once, in a sentence that names both identities and the likely cause"
        )
        // The first canvas is still live and still holding identity 17, so the
        // second one lands further along again -- and says so. A session
        // running on an identity that is not its own is a fact about that
        // session, and a log that mentioned only the first would leave every
        // later one unaccounted for.
        _ = try? recovering.acquire(configuration: .remoteDefault)
        expect(
            leftoverLog.count == 2 && leftoverLog[1].contains("using identity 33 instead"),
            "a second canvas that needs a fallback of its own is reported too, naming the identity it took"
        )

        let clean = FakeVirtualDisplayCreator()
        var cleanLog: [String] = []
        let ordinary = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            creator: clean,
            log: { cleanLog.append($0) }
        )
        _ = try? ordinary.acquire(configuration: .remoteDefault)
        expect(
            clean.attemptedIdentities.map(\.serialNumber) == [1] && cleanLog.isEmpty,
            "nothing is said and nothing else is tried when the stable identity is free"
        )

        let refusingEverything = FakeVirtualDisplayCreator()
        refusingEverything.refusedSerials = Set(
            CanvasIdentityFallback.identities(for: surfaceZero).map(\.serialNumber)
        )
        let exhausted = HostVirtualDisplayCapability.probe(makeAdapter: { log in
            CoreGraphicsVirtualDisplayAdapter(surface: surfaceZero, creator: refusingEverything, log: log)
        })
        guard case let .unsupported(exhaustedReason) = exhausted else {
            expect(false, "a machine that refuses every identity cannot host")
            return
        }
        expect(
            refusingEverything.attemptedIdentities.count == 13,
            "the probe succeeds if any identity in the sequence works, so it tries all of them"
        )
        expect(
            exhaustedReason.contains("every identity") && exhaustedReason.contains("left behind"),
            "the reason names the step that failed: creation refused for every identity, most likely a leftover canvas"
        )
        expect(
            !exhaustedReason.contains("Mac"),
            "the reason speaks of this machine, the word the rest of the host app's copy uses"
        )

        let noRuntime = FakeVirtualDisplayCreator()
        noRuntime.refusedSerials = Set(
            CanvasIdentityFallback.identities(for: surfaceZero).map(\.serialNumber)
        )
        noRuntime.refusal = .runtimeUnavailable
        let unsupportedHardware = HostVirtualDisplayCapability.probe(makeAdapter: { log in
            CoreGraphicsVirtualDisplayAdapter(surface: surfaceZero, creator: noRuntime, log: log)
        })
        guard case let .unsupported(hardwareReason) = unsupportedHardware else {
            expect(false, "a machine without the runtime classes cannot host")
            return
        }
        expect(
            noRuntime.attemptedIdentities.count == 1,
            "a missing runtime class is not something another identity can get past, so nothing else is tried"
        )
        expect(
            hardwareReason.contains("Apple silicon") && !hardwareReason.contains("every identity"),
            "the reason tells the operator this is the machine itself, not a display an earlier host left behind"
        )
        expect(
            hardwareReason.contains("cannot host from this machine") && !hardwareReason.contains("Mac"),
            "the reason says what this machine cannot do, in the words the rest of the host app's copy uses"
        )
    }

    print("PASS: a session canvas identity left taken by an earlier host is stepped past, once, and reported")

    do {
        // The capability probe creates a canvas of its own at launch, moments
        // before the first session creates one. They must never draw from the
        // same identities: a probe holding a session's identity, even only
        // until it releases it, pushes that session onto a fallback it never
        // needed.
        let surfaceZero = CanvasSurfaceID.allCases[0]
        let probeIdentities = CanvasIdentityFallback.identities(for: surfaceZero, purpose: .capabilityProbe)
        let sessionSerials = Set(
            CanvasSurfaceID.allCases.flatMap {
                CanvasIdentityFallback.identities(for: $0).map(\.serialNumber)
            }
        )
        expect(
            Set(probeIdentities.map(\.serialNumber)).isDisjoint(with: sessionSerials),
            "no identity the probe can take is one either session canvas asks for"
        )
        expect(
            HostVirtualDisplayCapability.defaultProbeAdapter(log: { _ in }).identityInUse == probeIdentities[0],
            "the probe the host really runs draws from the probe's own identities"
        )

        expect(
            CanvasPurpose.session.displayName == "Sensorium Virtual Display"
                && CanvasPurpose.capabilityProbe.displayName != CanvasPurpose.session.displayName,
            "a session canvas is called what it is where the host lists displays, and the probe's throwaway canvas is not called the same"
        )

        // The probe's canvas is not a session canvas, and the one line the
        // host log may carry about it must not call it one.
        let busyProbe = FakeVirtualDisplayCreator()
        busyProbe.refusedSerials = [probeIdentities[0].serialNumber]
        var probeLog: [String] = []
        let reportingProbe = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            purpose: .capabilityProbe,
            creator: busyProbe,
            log: { probeLog.append($0) }
        )
        _ = try? reportingProbe.acquire(configuration: .remoteDefault)
        expect(
            probeLog.count == 1
                && !probeLog[0].contains("session canvas")
                && probeLog[0].contains("\(probeIdentities[0].serialNumber)")
                && probeLog[0].contains("\(probeIdentities[1].serialNumber)"),
            "the probe's own fallback line names the identities it tried and does not call its canvas a session canvas"
        )

        // macOS refuses an identity a live display is already presenting, so
        // the creator standing in for it has to refuse one too: a test that
        // lets the same identity be created twice over is not testing a
        // sequence this host could ever meet.
        let holding = FakeVirtualDisplayCreator()
        let held = try? holding.create(configuration: .remoteDefault, identity: probeIdentities[0])
        expect(held != nil, "a free identity is created")
        var refusedWhileHeld = false
        do {
            _ = try holding.create(configuration: .remoteDefault, identity: probeIdentities[0])
        } catch {
            refusedWhileHeld = true
        }
        expect(refusedWhileHeld, "an identity a live display still presents is not created a second time")
        if let held {
            holding.destroy(held)
        }
        expect(
            (try? holding.create(configuration: .remoteDefault, identity: probeIdentities[0])) != nil,
            "destroying the display frees its identity for whatever asks next"
        )

        // Launch, in the order it really happens: a canvas an earlier host
        // left behind holds surface 0's stable identity, the probe creates and
        // releases a canvas of its own, and then the first session starts. The
        // session lands on the first alternative -- exactly where it would
        // have landed had the probe never run.
        let launch = FakeVirtualDisplayCreator()
        let sessionIdentities = CanvasIdentityFallback.identities(for: surfaceZero)
        launch.refusedSerials = [sessionIdentities[0].serialNumber]
        let probeAdapter = CoreGraphicsVirtualDisplayAdapter(
            surface: surfaceZero,
            purpose: .capabilityProbe,
            creator: launch
        )
        let probeHandle = try? probeAdapter.acquire(configuration: .remoteDefault)
        expect(probeHandle != nil, "the probe creates its own canvas")
        if let probeHandle {
            probeAdapter.release(probeHandle)
        }
        let sessionAdapter = CoreGraphicsVirtualDisplayAdapter(surface: surfaceZero, creator: launch)
        _ = try? sessionAdapter.acquire(configuration: .remoteDefault)
        expect(
            sessionAdapter.identityInUse == sessionIdentities[1],
            "the session takes the first identity the leftover canvas does not hold, whatever the probe did before it"
        )
    }

    print("PASS: the capability probe draws from identities no session canvas asks for")

    do {
        // The host-configured cap is enforced the same way the wire
        // protocol's own two-canvas cap already is: `invalidCanvasRequest`,
        // no reply, the session otherwise unaffected -- see the identical
        // out-of-range-surfaceID test this mirrors.
        let cappedAdapter = FakeVirtualDisplayAdapter()
        let cappedSession = VirtualDisplaySession(adapter: cappedAdapter)
        let cappedController = HostSessionController(
            sessions: surfaceZeroOnly(cappedSession),
            keyConfinement: .unconfined,
            maxSurfaceCount: 1
        )
        expectThrows(
            HostSessionControllerError.invalidCanvasRequest,
            { _ = try cappedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1)) },
            "a canvasRequest for surface 1 is refused when the operator has capped this host at one canvas"
        )
        expect(!cappedSession.isActive, "the refused surface's canvas is never claimed")
        let cappedReady = try! cappedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0))
        expect(cappedReady != nil, "surface 0 is unaffected by a cap of one -- it is still within it")

        let uncappedController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let uncappedReady = try! uncappedController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1))
        expect(uncappedReady != nil, "the default cap (every canvas the wire protocol allows) leaves surface 1 reachable, unchanged from before this setting existed")

        print("PASS: HostSessionController's own canvas cap refuses a surface beyond the operator's chosen count, and leaves every surface within it unaffected")
    }
}
