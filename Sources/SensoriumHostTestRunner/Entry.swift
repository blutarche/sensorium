#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreMedia)
import CoreMedia
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
import SensoriumCore
import SensoriumHost

/// Entry point only. Every assertion lives in another file in this target,
/// so no single file's type-checking cost is unbounded -- see docs/testing.md.
/// `CoreSessionTestsPart1-4` share one `CoreSessionSharedFixtures` box because
/// most of the suite reuses the same naked top-level fixtures throughout.
///
/// Order matters and is preserved exactly:
///
/// - `runLifecycleAndGateTests` must run first, `expectRunLoopPumpCanDispatchQueuedWork`
///   explains why.
/// - `runHostCapsLockRealTextFieldTests`, `runHostScreenPresenceWaitingTests`
///   and `runHostScreenPresencePromptTests` must run last, after every group
///   that ever suspends on a genuine wall-clock `Task.sleep`. All three put a
///   real window on the window server, after which this runner's own async
///   `main()` task is never seen finishing by the Swift concurrency runtime,
///   so the next real `Task.sleep` anywhere in the process never resumes --
///   the process exits (code 0, no crash, no `FAIL` line) mid-sleep instead,
///   silently discarding every group still to come.
///
/// `HostRunnerCompletionGuard` below exists because that failure mode is
/// exactly the shape a naive "did it exit non-zero" check cannot see.
@main
@MainActor
struct SensoriumHostTestRunner {
    static func main() async {
        let coreFixtures = CoreSessionSharedFixtures()
        var groups: [() async -> Void] = []
        groups.append { await runLifecycleAndGateTests() }
        groups.append { await runCoreSessionTestsPart1(coreFixtures) }
        groups.append { await runCoreSessionTestsPart2(coreFixtures) }
        groups.append { await runCoreSessionTestsPart3(coreFixtures) }
        groups.append { await runCoreSessionTestsPart4(coreFixtures) }
        #if os(macOS)
        groups.append { await runLauncherDesignAndOperatorTests() }
        groups.append { await runCanvasDesignAppearanceTests() }
        groups.append { await runCanvasLauncherEmptyStateWrapTests() }
        groups.append { await runCanvasLauncherHostNameTests() }
        groups.append { await runHostWorkspaceKeyboardHintTests() }
        groups.append { await runHostWorkspaceEditorTextOriginTests() }
        groups.append { await runHostWorkspaceEditorContentTests() }
        groups.append { await runHostCapabilityAndSettingsTests() }
        groups.append { runHostPrivateDesktopSettingTests() }
        groups.append { runHostPrivateDesktopRefusalTests() }
        groups.append { runHostPrivateDesktopProbeFailureTests() }
        groups.append { runHostLocalNetworkSettingTests() }
        groups.append { runHostLocalNetworkConnectionRegistryTests() }
        groups.append { await runCanvasReleaseAccountingTests() }
        groups.append { await runScreenCaptureCanvasMediaRetryTests() }
        groups.append { await runHostScreenCaptureMediaRetryTests() }
        groups.append { await runScreenCaptureCanvasMediaStopSignalTests() }
        #endif
        groups.append { await runCanvasCaptureStopTests() }
        groups.append { await runHostScreenArmingTests() }
        groups.append { await runHostScreenGateEnforcementTests() }
        groups.append { await runHostScreenArmingUnreadableFileTests() }
        groups.append { await runPairingSignatureRequirementTests() }
        groups.append { await runHelloChannelBindingHostTests() }
        groups.append { await runHostScreenDeclineIsFinalTests() }
        groups.append { await runHostScreenSelectionGuardTests() }
        #if os(macOS)
        groups.append { await runSharpScreenTests() }
        groups.append { await runSharpScreenManagerTests() }
        groups.append { await runSharpScreenSessionTests() }
        #endif
        groups.append { await runHostScreenPresenceRuleTests() }
        #if os(macOS)
        groups.append { await runHostLocalActivitySignalTests() }
        #endif
        groups.append { await runHostScreenPresenceGateTests() }
        groups.append { await runHostScreenSessionControllerPlaceholderTests() }
        groups.append { await runHostScreenSessionControllerAdmissionTests() }
        groups.append { await runHostScreenResumeTicketStoreTests() }
        groups.append { runHostScreenUnlockThrottleTests() }
        groups.append { await runHostScreenResumeTicketControllerTests() }
        groups.append { await runStreamScalePreferenceHostTests() }
        groups.append { await runHostScreenModeTests() }
        groups.append { await runHostScreenCoordinatorTests() }
        #if os(macOS)
        groups.append { await runLockScreenUnlockTests() }
        #endif
        groups.append { await runHostScreenUnlockCoordinatorTests() }
        groups.append { await runHostScreenLockWatcherTests() }
        groups.append { runHostScreenRelockTrackerTests() }
        #if os(macOS)
        groups.append { runHostScreenRelockPosterTests() }
        #endif
        groups.append { runHostAutoLoginLockAtStartTests() }
        groups.append { runHostAutoLoginDefaultRegistrationTests() }
        groups.append { runSelfPostDiscountingLocalActivitySignalTests() }
        groups.append { runMutableHostInjectedHIDActivityTests() }
        #if os(macOS)
        groups.append { await runHostScreenRelockWiringTests() }
        #endif
        groups.append { await runHostScreenLiveSessionTests() }
        groups.append { await runInputGrantWithoutRelaunchTests() }
        groups.append { await runHostScreenModeCoordinatorTests() }
        groups.append { await runHostScreenModeAccountabilityTests() }
        groups.append { await runHostScreenFidelityTests() }
        groups.append { await runHostScreenViewerGeometryTests() }
        groups.append { await runHostScreenDrawableCoalescingTests() }
        groups.append { await runHostScreenMixedSessionTests() }
        groups.append { await runDisplayCountTests() }
        #if os(macOS)
        groups.append { await runHostScreenIndicationTests() }
        #endif
        groups.append { await runHostScreenProductionWiringTests() }
        groups.append { await runHostScreenOfferOnHelloTests() }
        groups.append { await runPairingCodeRevealTests() }
        #if os(macOS)
        groups.append { await runHostSetupTailscaleButtonTests() }
        groups.append { await runHostIdentityFailureTests() }
        groups.append { runHostIdentityReplacementTests() }
        groups.append { await runHostSetupPermissionButtonCaseTests() }
        groups.append { await runHostAutoLoginSwitchTests() }
        groups.append { runHostPrivateDesktopSwitchTests() }
        groups.append { runHostLocalNetworkSwitchTests() }
        groups.append { await runHostSetupRevealButtonTests() }
        groups.append { await runHostSetupStopButtonTests() }
        groups.append { await runHostConnectionAndPairingTests() }
        groups.append { await runHostSetupPairingCodeViewTests() }
        groups.append { await runHostSetupPairingCountdownTickTests() }
        groups.append { await runHostSetupSectionOrderTests() }
        groups.append { await runHostSetupWindowScrollTests() }
        groups.append { await runHostStatusCardTests() }
        groups.append { await runHostTextFlowTests() }
        groups.append { await runHostPairedMachinesEmptyStateTests() }
        groups.append { await runHostMenuBarStopMenuItemTests() }
        groups.append { await runHostMenuBarSharingSubmenuTests() }
        groups.append { await runHostMenuBarAboutMenuItemTests() }
        groups.append { await runHostMenuBarAboutPanelActivationTests() }
        groups.append { await runHostMainMenuTests() }
        groups.append { await runHostMenuBarPairingCardFaceTests() }
        groups.append { await runHostMenuBarTitleCaseTests() }
        groups.append { await runHostMenuBarPingTitleColorTests() }
        groups.append { await runHostMenuBarLogoIconTests() }
        groups.append { await runHostMenuBarPanelMenuWidthTests() }
        groups.append { await runHostMenuPanelEyebrowContrastTests() }
        groups.append { await runPairedMachinesSharingToggleTests() }
        groups.append { await runPairedMachinesCardInsetTests() }
        groups.append { await runHostPairedMachineRowLayoutTests() }
        groups.append { await runPairedMachineRenameTests() }
        groups.append { await runHostRenameSheetPlacementTests() }
        groups.append { await runPairedMachinesCompactListTests() }
        #endif
        groups.append { await runApprovedDeviceStoreSafetyTests() }
        groups.append { await runFakeHostByteChannelTests() }
        groups.append { await runCaptureCursorPolicyTests() }
        #if os(macOS)
        groups.append { await runCaptureStreamColorTests() }
        groups.append { await runHostMediaPipelineFrameSourceTests() }
        groups.append { await runEncoderStallTests() }
        groups.append { await runEncoderCreationStallTests() }
        groups.append { await runPipelineBuildFidelityTests() }
        #endif
        groups.append { await runFidelityTickOverlapTests() }
        groups.append { await runStreamFidelityLeverTests() }
        #if os(macOS)
        groups.append { await runScreenChangeAdmissionTests() }
        #endif
        groups.append { await runSentByteAccountingTests() }
        #if os(macOS)
        groups.append { await runVideoSendRecoveryTests() }
        groups.append { await runStillRefreshTests() }
        #endif
        groups.append { await runStillRefreshSendTimeTests() }
        #if os(macOS)
        groups.append { await runStillRefreshTransportTests() }
        groups.append { await runStreamEncoderFlushTests() }
        groups.append { runFrameChangeSamplerTests() }
        groups.append { await runStreamMotionEncoderTests() }
        groups.append { runStreamMotionProofTests() }
        groups.append { await runStreamMotionPipelineTests() }
        groups.append { await runStillRefreshEncodeMeasurementTests() }
        groups.append { await runBaselineEncoderHardwareTests() }
        groups.append { await runViewerDecoderPreferenceHostTests() }
        groups.append { await runViewerKeyFrameRequestHostTests() }
        groups.append { await runViewerKeyFrameIntervalTests() }
        #endif
        groups.append { await runStreamFidelityCoordinatorTests() }
        groups.append { await runInputRoundTripTests() }
        groups.append { await runHostScreenKeyInputTests() }
        #if os(macOS)
        groups.append { await runSystemHotkeyChordTests() }
        groups.append { await runLockScreenInputTapTests() }
        groups.append { await runHostScreenInputDiagnosticsTests() }
        groups.append { await runClickCountTests() }
        groups.append { await runInjectedInputFidelityTests() }
        #endif
        groups.append { await runViewerTelemetryReceiptTests() }
        groups.append { await runOnlineDisplayLeakDetectionTests() }
        #if os(macOS)
        groups.append { await runDisplayWakeTests() }
        groups.append { await runHostScreenCaptureRecoveryTests() }
        groups.append { await runCaptureUnavailableTests() }
        #endif
        groups.append { await runHostStopIsFinalTests() }
        groups.append { await runHostViewerSilenceWatchdogTests() }
        groups.append { await runHostUndecodableControlMessageTests() }
        #if os(macOS)
        groups.append { await runHostCapsLockTests() }
        groups.append { runHostScrollLineTests() }
        #endif
        groups.append { await runHostConnectionDeadlineTests() }
        groups.append { await runHostPingDisplayTests() }
        groups.append { await runHostOperatorStatusPingTests() }
        groups.append { runHostListenerRecoveryPolicyTests() }
        #if os(macOS)
        groups.append { runHostLocalNetworkAdmissionTests() }
        groups.append { runHostLocalNetworkListenerParameterTests() }
        groups.append { runHostLocalSubnetInterfaceFilterTests() }
        groups.append { runHostUnscopedListenerEventTests() }
        groups.append { runHostUpdateLaunchRouteTests() }
        groups.append { runHostUpdateRelaunchLockTests() }
        groups.append { runHostUpdateSelfTestTests() }
        groups.append { runHostUpdateIdleRuleTests() }
        groups.append { runHostUpdateReadyReportTests() }
        groups.append { runHostUpdateStatusLineTests() }
        groups.append { runHostUpdatePreferenceTests() }
        groups.append { runHostUpdateBundleTests() }
        groups.append { await runHostUpdaterTests() }
        groups.append { runHostUpdateLogLineTests() }
        #endif
        groups.append { runHostSessionLogLineTests() }
        #if os(macOS)
        groups.append { runHostUpdateRelaunchReporterTests() }
        groups.append { await runHostUpdateSwapBackRecoveryTests() }
        groups.append { runHostUpdateArgumentOrderTests() }
        groups.append { runHostUpdateWindowTests() }
        groups.append { runHostUpdateMenuItemTests() }
        #endif
        // Kept last -- see the file-level comment above.
        #if os(macOS)
        groups.append { runHostCapsLockRealTextFieldTests() }
        groups.append { await runHostScreenPresenceWaitingTests() }
        groups.append { await runHostScreenPresencePromptTests() }
        #endif

        HostRunnerCompletionGuard.shared.configure(totalGroups: groups.count)
        for group in groups {
            await group()
            HostRunnerCompletionGuard.shared.recordGroupCompleted()
        }
    }
}

