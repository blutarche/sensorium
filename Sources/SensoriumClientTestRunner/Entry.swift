import Foundation
import SensoriumClient
import SensoriumCore

/// Every verification whose test file needs nothing beyond Foundation,
/// SensoriumCore and SensoriumClient. The ones that need AppKit, Metal,
/// VideoToolbox, CoreVideo, CryptoKit or Network live in `Entry+Darwin.swift`
/// and run through `runDarwinClientTests()`, which is a no-op elsewhere.
@main
struct SensoriumClientTestRunner {
    @MainActor
    static func main() async {
        // First, before anything here has awaited: the Linux event loop can
        // only take over the main queue while this actor has never suspended
        // -- see `GLibMainLoop`.
        testGLibMainLoopTests()
        testEvdevKeycodeTableTests()
        testWaylandPointerButtonMapTests()
        testWaylandScrollFrameTests()
        testKeyRepeatScheduleTests()
        testWaylandPointerCaptureTests()
        testWaylandShortcutInterceptorTests()
        testWaylandShortcutInterceptorRestartTests()
        await testWaylandPointerRoutingTests()
        await testWaylandLockedHostKeyRoutingTests()
        await testWaylandOverlayPointerRoutingTests()
        await testWaylandBandedPointerMappingTests()
        testWaylandOverlaySyncGateTests()
        testWaylandKeyboardStateTests()
        testWaylandPasteboardTests()
        testClipboardSyncSessionTests()
        testWaylandKeyboardStateModifiersEventTests()
        testWaylandKeyboardStateTruncatedKeymapSizeTests()
        await testInputRoutingTests()
        await testAuthenticatedHelloNamesThePinnedCertificate()
        await testCanvasSurfaceEventRouterSourceOriginTests()
        await runDarwinClientTests()
        await testViewerFrameCoalescingTests()
        testViewerPresentationPacingTests()
        await testDisplayCountMenuTests()
        await testSecondDisplayRefusalReconciliationTests()
        await testClientSessionControllerPairIntentTests()
        await testHostScreenModeMenuTests()
        await testHostScreenModeMemoryTests()
        await testEagerPairingRetryRuleTests()
        await testHostScreenResumeTicketRetentionTests()
        await runViewerHostStopTests()
        testShortcutStripLayoutPolicyTests()
        testWaylandOverlayLayoutTests()
        testShortcutStripBandTests()
        testViewerStatusPanelMetricsTests()
        testViewerStatusPanelHitTestTests()
        testSessionControlsWindowModelTests()
        testSessionChromeStateTests()
        testSessionControlsChordTests()
        testShortcutStripToggleChordTests()
        testShortcutStripIconNameTests()
        testViewerKeyNamesTests()
        testShortcutStripPinMemoryTests()
        testSavedMachinesStoreTests()
        testStartTargetTests()
        await testOfferedHostScreenStartTests()
        testYourMachinesWindowModelTests()
        await testViewerApplicationTests()
        testViewerSessionFailureCopyRowLineTests()
        testHostDisplaysAsleepCopyTests()
        await testHostDisplaysAsleepStopsTheRunTests()
        testViewerSessionStatusIndicatorPulseTests()
        runViewerTelemetryAndFidelityHUDTests()
        await testSilenceWatchdogTests()
        await testVideoDecodingSeamTests()
        testClientControlDialingTests()
        testViewerDialGuardTests()
        await testQUICControlConnectionTests()
        testQUICSessionCloseTests()
        testOpenSSLQUICIdleTimeoutTests()
        await testOpenSSLSessionThreadIdleTests()
        await testSessionCanvasWindowRoutingTests()
        testAVCodecVideoDecoderTests()
        testNV12ColorConversionTests()
        testWaylandSurfaceStateTests()
        await testCanvasObserverRegistrationTests()
        testWaylandPasteboardProxyTests()
        testLinuxViewerLocationsTests()
        testViewerFirstRunNoticeTests()
        await testViewportDrawableSizeTests()
    }
}
