import CoreMedia
import Foundation
import SensoriumCore
import SensoriumHost

/// The host side of a person's own stream-scale choice: `HostSessionController`
/// stores what a `streamScalePreference` message names, gated the same as
/// every other post-auth message, and `HostSessionCoordinator` resolves every
/// scale decision through it. `.automatic`'s own behaviour is proved
/// unchanged by the scale tests in `CoreSessionTestsPart3`; that a measured
/// fidelity limit still lowers a fixed choice is proved in
/// `StreamFidelityCoordinatorTests`, which can drive the limit deliberately.
@MainActor
func runStreamScalePreferenceHostTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]

    // A preference is gated exactly like viewerDrawableSize: an
    // unauthenticated peer cannot steer the host's encoder.
    let unauthenticatedController = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        requireAuthentication: true,
        keyConfinement: .unconfined
    )
    expectThrows(
        HostSessionControllerError.authenticationRequired,
        { _ = try unauthenticatedController.handle(.streamScalePreference(.fixed(1.5), surfaceID: nil)) },
        "an unauthenticated peer cannot choose the host's stream scale"
    )
    // An out-of-range surfaceID is refused the same way every other
    // surface-tagged message is, and survivably: one bad choice is not a
    // reason to drop an authenticated session.
    let rangeController = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        keyConfinement: .unconfined
    )
    expectThrows(
        HostSessionControllerError.invalidStreamScalePreference,
        { _ = try rangeController.handle(.streamScalePreference(.automatic, surfaceID: 99)) },
        "a preference naming a surface outside the wire's cap is refused"
    )
    expect(
        !HostSessionControllerError.invalidStreamScalePreference.isSessionFatal,
        "an invalid stream scale preference is survivable, not a reason to drop the session"
    )

    // The controller stores exactly what was asked, before any canvas
    // exists -- a client resending its saved preference right after pairing
    // must not be refused for it.
    let storesController = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        keyConfinement: .unconfined
    )
    expect(
        storesController.streamScalePreference(for: surfaceZero) == .automatic,
        "a surface starts at .automatic, exactly today's unchanged behaviour"
    )
    _ = try? storesController.handle(.streamScalePreference(.fixed(1.5), surfaceID: nil))
    expect(
        storesController.streamScalePreference(for: surfaceZero) == .fixed(1.5),
        "the controller stores exactly the preference a message named, before any canvas is up"
    )

    // A fixed choice is honoured exactly, ignoring the viewer's own window
    // geometry entirely, and takes effect immediately -- even when it lands
    // within one quantum of what is already streaming, which
    // `isWorthReconfiguring` would otherwise treat as not worth a rebuild.
    // That gate exists for idle churn; a deliberate choice is not idle churn.
    do {
        let media = FakeScalableCanvasMedia()
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined
            ),
            media: onlyOnSurfaceZero(media),
            videoSink: FakeVideoSink(),
            streamScaleSettleSeconds: 0.05
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // First-ever geometry-derived request: 1.25x, always applied.
        _ = try! await coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 2400, pixelHeight: 1500, surfaceID: nil, maximumScale: nil)
        )
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [1.25] },
            "the baseline geometry-derived scale is applied first"
        )

        // 1.25 -> 1.5 is exactly one quantum: `isWorthReconfiguring` would
        // suppress it as churn if this call site required a minimum delta.
        // It does not.
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.fixed(1.5), surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [1.25, 1.5] },
            "a fixed choice one quantum away from what is applied is honoured, not suppressed as idle churn"
        )

        // A resize that would derive 2.0x from geometry alone changes
        // nothing: a fixed choice is honoured exactly, with no
        // geometry-driven second-guessing once a person has stated one.
        _ = try! await coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)
        )
        try! await Task.sleep(for: .milliseconds(300))
        expect(
            media.reconfiguredScales == [1.25, 1.5],
            "a window resize never reaches reconfigure while a fixed choice is in force"
        )

        // Returning to .automatic hands control back to the viewer's
        // geometry, without needing a further resize.
        _ = try! await coordinator.handleWritingResponse(.streamScalePreference(.automatic, surfaceID: nil))
        expect(
            await waitUntil(timeoutSeconds: 2) { media.reconfiguredScales == [1.25, 1.5, 2.0] },
            "returning to automatic re-applies what the viewer's own geometry already wants, with no resize needed"
        )
    }
    print("PASS: a fixed stream scale choice is honoured exactly, applied immediately, and survives a resize until returned to automatic")
}
