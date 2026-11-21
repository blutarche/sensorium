#if os(Linux)
import Foundation
import SensoriumHost
import SensoriumLinuxHost

@MainActor
private func testCaptureIsGrantedOnlyWhileTheLaunchPortalSessionIsOpen() async {
    let state = PortalGrantState()
    let gate = ScreenCapturePermissionGate(checker: PortalCapturePermissionChecker(grantState: state))
    expect(gate.currentStatus == .approvalRequired, "before the portal session opens, capture is not granted")

    state.install(grant: liveGrant(streams: []), sink: RecordingSink())
    expect(gate.currentStatus == .approvalRequired, "a grant with no monitor grants no capture")

    state.install(grant: liveGrant(), sink: RecordingSink())
    expect(gate.currentStatus == .granted, "an open session with a monitor grants capture")

    state.end()
    expect(gate.currentStatus == .approvalRequired, "once the portal session ends, capture is not granted")
}

@MainActor
private func testAskingForApprovalOpensNoDialog() async {
    let state = PortalGrantState()
    let gate = ScreenCapturePermissionGate(checker: PortalCapturePermissionChecker(grantState: state))
    expect(gate.requestApproval() == .approvalRequired, "asking reads the grant; only the host window asks the portal again")
    expect(state.live == nil, "asking opened no portal session")
}

func portalCapturePermissionTests() -> [NamedTest] { [
    ("capture is granted only while the launch portal session is open", testCaptureIsGrantedOnlyWhileTheLaunchPortalSessionIsOpen),
    ("asking for capture approval opens no dialog", testAskingForApprovalOpensNoDialog)
] }
#endif
