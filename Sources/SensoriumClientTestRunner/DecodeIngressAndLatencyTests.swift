#if canImport(AppKit)
import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
func testDecodeIngressAndLatencyTests() async {

        // The tag-to-surface decision `ClientSessionRunner`'s receive loop
        // actually makes, called here directly: the loop itself owns a live
        // connection and AppKit windows, so this is the seam it routes
        // through rather than a second copy of the same mapping.
        let tagOneFrame = EncodedVideoFramePacket(
            sequence: 3, presentationTimeNanoseconds: 30, isKeyFrame: true, payload: Data([4])
        )
        let tagTwoFrame = EncodedVideoFramePacket(
            sequence: 4, presentationTimeNanoseconds: 40, isKeyFrame: true, payload: Data([5])
        )
        expect(
            ClientSessionRunner.videoRouting(for: .video(tagOneFrame))?.surfaceID == 0,
            "a tag 1 frame, which carries no surfaceID on the wire, is routed to surface 0"
        )
        expect(
            ClientSessionRunner.videoRouting(for: .video(tagOneFrame))?.frame == tagOneFrame,
            "and reaches that surface as the frame it arrived as"
        )
        expect(
            ClientSessionRunner.videoRouting(for: .videoForSurface(surfaceID: 1, frame: tagTwoFrame))
                .map { ($0.surfaceID, $0.frame) == (1, tagTwoFrame) } == true,
            "a tag 2 frame is routed to the surface it names, unchanged"
        )
        expect(
            ClientSessionRunner.videoRouting(for: .videoForSurface(surfaceID: 0, frame: tagTwoFrame))?.surfaceID == 0,
            "and a tag 2 frame naming surface 0 is not diverted by the tag it came in on"
        )
        expect(
            ClientSessionRunner.videoRouting(for: .control(.goodbye(reason: "done"))) == nil
                && ClientSessionRunner.videoRouting(for: .clipboard(.text("copied"))) == nil
                && ClientSessionRunner.videoRouting(for: .unrecognized(tag: 9, payload: Data([1]))) == nil,
            "and no packet that is not video is routed as video"
        )

        // The live "Displays" control's own reply, matched the same way --
        // `secondDisplayOutcome(for:)` is the receive loop's seam for it,
        // the same reason `videoRouting(for:)` is one for video packets.
        expect(
            ClientSessionRunner.secondDisplayOutcome(
                for: .canvasReady(displayID: 7, logicalWidth: 2560, logicalHeight: 1440, hostSignature: nil, surfaceID: 1, hostName: nil)
            ) == .ready(displayID: 7, logicalWidth: 2560, logicalHeight: 1440, hostSignature: nil),
            "a canvasReady naming surface 1 is the live increase's own reply"
        )
        expect(
            ClientSessionRunner.secondDisplayOutcome(for: .canvasRefused(reason: "display-count-exceeds-host-limit", surfaceID: 1))
                == .refused(reason: "display-count-exceeds-host-limit"),
            "a canvasRefused naming surface 1 carries the host's own reason through unchanged"
        )
        expect(
            ClientSessionRunner.secondDisplayOutcome(
                for: .canvasReady(displayID: 7, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0, hostName: nil)
            ) == nil,
            "a canvasReady naming surface 0 -- connect()'s own reply, never expected here -- is not misread as the live control's"
        )
        expect(
            ClientSessionRunner.secondDisplayOutcome(for: .canvasRefused(reason: "invalid-code", surfaceID: nil)) == nil,
            "a canvasRefused naming no surface at all is not misread as the live control's either"
        )
        expect(
            ClientSessionRunner.secondDisplayOutcome(for: .goodbye(reason: "done")) == nil,
            "a control message of a different kind entirely is simply not an outcome"
        )

        // The per-surface cap is two slots; an out-of-range surfaceID is
        // dropped rather than used to grow storage.
        let boundedIngress = SurfaceVideoIngress()
        await boundedIngress.receive(surfaceID: 5, frame: EncodedVideoFramePacket(
            sequence: 0, presentationTimeNanoseconds: 1, isKeyFrame: true, payload: Data([1])
        ))
        expect(
            await boundedIngress.takeNewest(surfaceID: 5) == nil,
            "a surfaceID outside the {0,1} cap is dropped rather than used to grow storage"
        )

        let monitor = SessionLatencyMonitor()
        expect(
            await monitor.summaryLine() == nil,
            "a session with no synchronised frame reports no latency rather than a zero"
        )
        guard case let .timeSyncRequest(sentAt) = await monitor.makeClockRequest(atNanoseconds: 1_000) else {
            print("FAIL: the monitor produces a time-sync request")
            Foundation.exit(1)
        }
        expect(sentAt == 1_000, "the monitor's request carries the timestamp it was made at")
        expect(
            await monitor.receiveClockReply(
                clientTimeNanoseconds: 1_000,
                hostTimeNanoseconds: 5_100,
                receivedAtNanoseconds: 1_200
            ),
            "the monitor accepts the reply to its own request"
        )
        // Host clock 4_000 ahead: host capture 5_000 is client 1_000.
        expect(
            await monitor.recordPresentedFrame(
                timing: FrameTiming(
                    hostCapturedAtNanoseconds: 5_000,
                    receivedAtNanoseconds: 1_300,
                    decodedAtNanoseconds: 1_500
                ),
                presentedAtNanoseconds: 1_900
            ),
            "a frame presented after a synchronised capture is measured"
        )
        guard let summary = await monitor.summaryLine() else {
            print("FAIL: a measured session produces a summary line")
            Foundation.exit(1)
        }
        expect(
            summary.contains("end-to-end p50 0.0ms") && summary.contains("clock offset"),
            "the summary names the end-to-end percentile and the clock offset it depended on: \(summary)"
        )
        expect(
            await monitor.metrics().samples(for: .endToEnd).p50 == 900,
            "the monitor's end-to-end sample is capture-to-present in client time"
        )
        expect(
            !(summary.contains("input round trip")),
            "before any input round trip is recorded, the summary says nothing about one"
        )

        // Once an input round trip is recorded, the summary line appends it
        // rather than replacing anything already there.
        expect(
            await monitor.recordInputRoundTrip(sentAtNanoseconds: 2_000_000, repliedAtNanoseconds: 2_600_000),
            "an input round trip with a later reply than send is recorded"
        )
        guard let summaryWithInput = await monitor.summaryLine() else {
            print("FAIL: a measured session still produces a summary line once an input round trip is recorded")
            Foundation.exit(1)
        }
        expect(
            summaryWithInput.contains("end-to-end p50 0.0ms") && summaryWithInput.contains("clock offset"),
            "recording an input round trip does not disturb the rest of the summary: \(summaryWithInput)"
        )
        expect(
            summaryWithInput.contains("input round trip p50 0.6ms p95 0.6ms"),
            "the summary appends the input round trip's own p50 and p95, got: \(summaryWithInput)"
        )
        expect(
            await monitor.metrics().samples(for: .inputRoundTrip).p50 == 600_000,
            "the monitor's own metrics carry the input round trip sample under its own stage"
        )


        let firstSink = RecordingInputSink()
        let secondSink = RecordingInputSink()
        let reconnectViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: firstSink
        )
        await reconnectViewport.setViewportSize(width: 960, height: 600)
        await reconnectViewport.canvasDidBecomeReady()
        _ = await reconnectViewport.movePointer(x: 480, y: 300)
        expect(await firstSink.events.count == 1, "the first session receives its pointer motion")

        // Transport loss must disarm: input aimed at a canvas that no longer
        // exists cannot be allowed to reach the next session by accident.
        await reconnectViewport.canvasDidEnd()
        expect(
            await reconnectViewport.movePointer(x: 480, y: 300) == .droppedNotConnected,
            "input is dropped between a lost session and its replacement"
        )

        await reconnectViewport.replacePointerSink(secondSink)
        expect(
            await reconnectViewport.movePointer(x: 480, y: 300) == .droppedNotConnected,
            "a replaced sink stays disarmed until the new canvas is ready"
        )
        expect(await secondSink.events.isEmpty, "the replacement sink received nothing while disarmed")

        await reconnectViewport.canvasDidBecomeReady()
        _ = await reconnectViewport.movePointer(x: 1920, y: 1200)
        expect(await secondSink.events.count == 1, "the reconnected session receives pointer motion")
        expect(await firstSink.events.count == 1, "the abandoned session receives nothing after replacement")


        // Backoff must come from the policy, and a session that connected and
        // then died must start over at the shortest delay rather than inheriting
        // the previous failure streak.
        let sleeps = RecordedSleeps()
        let attempts = SessionAttempts(failuresBeforeSuccess: 3)
        let driver = ClientReconnectDriver(
            policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 2, multiplier: 2, maximumAttempts: nil),
            runSession: { try await attempts.attempt() },
            sleep: { await sleeps.record($0) }
        )
        let firstOutcome = await driver.runUntilConnectedSessionEnds()
        expect(await attempts.count == 4, "the driver retried until a session actually connected")
        expect(
            await sleeps.delays == [0.5, 1.0, 2.0],
            "the retry delays came from the policy and were capped: \(await sleeps.delays)"
        )
        expect(firstOutcome == .sessionEnded, "a connected session that ends is reported as such")

        let exhausting = RecordedSleeps()
        let neverConnects = SessionAttempts(failuresBeforeSuccess: 99)
        let givingUp = ClientReconnectDriver(
            policy: ReconnectPolicy(initialDelay: 0.5, maximumDelay: 2, multiplier: 2, maximumAttempts: 2),
            runSession: { try await neverConnects.attempt() },
            sleep: { await exhausting.record($0) }
        )
        expect(
            await givingUp.runUntilConnectedSessionEnds() == .gaveUp,
            "a host that never answers ends the loop instead of retrying forever"
        )
        expect(await neverConnects.count == 3, "the driver stopped after the policy's last permitted attempt")
        expect(await exhausting.delays == [0.5, 1.0], "no delay is waited after the policy is exhausted")

        let quitBeforeDialling = ClientReconnectDriver(
            policy: .remoteDefault,
            runSession: { try await SessionAttempts(failuresBeforeSuccess: 99).attempt() },
            sleep: { _ in }
        )
        await quitBeforeDialling.stop()
        expect(
            await quitBeforeDialling.runUntilConnectedSessionEnds() == .stopped,
            "a driver the user already quit never dials at all"
        )


        // The client's TCP verification transport mirrors the host's: never
        // QUIC, explicit, and it cannot silently pretend to be a pinned QUIC
        // session — the TLS pin is meaningless without TLS.
        expect(
            !(NetworkControlConnection.parameters(
                tlsCertificateHash: nil,
                transport: .tcpLocalVerification
            ).defaultProtocolStack.transportProtocol is NWProtocolQUIC.Options),
            "the TCP verification transport is not QUIC"
        )
        expect(
            NetworkControlConnection.parameters(
                tlsCertificateHash: nil,
                transport: .quic
            ).defaultProtocolStack.transportProtocol is NWProtocolQUIC.Options,
            "the default transport remains QUIC"
        )


        let clientQuicOptions = NetworkControlConnection.parameters(
            tlsCertificateHash: nil,
            transport: .quic
        ).defaultProtocolStack.transportProtocol as? NWProtocolQUIC.Options
        expect(
            clientQuicOptions?.idleTimeout == 30_000,
            "the client QUIC transport fails a silent connection after 30s"
        )

        expect(
            ClientRunModeResolver.resolve(verb: "enter") == .interactive,
            "enter is interactive: the viewer window must receive AppKit input"
        )
        expect(
            ClientRunModeResolver.resolve(verb: nil) == .interactive,
            "omitting the subcommand implies enter, so it stays interactive too"
        )
        expect(
            ClientRunModeResolver.resolve(verb: "pair") == .headless,
            "pair stays headless: it must never start an event loop or bounce a Dock icon"
        )
        expect(
            ClientRunModeResolver.resolve(verb: "bogus") == .headless,
            "an unrecognized subcommand stays headless"
        )

        print("PASS: viewport controller refuses pointer input before a viewport size is known")
        print("PASS: quitting disconnects once and releases held input")
        print("PASS: a host that never answers times out instead of hanging the client")
        print("PASS: saved host profile persists the pinned key and fixed canvas preset")
        print("PASS: client refuses a canvas the pinned host did not sign")
        print("PASS: client pairing pins the approved host key and surfaces rejection reasons")
        print("PASS: AppKit modifier flags translate to exactly the four forwarded modifiers")
        print("PASS: surface router carries button, scroll, and key input onto the owned canvas")
        print("PASS: discrete input is never coalesced away behind pointer motion")
        print("PASS: surface router rejects non-finite pointer locations before they reach the session")
        print("PASS: surface router re-anchors on resize and disarms when the surface loses its bounds")
        print("PASS: surface router flips AppKit view coordinates onto the owned canvas")
        print("PASS: surface router drops pointer events until the view reports its bounds")
        print("PASS: viewport controller refuses pointer input once the session canvas ends")
        print("PASS: viewport controller presents frames only while the session canvas is ready")
        print("PASS: viewport controller coalesces pointer motion to the newest point in flight")
        print("PASS: viewport controller reports pointer loss while the session is not connected")
        print("PASS: viewport controller maps viewport pointer motion onto the owned canvas")
        print("PASS: latest-frame-wins buffer keeps only the newest frame")
        print("PASS: input mapper preserves canvas corners and clamps viewport bounds")
        print("PASS: presentation layout pillarboxes a wider-than-source viewport")
        print("PASS: presentation layout letterboxes a taller-than-source viewport")
        print("PASS: presentation layout fills an exact-aspect viewport with no bars")
        print("PASS: presentation layout scales a smaller-than-source viewport instead of cropping it")
        print("PASS: input mapper round-trips the displayed video's centre and corners onto the canvas")
        print("PASS: input mapper clamps letterbox-margin input to the nearest canvas edge")
        print("PASS: decoder ingress requires recovery keyframes and rejects stale frames")
        print("PASS: in-memory control channel delivers framed messages")

        // --- The streamed resolution follows this viewer's drawable ---

        let earlySink = RecordingInputSink()
        let earlyViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: earlySink
        )
        guard await earlyViewport.setDrawableSize(pixelWidth: 3840, pixelHeight: 2400) == .droppedNotConnected,
              await earlySink.drawableSizes.isEmpty else {
            print("FAIL: the viewer reported its drawable size before the canvas was ready")
            Foundation.exit(1)
        }
        await earlyViewport.canvasDidBecomeReady()
        guard await earlySink.drawableSizes == [.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)] else {
            print("FAIL: a viewer already larger than the canvas did not report itself once the canvas was ready")
            Foundation.exit(1)
        }

        let scaleSink = RecordingInputSink()
        let scaleViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: scaleSink
        )
        await scaleViewport.canvasDidBecomeReady()
        // The default 960x600-point window on a 2x display is a 1920x1200
        // drawable: exactly what the host already streams, so nothing is sent
        // and a host that never learned this message keeps working unchanged.
        guard await scaleViewport.setDrawableSize(pixelWidth: 1920, pixelHeight: 1200) == .unchanged,
              await scaleSink.drawableSizes.isEmpty else {
            print("FAIL: a default-sized viewer sent a drawable size the host already assumes")
            Foundation.exit(1)
        }
        guard await scaleViewport.setDrawableSize(pixelWidth: 3840, pixelHeight: 2400) == .sent(2.0) else {
            print("FAIL: enlarging the viewer to the canvas's native pixels did not raise the stream scale")
            Foundation.exit(1)
        }
        // A few pixels of drag quantize to the same 0.25 step, so the encoder
        // is never rebuilt for them.
        guard await scaleViewport.setDrawableSize(pixelWidth: 3830, pixelHeight: 2394) == .unchanged,
              await scaleSink.drawableSizes == [.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)] else {
            print("FAIL: a sub-step viewer resize churned the host's encoder")
            Foundation.exit(1)
        }
        guard await scaleViewport.setDrawableSize(pixelWidth: 2880, pixelHeight: 1800) == .sent(1.5) else {
            print("FAIL: shrinking the viewer did not lower the stream scale")
            Foundation.exit(1)
        }
        for hostile in [(0.0, 1200.0), (-1920.0, 1200.0), (1920.0, 0.0), (Double.nan, 1200.0), (Double.infinity, 1200.0), (1e9, 1e9)] {
            guard await scaleViewport.setDrawableSize(pixelWidth: hostile.0, pixelHeight: hostile.1) == .invalid else {
                print("FAIL: a degenerate drawable size was reported to the host")
                Foundation.exit(1)
            }
        }
        guard await scaleSink.drawableSizes.count == 2 else {
            print("FAIL: a refused drawable size still reached the host")
            Foundation.exit(1)
        }

        // A person's own choice is a separate fact from the window's
        // geometry: choosing one must reach the host straight away, because a
        // choice the host has not been told is not a choice, and the window
        // may never be resized again.
        guard await scaleViewport.setStreamScalePreference(.fixed(1.25)) == .sent else {
            print("FAIL: choosing a fixed stream scale did not report it to the host")
            Foundation.exit(1)
        }
        guard await scaleSink.streamScalePreferences.last == .fixed(1.25) else {
            print("FAIL: the chosen scale was not sent as its own streamScalePreference message")
            Foundation.exit(1)
        }
        guard await scaleViewport.currentStreamScalePreference == .fixed(1.25),
              await scaleViewport.requestedStreamScale == 1.5 else {
            print("FAIL: the viewport does not report what it asked for and what the user chose")
            Foundation.exit(1)
        }
        // Re-choosing the same scale changes nothing the host does not
        // already know, so it must not churn the wire.
        guard await scaleViewport.setStreamScalePreference(.fixed(1.25)) == .unchanged,
              await scaleSink.streamScalePreferences.count == 1 else {
            print("FAIL: repeating an unchanged choice still reached the host")
            Foundation.exit(1)
        }
        guard await scaleViewport.setStreamScalePreference(.fixed(0.5)) == .invalid,
              await scaleSink.streamScalePreferences.count == 1 else {
            print("FAIL: a choice outside the streamable range was sent to the host")
            Foundation.exit(1)
        }
        guard await scaleViewport.setStreamScalePreference(.automatic) == .sent,
              await scaleSink.streamScalePreferences.last == .automatic else {
            print("FAIL: returning to automatic did not tell the host the choice is gone")
            Foundation.exit(1)
        }
        // A window resize is unaffected by any of the above: the drawable
        // size the host was told never carried a cap in the first place.
        guard await scaleSink.drawableSizes.last == .viewerDrawableSize(
            pixelWidth: 2880,
            pixelHeight: 1800,
            surfaceID: nil,
            maximumScale: nil
        ) else {
            print("FAIL: choosing and un-choosing a fixed scale disturbed the drawable-size report")
            Foundation.exit(1)
        }

        // A reconnect gets a fresh host session, which starts back at the
        // default scale; the viewer must say what it actually needs again or
        // an enlarged window would silently stay soft. A standing fixed
        // choice must also be told again, the same reasoning.
        let reconnectSink = RecordingInputSink()
        await scaleViewport.replacePointerSink(reconnectSink)
        _ = await scaleViewport.setStreamScalePreference(.fixed(1.25))
        await scaleViewport.canvasDidBecomeReady()
        guard await reconnectSink.drawableSizes == [.viewerDrawableSize(pixelWidth: 2880, pixelHeight: 1800, surfaceID: nil, maximumScale: nil)] else {
            print("FAIL: a reconnected session was not told the viewer's drawable size again")
            Foundation.exit(1)
        }
        guard await reconnectSink.streamScalePreferences == [.fixed(1.25)] else {
            print("FAIL: a reconnected session was not told the standing fixed choice again")
            Foundation.exit(1)
        }

        let scaleRouterSink = RecordingInputSink()
        let scaleRouterViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: scaleRouterSink
        )
        let scaleRouter = CanvasSurfaceEventRouter(viewport: scaleRouterViewport)
        await scaleRouterViewport.canvasDidBecomeReady()
        _ = await scaleRouter.route(.drawableSizeChanged(pixelWidth: 3840, pixelHeight: 2400))
        guard await scaleRouterSink.drawableSizes == [.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)] else {
            print("FAIL: a surface drawable-size change did not reach the host")
            Foundation.exit(1)
        }
        // `CanvasSurfaceView` reports its drawable from every hook that can
        // change it, including `layout()`, which AppKit runs whenever anything
        // in the viewer window is laid out again -- a telemetry tick into the
        // session HUD is enough, so this arrives on a timer for the life of
        // the session with the window untouched. A report that repeats the
        // size already reported is not a change and must not reach the
        // viewport: the viewport would derive the window's own scale from it
        // and overwrite whatever scale is actually in force, which is not
        // always the one this geometry justifies.
        guard await scaleRouterViewport.setDrawableSize(pixelWidth: 2880, pixelHeight: 1800) == .sent(1.5) else {
            print("FAIL: the viewport did not accept a drawable size reported from outside the router")
            Foundation.exit(1)
        }
        guard await scaleRouter.route(.drawableSizeChanged(pixelWidth: 3840, pixelHeight: 2400)) == .droppedNoChange,
              await scaleRouterViewport.requestedStreamScale == 1.5,
              await scaleRouterSink.drawableSizes.count == 2 else {
            print("FAIL: a repeated drawable-size report reached the host again and undid the scale in force")
            Foundation.exit(1)
        }
        // Only a repeat is dropped: a size that really changed still gets
        // through, or the viewer could never follow its own window again.
        guard await scaleRouter.route(.drawableSizeChanged(pixelWidth: 1920, pixelHeight: 1200)) == .droppedNoViewport,
              await scaleRouterViewport.requestedStreamScale == 1.0 else {
            print("FAIL: a real drawable-size change was dropped as a repeat")
            Foundation.exit(1)
        }

        // Why a resolution change must carry the host's existing packet
        // sequencer rather than starting a fresh one.
        let restartIngress = VideoFrameIngress()
        await restartIngress.receive(EncodedVideoFramePacket(
            sequence: 100,
            presentationTimeNanoseconds: 1000,
            isKeyFrame: true,
            codecConfiguration: Data([1]),
            payload: Data([1])
        ))
        guard await restartIngress.takeNewest()?.sequence == 100 else {
            print("FAIL: decoder ingress did not admit the stream's keyframe")
            Foundation.exit(1)
        }
        await restartIngress.receive(EncodedVideoFramePacket(
            sequence: 0,
            presentationTimeNanoseconds: 2000,
            isKeyFrame: true,
            codecConfiguration: Data([2]),
            payload: Data([2])
        ))
        guard await restartIngress.takeNewest() == nil else {
            print("FAIL: decoder ingress admitted a restarted sequence, so a resolution change may reset the sequencer")
            Foundation.exit(1)
        }

        // The codec refuses a presentation time a viewer cannot express, but
        // the decoder is reached by more than one path and turns that field
        // into a signed `CMTime` value itself. It checks rather than assumes:
        // an unchecked conversion of a number past `Int64.max` ends the viewer
        // outright.
        let unrepresentable = EncodedVideoFramePacket(
            sequence: 1,
            presentationTimeNanoseconds: UInt64(Int64.max) + 1,
            isKeyFrame: true,
            codecConfiguration: Data([0x67, 0x42, 0x00, 0x1F, 0x68, 0xCE]),
            payload: Data([1, 2, 3])
        )
        let checkingDecoder = VideoToolboxDecoder { _ in }
        do {
            try checkingDecoder.decode(unrepresentable)
            print("FAIL: the decoder took a presentation time it cannot express")
            Foundation.exit(1)
        } catch VideoToolboxDecoderError.invalidPresentationTime {
        } catch {
            print("FAIL: the decoder refused an unrepresentable presentation time as \(error), not as its own case")
            Foundation.exit(1)
        }
}
#endif
