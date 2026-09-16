import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@main
struct SensoriumClientTestRunner {
    @MainActor
    static func main() async {
        await testInputMappingAndPresentationTests()
        await testSurfaceRoutingAndSessionSetupTests()
        await testDecodeIngressAndLatencyTests()
        await testViewerFrameCoalescingTests()
        testViewerPresentationPacingTests()
        await testClipboardAndScaleTests()
        await testDualCanvasReconnectAndUITests()
        await testViewerUXFixTests()
        await testTailnetDevicePickerTests()
        await testMetalFramePresenterMeasuresRealCompletionNotJustScheduling()
        await testMetalFramePresenterDrawsBurstedFramesOnSuccessiveRefreshes()
        await testMetalFramePresenterRenderTests()
        testViewerIdentityFailureCopyReadsAsASentence()
        await testViewerIdentityRecoveryTests()
        await testViewerIdentityFailureButtonsTests()
        await testDisplayCountMenuTests()
        await testSecondDisplayRefusalReconciliationTests()
        await testPresenceCredentialTests()
        await testClientSessionControllerPairIntentTests()
        await testHostScreenSessionFlowTests()
        await testHostScreenViewerInputTests()
        await testHostScreenModeMenuTests()
        await testHostScreenModeMemoryTests()
        await testClipboardSharingMenuTests()
        await testEagerPairingRetryRuleTests()
        await testHostScreenResumeTicketRetentionTests()
        await runViewerHostStopTests()
        await testViewerMainMenuUnregisterTests()
        testShortcutStripTests()
        testShortcutStripVisibilityTests()
        testShortcutStripPinTests()
        testShortcutStripPinSurvivesReconnectTests()
        testShortcutStripLayoutPolicyTests()
        testShortcutStripHandleTests()
        testShortcutStripHandleStaysCenteredWhenNarrow()
        testShortcutStripButtonAppearanceTests()
        testShortcutStripPinButtonAppearanceTests()
        testShortcutStripSymbolsTests()
        testShortcutStripPinMemoryTests()
        testCanvasChromeClickPolicyTests()
        await testCanvasSurfaceChromeClickTests()
        await testShortcutStripSendsWholeChordsTests()
        testSavedMachinesStoreTests()
        testStartTargetTests()
        testYourMachinesWindowModelTests()
        testViewerSessionFailureCopyRowLineTests()
        testHostDisplaysAsleepCopyTests()
        await testHostDisplaysAsleepStopsTheRunTests()
        testViewerSessionStatusIndicatorPulseTests()
        await testYourMachinesWindowTests()
        testViewerFormActionButtonPaddingTests()
        testViewerPairingFieldCellCenteringTests()
        runViewerTelemetryAndFidelityHUDTests()
        runSessionHUDSparklineAndAddressTests()
        testAboutPanelCreditTests()
        await testHostScreenUnlockClientTests()
        await testHostScreenUnlockArmFlowTests()
        await testSilenceWatchdogTests()
    }
}
