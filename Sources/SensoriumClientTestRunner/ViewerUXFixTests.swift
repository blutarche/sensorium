import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
func testViewerUXFixTests() async {

        // Hiding the local cursor over the ordinary canvas would make every
        // pointer movement wait for the whole capture-encode-send-decode-
        // present pipeline before the person saw anything move -- measured at
        // 34 ms p50 / 117 ms p95 glass-to-glass in a live session. The viewer
        // instead draws its own local arrow there at all times; only captured-
        // pointer mode still hides it, because relative motion leaves the
        // arrow's screen position meaningless. `NSCursor`'s hide/unhide is a
        // system-wide reference count, not a per-caller flag, so this proves
        // the balance itself, not just the resulting boolean.
        do {
            var policy = CanvasCursorVisibilityPolicy()
            expect(!policy.shouldHideCursor && !policy.isHidden, "a fresh policy hides nothing")

            expect(
                policy.capturingPointerChanged(true) == .hide,
                "entering captured-pointer mode hides the local arrow, since relative motion leaves its position meaningless"
            )
            expect(policy.isHidden, "the policy now believes the cursor is hidden")
            expect(
                policy.capturingPointerChanged(true) == .none,
                "reporting the same capture state twice must not double-hide"
            )
            expect(
                policy.capturingPointerChanged(false) == .unhide,
                "leaving captured-pointer mode is the ordinary way out"
            )
            expect(!policy.isHidden, "unhidden after the only reason left")
            expect(
                policy.capturingPointerChanged(false) == .none,
                "reporting the same exit twice must not double-unhide"
            )

            // The last-resort exit: `reset()` restores it in exactly one call
            // and is idempotent afterward.
            var teardown = CanvasCursorVisibilityPolicy()
            _ = teardown.capturingPointerChanged(true)
            expect(teardown.isHidden, "hidden while capture is on, before teardown")
            expect(teardown.reset() == .unhide, "tearing down restores the cursor exactly once")
            expect(teardown.reset() == .none, "a second teardown call must not double-unhide")

            // A long deterministic run of every kind of transition, checked
            // after every step: the outstanding hide/unhide count -- which is
            // what a hidden-with-no-cursor-anywhere bug would violate -- can
            // only ever be 0 or 1, never negative and never counted twice.
            var fuzzed = CanvasCursorVisibilityPolicy()
            var outstanding = 0
            let script: [(Int) -> CanvasCursorVisibilityPolicy.Transition] = [
                { i in fuzzed.capturingPointerChanged(i % 3 == 0) },
                { i in fuzzed.overlayVisibilityChanged(i % 5 == 0) }
            ]
            for i in 0..<200 {
                let transition = script[i % script.count](i)
                switch transition {
                case .hide: outstanding += 1
                case .unhide: outstanding -= 1
                case .none: break
                }
                expect(outstanding == 0 || outstanding == 1, "the cursor is hidden by at most one outstanding hide() at step \(i)")
                expect((outstanding == 1) == fuzzed.isHidden, "the outstanding count and the policy's own isHidden agree at step \(i)")
            }
            _ = fuzzed.reset()
            expect(!fuzzed.isHidden, "every reason cleared by reset leaves the cursor visible")

            print("PASS: the local cursor hides only in captured-pointer mode, once, and every exit restores it exactly once")
        }

        // Defect: the session status overlay (Connecting, Reconnecting, Lost,
        // Ended, refusals) covers the canvas, but must still force the local
        // arrow visible over its own buttons even while captured-pointer mode
        // wants it hidden -- otherwise there is nothing on screen to click
        // "Try again" or "Quit" with.
        do {
            var captured = CanvasCursorVisibilityPolicy()
            expect(captured.capturingPointerChanged(true) == .hide, "captured-pointer mode hides the cursor on its own")
            expect(
                captured.overlayVisibilityChanged(true) == .unhide,
                "an overlay covering a captured-pointer session must still restore the cursor -- its buttons need to be clickable too"
            )
            expect(!captured.shouldHideCursor, "capture mode alone cannot hide the cursor while the overlay is up")
            expect(
                captured.overlayVisibilityChanged(false) == .hide,
                "the overlay going away with capture still on hides the cursor again"
            )
            expect(
                captured.overlayVisibilityChanged(false) == .none,
                "reporting the same overlay state twice must not double-hide"
            )

            print("PASS: the session status overlay always keeps the local cursor visible over its own buttons, even in captured-pointer mode")
        }

        // The stuck-cursor regression: CGAssociateMouseAndMouseCursorPosition
        // is a machine-wide connection, not a per-session flag, so an
        // unbalanced disassociate is worse than an unbalanced NSCursor.hide()
        // -- it leaves the user's physical mouse dead with nothing on screen
        // to click and fix it. Proven the same way as the cursor-visibility
        // balance: exact transitions on every path, then a long fuzzed run.
        do {
            var policy = CanvasPointerAssociationPolicy()
            expect(!policy.isCapturing && !policy.isDisassociated, "a fresh policy starts connected")

            expect(policy.capturingPointerChanged(true) == .disassociate, "entering capture disconnects the physical mouse")
            expect(policy.isDisassociated, "the policy now believes the mouse is disconnected")
            expect(policy.capturingPointerChanged(true) == .none, "reporting the same capture state twice must not disassociate twice")
            expect(policy.capturingPointerChanged(false) == .associate, "leaving capture reconnects it")
            expect(!policy.isDisassociated, "reconnected after the only reason to be disconnected ended")
            expect(policy.capturingPointerChanged(false) == .none, "reporting the same release twice must not reconnect twice")

            // The abrupt-teardown case named explicitly: a session that ends
            // mid-capture, with no `capturingPointerChanged(false)` ever
            // reported, must still reconnect in exactly one call.
            var teardown = CanvasPointerAssociationPolicy()
            _ = teardown.capturingPointerChanged(true)
            expect(teardown.isDisassociated, "disconnected mid-capture, before any teardown")
            expect(teardown.reset() == .associate, "an abrupt teardown mid-capture still reconnects exactly once")
            expect(teardown.reset() == .none, "a second teardown call must not reconnect twice")
            expect(!teardown.isCapturing, "reset also clears capture itself, so a stray togglePointerCapture() after teardown cannot re-disassociate on a false premise")

            // The same 200-step fuzz as the cursor-visibility balance, over
            // the one signal this policy actually has: capture toggling and
            // teardown, interleaved, checked after every step.
            var fuzzed = CanvasPointerAssociationPolicy()
            var outstanding = 0
            for i in 0..<200 {
                let transition: CanvasPointerAssociationPolicy.Transition
                if i % 7 == 0 {
                    transition = fuzzed.reset()
                } else {
                    transition = fuzzed.capturingPointerChanged(i % 3 != 0)
                }
                switch transition {
                case .disassociate: outstanding += 1
                case .associate: outstanding -= 1
                case .none: break
                }
                expect(outstanding == 0 || outstanding == 1, "the mouse is disconnected by at most one outstanding call at step \(i)")
                expect((outstanding == 1) == fuzzed.isDisassociated, "the outstanding count and the policy's own isDisassociated agree at step \(i)")
            }
            _ = fuzzed.reset()
            expect(!fuzzed.isDisassociated, "the fuzzed run ends reconnected after a final teardown")

            print("PASS: the physical mouse is disconnected at most once, and every exit, abrupt teardown included, reconnects it exactly once")
        }

        // The window title docs/ux-spec.md names: "<machine name> @ <tailnet
        // name>" once the host has said who it is, the address-derived name
        // from pairing when it has not.
        do {
            expect(
                ViewerWindowTitle.resolve(hostMachineName: "Mac mini", savedHost: "mini.tailnet.ts.net", fallback: "mini.tailnet.ts.net")
                    == "Mac mini @ mini.tailnet.ts.net",
                "a host that names itself is shown as its name and the address it was reached at"
            )
            expect(
                ViewerWindowTitle.resolve(hostMachineName: nil, savedHost: "mini.tailnet.ts.net", fallback: "Downstairs Mini")
                    == "Downstairs Mini",
                "an old host that never sends hostName falls back to today's title"
            )
            expect(
                ViewerWindowTitle.resolve(hostMachineName: "", savedHost: "mini.tailnet.ts.net", fallback: "mini.tailnet.ts.net")
                    == "mini.tailnet.ts.net",
                "an empty hostName is treated the same as none, not as a blank name"
            )

            print("PASS: the window title names the host's machine and address, and falls back cleanly when the name is absent")
        }

        // Defect: the second session window's title said "(Canvas 2)" --
        // internal vocabulary docs/ux-spec.md forbids on screen. Named by
        // the same word the Displays menu itself uses.
        do {
            let title = ViewerWindowTitle.secondDisplayTitle(primaryTitle: "Mac mini @ mini.tailnet.ts.net")
            expect(title == "Mac mini @ mini.tailnet.ts.net \u{2014} Display 2", "the second window's title names which display it is, in the menu's own words")
            expect(!title.lowercased().contains("canvas"), "no window title ever says canvas")
            expect(!title.lowercased().contains("surface"), "no window title ever says surface")

            print("PASS: the second session window's title names Display 2, not Canvas 2")
        }

        // Defect: captured-pointer mode ("Cmd-Shift-G... it seems bugged")
        // and the streamed resolution ("blurry and looks shit") were both
        // invisible from the UI: the HUD said nothing about pointer mode, and
        // `ClientCanvasWindowController.selectStreamScale(_:)` had no menu
        // item calling it at all.
        do {
            expect(
                ViewerMenuPlan.pointerCaptureTitle(isCaptured: false) == "Capture Pointer"
                    && ViewerMenuPlan.pointerCaptureTitle(isCaptured: true) == "Release Captured Pointer",
                "the View menu's item says which mode this window is in, not just 'Toggle'"
            )

            func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
                sections.flatMap(\.rows).first { $0.label == label }
            }
            let capturedSnapshot = SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil,
                isPointerCaptured: true
            )
            let capturedRow = hudRow(SessionHUDPanel.sections(telemetry: capturedSnapshot, session: nil), "POINTER")
            expect(capturedRow?.value == "captured", "the HUD states captured-pointer mode plainly")
            expect(
                capturedRow?.note?.contains("Control-Option-Command-Escape") == true,
                "the HUD names the exact exit gesture, not just that one exists"
            )
            expect(capturedRow?.tone == .warn, "a mode that changes what the mouse does is worth a tone, not a silent row")

            let freeSnapshot = SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil
            )
            let freeRow = hudRow(SessionHUDPanel.sections(telemetry: freeSnapshot, session: nil), "POINTER")
            expect(freeRow?.value == "free" && freeRow?.note == nil, "ordinary absolute-pointer mode states itself with nothing to explain")

            print("PASS: captured-pointer mode is named in the HUD and the View menu title, not left to be guessed")
        }

        // PRESENT means the real, GPU-measured completion latency, never
        // `clientMetrics`'s decode-to-scheduling number; that number is
        // shown separately, under UPDATES, its own honest name.
        do {
            func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
                sections.flatMap(\.rows).first { $0.label == label }
            }
            var clientMetrics = SessionMetrics()
            _ = clientMetrics.record(stage: .present, startedAtNanoseconds: 0, endedAtNanoseconds: 300_000)
            let snapshot = SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: clientMetrics,
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil,
                presentCompletionP50Nanoseconds: 4_500_000
            )
            let sections = SessionHUDPanel.sections(telemetry: snapshot, session: nil)
            expect(
                hudRow(sections, "PRESENT")?.value == "4.5 ms",
                "PRESENT reads the real completion-measured number, not clientMetrics's scheduling one, got: \(hudRow(sections, "PRESENT")?.value ?? "nil")"
            )
            expect(
                hudRow(sections, "UPDATES")?.value == "0.3 ms",
                "the old decode-to-scheduling number survives under its own honest name rather than vanishing, got: \(hudRow(sections, "UPDATES")?.value ?? "nil")"
            )

            let noSamplesYet = SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil
            )
            expect(
                hudRow(SessionHUDPanel.sections(telemetry: noSamplesYet, session: nil), "PRESENT")?.value == "not yet",
                "before a single frame has actually completed a draw, PRESENT says so rather than showing a zero"
            )

            print("PASS: the HUD's PRESENT row shows GPU-completion latency, and the scheduling figure keeps its own row, UPDATES")
        }

        // The INPUT RTT row: this machine's own send-to-inputApplied round trip,
        // alongside the other viewer-local stages in the "THIS MACHINE" column --
        // see `SessionMetricStage.inputRoundTrip`.
        do {
            func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
                sections.flatMap(\.rows).first { $0.label == label }
            }
            var clientMetrics = SessionMetrics()
            _ = clientMetrics.record(stage: .inputRoundTrip, startedAtNanoseconds: 0, endedAtNanoseconds: 8_000_000)
            let snapshot = SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: clientMetrics,
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil
            )
            let sections = SessionHUDPanel.sections(telemetry: snapshot, session: nil)
            expect(
                hudRow(sections, "INPUT RTT")?.value == "8.0 ms",
                "INPUT RTT shows this machine's own send-to-inputApplied round trip, got: \(hudRow(sections, "INPUT RTT")?.value ?? "nil")"
            )

            let noSamplesYet = SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
                requestedStreamScale: nil,
                streamScalePreference: .automatic,
                decoder: nil
            )
            expect(
                hudRow(SessionHUDPanel.sections(telemetry: noSamplesYet, session: nil), "INPUT RTT")?.value == "not yet",
                "before any input round trip has been measured, INPUT RTT says so rather than showing a zero"
            )

            print("PASS: the session HUD lists this machine's own input round trip alongside its other client-local latency stages")
        }

        // The resolution picker: every step `StreamScalePolicy` allows,
        // labelled with the pixel size it actually streams, and the one line
        // explaining a picture the host is holding below what was asked for.
        do {
            let canvas = SavedHost.remoteCanvasPreset
            let items = DisplayScaleMenuPlan.items(
                selectedPreference: .fixed(1.5),
                canvasLogicalWidth: Double(canvas.logicalWidth),
                canvasLogicalHeight: Double(canvas.logicalHeight)
            )
            expect(items.first?.scale == nil && items.first?.title == "Automatic", "Automatic leads the menu")
            expect(
                items.map(\.scale) == [nil, 1.0, 1.25, 1.5, 1.75, 2.0],
                "every explicit step StreamScalePolicy allows is offered, got: \(items.map(\.scale))"
            )
            expect(
                items.first { $0.scale == 1.0 }?.title == "1.00x (1920 x 1200)",
                "1.00x streams the canvas's own logical size"
            )
            expect(
                items.first { $0.scale == 2.0 }?.title == "2.00x (3840 x 2400)",
                "2.00x streams the canvas's full native pixels"
            )
            expect(
                items.first { $0.scale == 1.5 }?.isSelected == true
                    && items.filter(\.isSelected).count == 1,
                "exactly the user's current choice is marked selected"
            )
            expect(
                DisplayScaleMenuPlan.items(
                    selectedPreference: .automatic,
                    canvasLogicalWidth: Double(canvas.logicalWidth),
                    canvasLogicalHeight: Double(canvas.logicalHeight)
                ).first?.isSelected == true,
                "automatic selects the Automatic row"
            )

            expect(
                DisplayScaleMenuPlan.clampNotice(appliedStreamScale: 1.5, requestedStreamScale: 1.5) == nil,
                "no clamp notice when the host is streaming exactly what was asked for"
            )
            expect(
                DisplayScaleMenuPlan.clampNotice(appliedStreamScale: nil, requestedStreamScale: 2.0) == nil,
                "no clamp notice before the host has ever reported an applied scale"
            )
            expect(
                DisplayScaleMenuPlan.clampNotice(appliedStreamScale: 1.5, requestedStreamScale: 2.0)?.contains("1.50x") == true
                    && DisplayScaleMenuPlan.clampNotice(appliedStreamScale: 1.5, requestedStreamScale: 2.0)?.contains("2.00x") == true,
                "a genuinely clamped picture names both the scale it is stuck at and the one that was asked for"
            )
            expect(
                DisplayScaleMenuPlan.clampNotice(
                    appliedStreamScale: 1.75, requestedStreamScale: 2.0, clampedFromUserChoice: 2.0
                )?.contains("you asked for 2.00x") == true,
                "the host's own report of a clamped fixed choice is preferred over the plain geometry comparison"
            )
            expect(
                !(DisplayScaleMenuPlan.clampNotice(appliedStreamScale: 1.5, requestedStreamScale: 2.0)?.contains(" -- ") ?? true)
                    && !(DisplayScaleMenuPlan.clampNotice(
                        appliedStreamScale: 1.75, requestedStreamScale: 2.0, clampedFromUserChoice: 2.0
                    )?.contains(" -- ") ?? true),
                "the clamp notice uses an em dash, not a double hyphen with spaces around it"
            )

            print("PASS: the Display menu labels Automatic and every explicit scale with its pixel size, and explains a clamped picture")
        }

        // The panel grows to fit its widest button row, rather than
        // compressing one that is wider than its fixed 400pt -- the
        // host-screen row, whose middle button names the target it offers,
        // is the one that needs the room.
        do {
            let ordinaryRow = StatusPanelLayout.width(forButtonTitles: ["Try again", "Stop trying"])
            expect(
                ordinaryRow == StatusPanelLayout.defaultWidth,
                "a short row that already fits the default panel does not grow it, got \(ordinaryRow)"
            )

            let noButtons = StatusPanelLayout.width(forButtonTitles: [])
            expect(
                noButtons == StatusPanelLayout.defaultWidth,
                "a state with no buttons keeps the default width, got \(noButtons)"
            )

            let hostScreenRow = StatusPanelLayout.width(
                forButtonTitles: ["Your machines", "Connect with a virtual display", "Pair again"]
            )
            expect(
                hostScreenRow > StatusPanelLayout.defaultWidth,
                "the host-screen row does not fit the default width and must grow the panel, "
                    + "got \(hostScreenRow)"
            )

            let widerRow = StatusPanelLayout.width(
                forButtonTitles: ["Your machines", "Connect with a virtual display and more", "Pair again"]
            )
            expect(
                widerRow > hostScreenRow,
                "a wider title in the same row widens the panel further, got \(widerRow) vs \(hostScreenRow)"
            )

            print("PASS: the status panel grows to fit its widest button row rather than compressing any button")
        }

        // A panel sized per state changes width as a session goes lost ->
        // reconnecting -> gave up, so the whole panel jumps under the eye at
        // exactly the moment the person is reading it. One width for the
        // whole session, wide enough for every button row any state can
        // show -- and the list of rows it is computed from cannot drift
        // from the state machine without this catching it.
        do {
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            var statuses = [machine.status]
            machine.handle(.connectStarted)
            machine.handle(.canvasReady)
            statuses.append(machine.handle(.sessionEnded))
            statuses.append(machine.handle(.connectStarted))
            statuses.append(machine.handle(.connectStarted))
            statuses.append(machine.handle(.stoppedByHost(reasonLine: "reason")))
            statuses.append(machine.handle(.stopRequested))
            statuses.append(machine.handle(.retryRequested))
            statuses.append(machine.handle(.gaveUp))
            for offersPairAgain in [false, true] {
                var ended = ViewerSessionStateMachine(hostName: "mac-mini")
                statuses.append(ended.handle(
                    .hostScreenConnectEnded(reasonLine: "reason", offersPairAgain: offersPairAgain)
                ))
            }

            let sessionWidth = StatusPanelLayout.sessionPanelWidth
            for status in statuses {
                let titles = status.buttons.map(\.title)
                let own = StatusPanelLayout.width(forButtonTitles: titles)
                expect(
                    own <= sessionWidth,
                    "the \(status.eyebrow) state's row \(titles) needs \(own)pt, wider than the session "
                        + "panel's \(sessionWidth)pt -- ViewerSessionStateMachine.buttonRows is missing it"
                )
                expect(
                    ViewerSessionStateMachine.buttonRows.contains(titles),
                    "the \(status.eyebrow) state's row \(titles) is not listed in "
                        + "ViewerSessionStateMachine.buttonRows"
                )
            }
            expect(
                sessionWidth == StatusPanelLayout.width(
                    forButtonTitles: ["Your machines", "Connect with a virtual display", "Pair again"]
                ),
                "the session panel is exactly as wide as its widest row, the refusal row that offers pairing "
                    + "again, got \(sessionWidth)"
            )

            print("PASS: the session status panel keeps one width across every state, sized to the widest button row")
        }

        // The Displays-menu refusal banner wraps its sentence at 360pt. The
        // unrecognised-reason line needs four lines there, and a line cap on
        // the label cut off the last one -- the remedy. The label's wrapped
        // height must drive the banner's own height instead.
        do {
            func laidOut(_ text: String) -> (notice: ViewerTransientNoticeView, label: NSTextField, neededHeight: CGFloat) {
                let notice = ViewerTransientNoticeView()
                notice.show(text)
                notice.frame = NSRect(origin: .zero, size: notice.fittingSize)
                notice.layoutSubtreeIfNeeded()
                guard let label = notice.subviews.compactMap({ $0 as? NSTextField }).first,
                      let font = label.font
                else {
                    print("FAIL: the transient notice has no label to measure")
                    Foundation.exit(1)
                }
                let needed = NSAttributedString(string: text, attributes: [.font: font])
                    .boundingRect(
                        with: NSSize(width: label.preferredMaxLayoutWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]
                    ).height
                return (notice, label, ceil(needed))
            }

            let fourLineText = DisplayCountRefusalCopy.line(
                reason: "a-reason-this-build-has-never-seen", hostLabel: "mac-mini"
            )
            let wrapped = laidOut(fourLineText)
            let threeLines = laidOut("one\ntwo\nthree")
            let lineHeight = laidOut("one").neededHeight
            expect(
                wrapped.neededHeight > lineHeight * 3.5,
                "the unrecognised-reason line is the fixture because it needs four lines at the label's "
                    + "width, got \(wrapped.neededHeight)pt against a line height of \(lineHeight)pt"
            )
            expect(
                wrapped.label.frame.height >= wrapped.neededHeight - 1,
                "the label shows every line the sentence wraps to, got \(wrapped.label.frame.height)pt "
                    + "for a sentence needing \(wrapped.neededHeight)pt"
            )
            expect(
                wrapped.notice.fittingSize.height > threeLines.notice.fittingSize.height,
                "a four-line sentence makes the banner taller than a three-line one, got "
                    + "\(wrapped.notice.fittingSize.height) vs \(threeLines.notice.fittingSize.height)"
            )

            print("PASS: the transient notice grows with its wrapped sentence instead of cutting off the fourth line")
        }

        // Without `.attemptFailed`, a retried dial that never answers would
        // redraw the identical "Connecting…" panel forever, with no sign
        // that anything was tried or why it failed. It must say so on the
        // spot, keep numbering attempts across the retry, and get out of the
        // way once the wait it describes is over.
        do {
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            machine.handle(.connectStarted)
            let failed = machine.handle(.attemptFailed(reasonLine: "Nothing answered."))
            expect(
                failed.phase == .connecting && failed.buttons.map(\.title) == ["Quit Sensorium", "Your machines"],
                "a failed first attempt stays on the connecting panel with its own buttons, got \(failed.phase) / \(failed.buttons.map(\.title))"
            )
            expect(
                failed.detail.contains("Attempt 1") && failed.detail.contains("Nothing answered."),
                "the connecting detail names the failed attempt and repeats why it failed, got \"\(failed.detail)\""
            )

            let retried = machine.handle(.connectStarted)
            expect(
                retried.phase == .connecting
                    && retried.detail.contains("Attempt 2")
                    && retried.detail.contains("Nothing answered."),
                "a fresh attempt after a known failure still names the new attempt and the last failure, got \"\(retried.detail)\""
            )

            print("PASS: the connecting panel counts attempts and repeats the last attempt's failure")
        }

        do {
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            machine.handle(.connectStarted)
            machine.handle(.canvasReady)
            let liveThenLost = machine.handle(.sessionEnded)
            let ignoredWhileLost = machine.handle(.attemptFailed(reasonLine: "should still not appear"))
            expect(
                ignoredWhileLost == liveThenLost,
                "a phase outside connecting or reconnecting ignores the report entirely, got \(ignoredWhileLost)"
            )

            print("PASS: attemptFailed is a no-op outside the connecting and reconnecting phases")
        }

        do {
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            machine.handle(.connectStarted)
            machine.handle(.canvasReady)
            machine.handle(.sessionEnded)
            let reconnecting = machine.handle(.connectStarted)
            expect(reconnecting.phase == .reconnecting, "a drop after a live session redials as reconnecting, got \(reconnecting.phase)")

            let failedReconnect = machine.handle(.attemptFailed(reasonLine: "Nothing answered."))
            expect(
                failedReconnect.phase == .reconnecting
                    && failedReconnect.detail.contains("Attempt 1")
                    && failedReconnect.detail.contains("Nothing answered."),
                "reconnecting keeps its own numbering and appends the failure line, got \"\(failedReconnect.detail)\""
            )

            let secondFailedReconnect = machine.handle(.connectStarted)
            expect(
                secondFailedReconnect.detail.contains("Attempt 2"),
                "the next reconnect attempt still counts up, got \"\(secondFailedReconnect.detail)\""
            )

            print("PASS: reconnecting keeps numbering attempts and appends the last failure's line")
        }

        do {
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            machine.handle(.connectStarted)
            machine.handle(.attemptFailed(reasonLine: "Nothing answered."))
            let retried = machine.handle(.retryRequested)
            expect(
                !retried.detail.contains("Nothing answered."),
                "asking to try again clears the remembered failure line, got \"\(retried.detail)\""
            )

            print("PASS: retryRequested clears the remembered failure line")
        }

        // Without a stated priority, Return would land on Quit Sensorium
        // whenever a row had no primary button -- the connecting and
        // reconnecting rows both put Quit first with no primary at all -- so
        // a stray Return would quit the app while it was still trying.
        // Focus must go to the primary if there is one, else the first
        // non-quit button, else nothing.
        do {
            expect(
                ViewerFocusPolicy.chosenIndex(among: [
                    (action: .quit, isPrimary: false),
                    (action: .yourMachines, isPrimary: false)
                ]) == 1,
                "the connecting row with no primary focuses Your machines, not Quit"
            )
            expect(
                ViewerFocusPolicy.chosenIndex(among: [
                    (action: .quit, isPrimary: false),
                    (action: .stopTrying, isPrimary: false)
                ]) == 1,
                "the reconnecting row with no primary focuses Stop trying, not Quit"
            )
            expect(
                ViewerFocusPolicy.chosenIndex(among: [
                    (action: .quit, isPrimary: false),
                    (action: .yourMachines, isPrimary: false),
                    (action: .tryAgain, isPrimary: true)
                ]) == 2,
                "the recovery row focuses its primary, Try again, not the first button"
            )
            expect(
                ViewerFocusPolicy.chosenIndex(among: [(action: .quit, isPrimary: false)]) == nil,
                "a row of only Quit chooses nothing, so the canvas keeps focus"
            )

            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            var statuses = [machine.status]
            machine.handle(.connectStarted)
            machine.handle(.canvasReady)
            statuses.append(machine.handle(.sessionEnded))
            statuses.append(machine.handle(.connectStarted))
            statuses.append(machine.handle(.connectStarted))
            statuses.append(machine.handle(.stoppedByHost(reasonLine: "reason")))
            statuses.append(machine.handle(.stopRequested))
            statuses.append(machine.handle(.retryRequested))
            statuses.append(machine.handle(.gaveUp))
            for offersPairAgain in [false, true] {
                var ended = ViewerSessionStateMachine(hostName: "mac-mini")
                statuses.append(ended.handle(
                    .hostScreenConnectEnded(reasonLine: "reason", offersPairAgain: offersPairAgain)
                ))
            }
            for status in statuses {
                let entries = status.buttons.map { (action: $0.action, isPrimary: $0.isPrimary) }
                if let index = ViewerFocusPolicy.chosenIndex(among: entries) {
                    expect(
                        entries[index].action != .quit,
                        "the \(status.eyebrow) state focused Quit Sensorium, got \(entries)"
                    )
                }
            }

            print("PASS: the status panel never puts keyboard focus on Quit Sensorium")
        }

        // Typing stopped reaching the host while clicking kept working: the
        // panel rebuilt its button row only for a state it actually shows, so
        // a live session hid it with the previous state's buttons still in
        // it. The window then handed the keyboard to one of those hidden
        // buttons instead of to the canvas, which is the only view that
        // forwards a key -- while a click, which is delivered by position
        // rather than to the keyboard's owner, still landed on the canvas.
        do {
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            let connecting = machine.handle(.connectStarted)
            expect(
                ViewerClientTestHooks.statusOverlayFocusTitle(after: [connecting]) == "Your machines",
                "while it is up, the connecting panel takes the keyboard for its own first non-quit button"
            )

            let live = machine.handle(.canvasReady)
            expect(
                ViewerClientTestHooks.statusOverlayFocusTitle(after: [connecting, live]) == nil,
                "a live session hides the panel, so it must want no keyboard focus and leave the canvas holding it, got "
                    + String(describing: ViewerClientTestHooks.statusOverlayFocusTitle(after: [connecting, live]))
            )

            print("PASS: the hidden session panel wants no keyboard focus, so a live canvas keeps the keys")
        }

        // A certificate pin or host key mismatch is not something another
        // attempt can fix, so redialling forever and showing "Attempt 26 is
        // under way. Last attempt: Stopped: …" would be dishonest. The event
        // this drives from must end the wait outright, the same way
        // `hostScreenConnectEnded` already does for a refused host-screen
        // connect, with its own buttons: Pair again first, since re-pinning
        // the key is the only fix.
        do {
            let reasonLine = ViewerSessionFailureCopy.line(for: .unverifiedHost, hostLabel: "mac-mini")
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            machine.handle(.connectStarted)
            let ended = machine.handle(.unverifiedHostConnectEnded(reasonLine: reasonLine))
            expect(ended.phase == .ended, "an unverified host ends the wait outright, got \(ended.phase)")
            expect(ended.detail == reasonLine, "the panel shows the unverified-host wording verbatim, got \"\(ended.detail)\"")
            expect(
                ended.buttons.map(\.action) == [.quit, .yourMachines, .pairAgain],
                "the unverified-host state offers Quit, Your machines, and Pair again, got \(ended.buttons.map(\.action))"
            )
            let primary = ended.buttons.first { $0.isPrimary }
            expect(primary?.action == .pairAgain, "Pair again is the primary action, since re-pinning the key is the only fix")
            expect(
                !ended.detail.hasPrefix("Attempt") && !ended.headline.contains("Attempt"),
                "the terminal state never reads like an attempt still under way"
            )

            let focusIndex = ViewerFocusPolicy.chosenIndex(among: ended.buttons.map { (action: $0.action, isPrimary: $0.isPrimary) })
            expect(
                focusIndex.map { ended.buttons[$0].action != .quit } ?? true,
                "focus never lands on Quit for the unverified-host state"
            )

            print("PASS: a host that fails verification ends the retry loop with Pair again as the way out")
        }

        // Everything before the first picture belongs to the launch window
        // now: it lists the saved machines, dials the one that is clicked, and
        // reports that attempt on its own row. This state machine drives the
        // canvas overlay only, so nothing here offers a Connect of its own,
        // and the way back to that list is a button that names it.
        do {
            var machine = ViewerSessionStateMachine(hostName: "mac-mini")
            machine.handle(.connectStarted)
            machine.handle(.canvasReady)
            let lost = machine.handle(.sessionEnded)
            expect(
                lost.buttons.map(\.action) == [.quit, .yourMachines, .tryAgain],
                "a lost session offers Quit, Your machines, and Try again, got \(lost.buttons.map(\.action))"
            )
            expect(
                lost.buttons.first { $0.action == .yourMachines }?.title == "Your machines",
                "and the button naming the launch window is called what that window is called"
            )
            expect(
                ViewerSessionStateMachine.buttonRows.allSatisfy { titles in titles.allSatisfy { $0 != "Connect" } },
                "no overlay row offers a Connect of its own, got \(ViewerSessionStateMachine.buttonRows)"
            )

            print("PASS: the canvas overlay offers Your machines rather than a Connect of its own")
        }
}
