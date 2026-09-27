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
    testViewerIdentityFailureCopyReadsAsASentence()
    await testViewerIdentityRecoveryTests()
    await testViewerIdentityFailureButtonsTests()
    await testClipboardSharingMenuTests()
    await testViewerMainMenuUnregisterTests()
    testViewerMainMenuStandardMenusTests()
    testViewerMainMenuFullScreenItemTests()
    testViewerMainMenuWindowStateWiringTests()
    testViewerApplicationDelegateTests()
    testShortcutStripTests()
    testShortcutStripVisibilityTests()
    testShortcutStripPinTests()
    testShortcutStripPinSurvivesReconnectTests()
    testShortcutStripHandleTests()
    testShortcutStripHandleStaysCenteredWhenNarrow()
    testShortcutStripButtonAppearanceTests()
    testShortcutStripMetricsTests()
    testShortcutStripPinButtonAppearanceTests()
    testShortcutStripAccessibilityLabelsTests()
    testShortcutStripSymbolsTests()
    testCanvasChromeClickPolicyTests()
    await testCanvasSurfaceChromeClickTests()
    await testCanvasSurfaceEditKeyPassthroughTests()
    await testShortcutStripSendsWholeChordsTests()
    await testYourMachinesWindowTests()
    testYourMachinesWindowMoreButtonAccessibilityLabelTests()
    testViewerFormActionButtonPaddingTests()
    testViewerFormControlsButtonFontSizeTests()
    testViewerPairingFieldCellCenteringTests()
    testViewerPairingFieldPlaceholderStaysPutWhileEditingTests()
    testViewerPairingFieldSelectionColoursTests()
    testViewerPairingFieldAccessibilityPlaceholderTests()
    testViewerPairingFieldPlaceholderSurvivesTeardownTests()
    testViewerPairingFieldObserverLifetimeTests()
    runSessionHUDSparklineAndAddressTests()
    testAboutPanelCreditTests()
    await testHostScreenUnlockClientTests()
}
#else
/// Nothing to run where those frameworks do not exist.
@MainActor
func runDarwinClientTests() async {}
#endif
