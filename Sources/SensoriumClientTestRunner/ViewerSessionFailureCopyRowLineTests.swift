import Foundation
import SensoriumClient
import SensoriumCore

/// `rowLine(for:hostLabel:)` is the `Your machines` row's own short
/// fragment -- never the status panel's long explanation, which
/// `line(for:hostLabel:)` still carries unchanged.
func testViewerSessionFailureCopyRowLineTests() {
    expect(
        ViewerSessionFailureCopy.rowLine(for: .unreachable, hostLabel: "Mac mini") == "no answer",
        "an unreachable host says only that nothing answered, got "
            + ViewerSessionFailureCopy.rowLine(for: .unreachable, hostLabel: "Mac mini")
    )
    expect(
        ViewerSessionFailureCopy.rowLine(for: .unverifiedHost, hostLabel: "Mac mini")
            == "answered with a key other than the one saved at pairing; check it at the machine "
                + "before pairing again",
        "an unverified host names the mismatch in one short fragment, got "
            + ViewerSessionFailureCopy.rowLine(for: .unverifiedHost, hostLabel: "Mac mini")
    )
    expect(
        ViewerSessionFailureCopy.rowLine(
            for: .canvasRefused(reason: CanvasRefusalReason.canvasUnavailable), hostLabel: "Mac mini"
        ) == "could not open a session canvas; quit and reopen Sensorium Host there",
        "a canvas the host could not open at all says so plainly, got "
            + ViewerSessionFailureCopy.rowLine(
                for: .canvasRefused(reason: CanvasRefusalReason.canvasUnavailable), hostLabel: "Mac mini"
            )
    )
    expect(
        ViewerSessionFailureCopy.rowLine(for: .unknown, hostLabel: "Mac mini") == "stopped; reason unknown",
        "an unclassified ending says plainly that the reason is unknown, got "
            + ViewerSessionFailureCopy.rowLine(for: .unknown, hostLabel: "Mac mini")
    )

    print("PASS: the Your machines row reads a short fragment per failure, never the status panel's long line")
}
