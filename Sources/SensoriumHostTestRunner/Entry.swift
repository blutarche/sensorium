import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
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
/// - `runHostScreenPresenceWaitingTests` and `runHostScreenPresencePromptTests`
///   must run last, after every group that ever suspends on a genuine
///   wall-clock `Task.sleep`. Both put a real window on the window server, after
///   which this runner's own async `main()` task is never seen finishing by the
///   Swift concurrency runtime, so the next real `Task.sleep` anywhere in the
///   process never resumes -- the process exits (code 0, no crash, no `FAIL`
///   line) mid-sleep instead, silently discarding every group still to come.
///
/// `HostRunnerCompletionGuard` below exists because that failure mode is
/// exactly the shape a naive "did it exit non-zero" check cannot see.
@main
@MainActor
struct SensoriumHostTestRunner {
    static func main() async {
        let coreFixtures = CoreSessionSharedFixtures()
        let groups: [() async -> Void] = [
            { await runLifecycleAndGateTests() },
            { await runCoreSessionTestsPart1(coreFixtures) },
            { await runCoreSessionTestsPart2(coreFixtures) },
            { await runCoreSessionTestsPart3(coreFixtures) },
            { await runCoreSessionTestsPart4(coreFixtures) },
            { await runLauncherDesignAndOperatorTests() },
            { await runCanvasLauncherEmptyStateWrapTests() },
            { await runCanvasLauncherHostNameTests() },
            { await runHostWorkspaceKeyboardHintTests() },
            { await runHostWorkspaceEditorTextOriginTests() },
            { await runHostCapabilityAndSettingsTests() },
            { runHostPrivateDesktopSettingTests() },
            { runHostPrivateDesktopRefusalTests() },
            { await runCanvasReleaseAccountingTests() },
            { await runScreenCaptureCanvasMediaRetryTests() },
            { await runScreenCaptureCanvasMediaStopSignalTests() },
            { await runCanvasCaptureStopTests() },
            { await runHostScreenArmingTests() },
            { await runHostScreenArmingUnreadableFileTests() },
            { await runPairingSignatureRequirementTests() },
            { await runHelloChannelBindingHostTests() },
            { await runHostScreenDeclineIsFinalTests() },
            { await runHostScreenSelectionGuardTests() },
            { await runHostScreenPresenceRuleTests() },
            { await runHostLocalActivitySignalTests() },
            { await runHostScreenPresenceGateTests() },
            { await runHostScreenSessionControllerPlaceholderTests() },
            { await runHostScreenSessionControllerAdmissionTests() },
            { await runHostScreenResumeTicketStoreTests() },
            { runHostScreenUnlockThrottleTests() },
            { await runHostScreenResumeTicketControllerTests() },
            { await runStreamScalePreferenceHostTests() },
            { await runHostScreenModeTests() },
            { await runHostScreenCoordinatorTests() },
            { await runLockScreenUnlockTests() },
            { await runHostScreenUnlockCoordinatorTests() },
            { await runHostScreenLockWatcherTests() },
            { runHostScreenRelockTrackerTests() },
            { runHostScreenRelockPosterTests() },
            { runHostAutoLoginLockAtStartTests() },
            { runHostAutoLoginDefaultRegistrationTests() },
            { runSelfPostDiscountingLocalActivitySignalTests() },
            { runMutableHostInjectedHIDActivityTests() },
            { await runHostScreenRelockWiringTests() },
            { await runHostScreenLiveSessionTests() },
            { await runHostScreenModeCoordinatorTests() },
            { await runHostScreenModeAccountabilityTests() },
            { await runHostScreenFidelityTests() },
            { await runHostScreenViewerGeometryTests() },
            { await runHostScreenMixedSessionTests() },
            { await runDisplayCountTests() },
            { await runHostScreenIndicationTests() },
            { await runHostScreenProductionWiringTests() },
            { await runHostScreenOfferOnHelloTests() },
            { await runPairingCodeRevealTests() },
            { await runHostSetupTailscaleButtonTests() },
            { await runHostIdentityFailureTests() },
            { runHostIdentityReplacementTests() },
            { await runHostSetupPermissionButtonCaseTests() },
            { await runHostAutoLoginSwitchTests() },
            { runHostPrivateDesktopSwitchTests() },
            { await runHostSetupRevealButtonTests() },
            { await runHostSetupStopButtonTests() },
            { await runHostConnectionAndPairingTests() },
            { await runHostSetupPairingCodeViewTests() },
            { await runHostSetupPairingCountdownTickTests() },
            { await runHostMenuBarStopMenuItemTests() },
            { await runHostMenuBarAboutMenuItemTests() },
            { await runHostMenuBarPairingCardFaceTests() },
            { await runHostMenuBarTitleCaseTests() },
            { await runPairedMachinesSharingToggleTests() },
            { await runPairedMachinesCardInsetTests() },
            { await runFakeHostByteChannelTests() },
            { await runCaptureCursorPolicyTests() },
            { await runStreamFidelityLeverTests() },
            { await runScreenChangeAdmissionTests() },
            { await runSentByteAccountingTests() },
            { await runStillRefreshTests() },
            { await runStillRefreshTransportTests() },
            { await runStillRefreshEncodeMeasurementTests() },
            { await runStreamFidelityCoordinatorTests() },
            { await runInputRoundTripTests() },
            { await runHostScreenKeyInputTests() },
            { await runSystemHotkeyChordTests() },
            { await runLockScreenInputTapTests() },
            { await runViewerTelemetryReceiptTests() },
            { await runOnlineDisplayLeakDetectionTests() },
            { await runDisplayWakeTests() },
            { await runHostScreenCaptureRecoveryTests() },
            { await runCaptureUnavailableTests() },
            { await runHostStopIsFinalTests() },
            { await runHostViewerSilenceWatchdogTests() },
            // Kept last -- see the file-level comment above.
            { await runHostScreenPresenceWaitingTests() },
            { await runHostScreenPresencePromptTests() },
        ]

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
        fflush(stdout)
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
