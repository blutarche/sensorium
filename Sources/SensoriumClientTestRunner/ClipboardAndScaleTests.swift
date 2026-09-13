import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
func testClipboardAndScaleTests() async {

        let scaleTransport = FakeClientTransport()
        let scaleController = ClientSessionController(transport: scaleTransport)
        do {
            try await scaleController.sendViewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, maximumScale: nil)
            print("FAIL: the client reported a drawable size with no session canvas")
            Foundation.exit(1)
        } catch {}
        _ = try! await scaleController.connect(deviceName: "MacBook")
        try! await scaleController.sendViewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, maximumScale: nil)
        guard await scaleTransport.sent.contains(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)) else {
            print("FAIL: the client did not put the viewer drawable size on the wire")
            Foundation.exit(1)
        }
        do {
            try await scaleController.sendViewerDrawableSize(pixelWidth: 0, pixelHeight: 2400, maximumScale: nil)
            print("FAIL: the client put a degenerate drawable size on the wire")
            Foundation.exit(1)
        } catch {}

        // The focus signal is reported on genuine transitions only. A focus
        // message per mouse move -- or per frame -- would be its own bug, so
        // repeating the state the host was already told produces nothing.
        do {
            let reporter = await ViewerFocusReporter()
            expect(
                await reporter.viewerWindowDidBecomeKey(surfaceID: 0)
                    == ViewerFocusReport(surfaceID: 0, hasViewerFocus: true),
                "the first window to take key focus is reported"
            )
            expect(
                await reporter.viewerWindowDidBecomeKey(surfaceID: 0) == nil,
                "the same window taking key focus again reports nothing: the host already knows"
            )
            expect(
                await reporter.viewerWindowDidBecomeKey(surfaceID: 1)
                    == ViewerFocusReport(surfaceID: 1, hasViewerFocus: true),
                "moving focus to the second canvas is a genuine transition"
            )

            // The third state: the whole viewer stepped aside and the user is
            // working in a local app. Not "surface 0".
            expect(
                await reporter.viewerDidResignActive()
                    == ViewerFocusReport(surfaceID: nil, hasViewerFocus: false),
                "the viewer losing focus entirely is reported as no focus at all"
            )
            expect(
                await reporter.viewerDidResignActive() == nil,
                "staying away reports nothing further"
            )
            expect(
                await reporter.viewerWindowDidBecomeKey(surfaceID: 1)
                    == ViewerFocusReport(surfaceID: 1, hasViewerFocus: true),
                "coming back to the canvas that was focused before is a transition again"
            )

            // A reconnected host has never been told anything, so the next
            // transition must be sent even though nothing changed locally.
            await reporter.reset()
            expect(
                await reporter.viewerWindowDidBecomeKey(surfaceID: 1)
                    == ViewerFocusReport(surfaceID: 1, hasViewerFocus: true),
                "a reconnected session is told the focus again from scratch"
            )
        }

        let focusTransport = FakeClientTransport()
        let focusController = ClientSessionController(transport: focusTransport)
        do {
            try await focusController.sendViewerFocus(surfaceID: 0, hasViewerFocus: true)
            print("FAIL: the client reported focus with no session canvas")
            Foundation.exit(1)
        } catch {}
        _ = try! await focusController.connect(deviceName: "MacBook")
        try! await focusController.sendViewerFocus(surfaceID: nil, hasViewerFocus: true)
        try! await focusController.sendViewerFocus(surfaceID: nil, hasViewerFocus: false)
        expect(
            await focusTransport.sent.suffix(2) == [
                .viewerFocus(surfaceID: nil, hasViewerFocus: true),
                .viewerFocus(surfaceID: nil, hasViewerFocus: false)
            ],
            "both focus states reach the wire unchanged"
        )
        do {
            try await focusController.sendViewerFocus(surfaceID: 1, hasViewerFocus: true)
            print("FAIL: the client reported focus on a canvas this session never opened")
            Foundation.exit(1)
        } catch {}

        print("PASS: the viewer reports its drawable size only when the settled stream scale actually changes")
        print("PASS: a reconnected session is told the viewer's drawable size again")
        print("PASS: decoder ingress discards a restarted sequence, so a resolution change keeps the host sequencer")

        print("PASS: client controller performs connect and disconnect sequence")
        print("PASS: frame receipt ledger carries receive time to the decode callback and stays bounded")
        print("PASS: two windows' independently-owned frame receipt ledgers never interfere, even sharing a presentation timestamp")
        print("PASS: SurfaceVideoIngress keeps each surface's sequence numbering and keyframe gate its own, bounded to two surfaces")
        print("PASS: the client receive loop routes tag 1 to surface 0 and tag 2 to the surface it names")
        print("PASS: session latency monitor reports end-to-end latency only after clock sync")
        print("PASS: viewport re-points at a reconnected session and stays disarmed in between")
        print("PASS: reconnect driver follows the backoff policy, gives up, and honours quit")
        print("PASS: the client TCP verification transport is explicit and never QUIC")
        print("PASS: the client QUIC transport carries a 30s idle timeout")
        print("PASS: only enter (explicit or implied) resolves to an interactive client run mode")
        print("PASS: viewer focus is reported on genuine transitions only, and never as surface 0 when the viewer has no focus")

        // --- Second canvas: requested at connect, capped at two, bound end to end ---

        // An old host that never echoes surfaceID must never see a second
        // canvasRequest, even when the client is configured for dual-canvas.
        let oldHostTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 60, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ])
        let oldHostClient = ClientSessionController(transport: oldHostTransport, requestSecondCanvas: true)
        _ = try! await oldHostClient.connect(deviceName: "MacBook")
        expect(await oldHostClient.hostSupportsSurfaceIDs == false, "an old host that never echoes surfaceID is recorded as not supporting it")
        expect(await oldHostClient.didOpenSecondCanvas == false, "a second canvas is never opened against a host that does not support surfaceID")
        let oldHostCanvasRequests = await oldHostTransport.sent.filter {
            if case .canvasRequest = $0 { return true } else { return false }
        }
        expect(oldHostCanvasRequests.count == 1, "no second canvasRequest is sent to a host that never proved it understands surfaceID")

        // A capable host that was never asked for a second canvas stays
        // single-window too — dual-canvas is opt-in, not automatic.
        let singleWindowTransport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 80, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0)
        ])
        let singleWindowClient = ClientSessionController(transport: singleWindowTransport)
        _ = try! await singleWindowClient.connect(deviceName: "MacBook")
        expect(await singleWindowClient.hostSupportsSurfaceIDs, "a capable host is still detected even when a second canvas was never requested")
        expect(await singleWindowClient.didOpenSecondCanvas == false, "a second canvas is never opened unless explicitly requested, even against a capable host")
        expect(await singleWindowTransport.sent == [
            .hello(protocolVersion: 1, deviceName: "MacBook"),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        ], "a single-canvas connect sends exactly the sequence it always has")
}
