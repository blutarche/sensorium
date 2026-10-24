#if canImport(AppKit)
import AppKit
import CoreVideo
import CryptoKit
import Foundation
import Metal
import MetalKit
import Network
import SensoriumClient
import SensoriumCore
import VideoToolbox

/// Every verification whose test file needs an Apple framework: a window
/// server connection, a Metal device, a pixel buffer, a keychain-backed key,
/// or Network.framework.
@MainActor
func runDarwinClientTests() async {
    await testHostScreenSessionFlowTests()
    await testHostScreenViewerInputTests()
    await testInputMappingAndPresentationTests()
    await testSurfaceRoutingAndSessionSetupTests()
    await testDecodeIngressAndLatencyTests()
    await testClipboardAndScaleTests()
    await testDualCanvasReconnectAndUITests()
    await testViewerUXFixTests()
    await testTailnetDevicePickerTests()
    await testMetalFramePresenterMeasuresRealCompletionNotJustScheduling()
    await testMetalFramePresenterDrawsBurstedFramesOnSuccessiveRefreshes()
    await testMetalFramePresenterRenderTests()
    await testMetalFramePresenterCountsADrawThatShowedNothing()
    testViewerIdentityFailureCopyReadsAsASentence()
    await testViewerIdentityRecoveryTests()
    await testViewerIdentityFailureButtonsTests()
    await testClipboardSharingMenuTests()
    await testViewerMainMenuUnregisterTests()
    testViewerMainMenuStandardMenusTests()
    testViewerMainMenuMatchesSharedModelTests()
    testViewerMainMenuUpdateItemsTests()
    testViewerMainMenuFullScreenItemTests()
    testViewerMainMenuWindowStateWiringTests()
    testViewerApplicationDelegateTests()
    testViewerApplicationDelegateTerminateTests()
    testShortcutStripTests()
    testShortcutStripVisibilityTests()
    testShortcutStripPinTests()
    testShortcutStripPinSurvivesReconnectTests()
    testShortcutStripHandleTests()
    testShortcutStripHandleStaysCenteredWhenNarrow()
    testShortcutStripButtonAppearanceTests()
    testShortcutStripMetricsTests()
    testShortcutStripPinButtonAppearanceTests()
    testShortcutStripConfirmationOrderAndDefaultTests()
    testShortcutStripIconsSitOnTheirButtonCentreTests()
    testShortcutStripClusterPillsContrastWithTheBarTests()
    testShortcutStripAccessibilityLabelsTests()
    testShortcutStripSymbolsTests()
    testShortcutStripGlyphCoverageTests()
    testShortcutStripGlyphCentroidTests()
    testCanvasChromeClickPolicyTests()
    await testCanvasSurfaceChromeClickTests()
    await testCanvasSurfaceOtherButtonTests()
    await testCanvasSurfaceCapsLockTests()
    await testCanvasSurfaceEditKeyPassthroughTests()
    await testCanvasSurfaceViewerInputTests()
    await testCanvasSurfaceInputOrderTests()
    await testShortcutStripSendsWholeChordsTests()
    await testYourMachinesWindowTests()
    testYourMachinesWindowMoreButtonAccessibilityLabelTests()
    testYourMachinesRowDetailLinesShareOneLeftEdgeTests()
    testYourMachinesMoreButtonEllipsisIsCentredTests()
    testYourMachinesPickerAndListShareTheAddressFontTests()
    testYourMachinesAddStepLinkTitlesShareOneLeftEdgeTests()
    await testYourMachinesCodeFieldIsNotSelectedAfterAFailedPairingTests()
    await testYourMachinesPairingMessageHeadlineAndDetailSitTogetherTests()
    testYourMachinesWindowUpdateLineTests()
    testViewerFormActionButtonPaddingTests()
    testYourMachinesCodeStepFieldsSitOnTheColumnTests()
    testViewerFormControlsButtonFontSizeTests()
    testViewerPairingFieldCellCenteringTests()
    testViewerPairingFieldPlaceholderStaysPutWhileEditingTests()
    testViewerPairingFieldSelectionColoursTests()
    testViewerPairingFieldAccessibilityPlaceholderTests()
    testViewerPairingFieldPlaceholderSurvivesTeardownTests()
    testViewerPairingFieldObserverLifetimeTests()
    runSessionHUDSparklineAndAddressTests()
    testSessionHUDViewMatchesRowLayoutTests()
    testSessionHUDLatencyGroupsShareTheValueGridTests()
    testAboutPanelCreditTests()
    testViewerNewKeyAlertTests()
    await testHostScreenUnlockClientTests()
    testViewerLaunchRouteTests()
    do {
        try testViewerUpdateSelfTestTests()
    } catch {
        expect(false, "the self-test fixture could not be written: \(error)")
    }
    testViewerUpdatePreferencesTests()
    testViewerUpdateLineTests()
    await testViewerUpdaterAutomaticPreferenceTests()
    await testViewerUpdaterRestartNowTests()
    await testViewerUpdaterInstallAtQuitTests()
    await testViewerUpdaterHeldBackRetryTests()
    await testViewerUpdaterQuitThroughAppKitTests()
    await testViewerUpdaterQuitDuringRestartNowTests()
    await testViewerUpdaterManualCheckTests()
    await testViewerUpdaterNotUpdatableTests()
    await testViewerUpdaterReportsReadyOnceTests()
    testViewerUpdaterInertWithoutVersionTests()
}
#else
/// Nothing to run where those frameworks do not exist.
@MainActor
func runDarwinClientTests() async {}
#endif