/// Guards against the process quietly ending with exit code 0 and no `FAIL`
/// line partway through `main()`'s test groups, with every later group never
/// running -- the failure mode a plain "did it exit non-zero" check cannot see.
///
/// Installed as an `atexit` handler rather than a check at the bottom of
/// `main()`, because a `main()` that dies mid-`await` never reaches its own
/// last line either; every way this process ends runs through libc's `exit()`
/// on its way out, and `atexit` handlers are libc's own hook into that call.
final class HostRunnerCompletionGuard: @unchecked Sendable {
    static let shared = HostRunnerCompletionGuard()

    private var completedGroups = 0
    private var totalGroups = 0
    private var configured = false
    private var failureReported = false

    private init() {}

    func configure(totalGroups: Int) {
        self.totalGroups = totalGroups
        guard !configured else { return }
        configured = true
        atexit {
            HostRunnerCompletionGuard.shared.reportAtExit()
        }
    }

    func recordGroupCompleted() {
        completedGroups += 1
    }

    /// Called by `expect` before it ends the process, so the report below
    /// points at the `FAIL` line above it instead of claiming there is none.
    func recordFailureReported() {
        failureReported = true
    }

    private func reportAtExit() {
        // `_exit` below is libc's own way out without libc's stdio flush,
        // which would otherwise discard whatever is still buffered -- the
        // line that was printing when the process ended, among others.
        fflush(nil)
        guard completedGroups < totalGroups else {
            print("host runner: \(completedGroups) of \(totalGroups) test groups ran")
            return
        }
        let message: String
        if failureReported {
            message = "host runner stopped after \(completedGroups) of \(totalGroups) registered test groups "
                + "on the FAIL above\n"
        } else {
            message = "FAIL: host runner ended after \(completedGroups) of \(totalGroups) registered test groups -- "
                + "the process stopped running before every registered group reported back, with no crash and "
                + "no other FAIL line naming why\n"
        }
        FileHandle.standardError.write(Data(message.utf8))
        _exit(1)
    }
}
