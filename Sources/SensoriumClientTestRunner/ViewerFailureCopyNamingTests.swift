import Foundation
import SensoriumClient
import SensoriumCore

/// What a session failure says: the machine's name is held whole wherever it
/// sits, a private desktop is called that and nothing else, and the host's
/// switch for a host screen is quoted as the host labels it.
func testViewerFailureCopyNamingTests() {
    let label = "Kestrel Laptop"
    let held = ViewerCopyWrapping.name(label)
    let failures: [ViewerSessionFailure] = [
        .unreachable, .unverifiedHost, .canvasIdentityMismatch, .unexpectedReply, .identityMissing,
        .canvasRefused(reason: CanvasRefusalReason.creationInProgress),
        .canvasRefused(reason: CanvasRefusalReason.canvasUnavailable),
        .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered),
        .canvasRefused(reason: "a-reason-from-a-newer-host"),
        .pairingRefused(reason: "no-active-code"),
        .hostScreenRefused(reason: "host-screen-not-allowed"),
        .hostScreenRefused(reason: "host-screen-presence-declined"),
        .stoppedByHost, .hostDisplaysAsleep, .hostCaptureUnavailable, .unknown
    ]
    for failure in failures {
        let line = ViewerSessionFailureCopy.line(for: failure, hostLabel: label)
        expect(
            !line.contains(label),
            "\(failure) never carries the machine's own breakable name, got \"\(line)\""
        )
        for text in [line, ViewerSessionFailureCopy.rowLine(for: failure, hostLabel: label)] {
            expect(
                !text.localizedCaseInsensitiveContains("virtual display")
                    && !text.localizedCaseInsensitiveContains("session canvas"),
                "\(failure) calls a private desktop by its one name, got \"\(text)\""
            )
        }
    }

    let notAllowed = ViewerSessionFailureCopy.line(
        for: .hostScreenRefused(reason: "host-screen-not-allowed"), hostLabel: label
    )
    expect(
        unbound(notAllowed).hasPrefix("Kestrel Laptop has \u{201C}Share host screen\u{201D} turned off"),
        "a refused host screen names the machine that has the switch off, got \"\(notAllowed)\""
    )
    expect(
        notAllowed.hasPrefix("\(held) has"),
        "and holds its name whole at the start of the sentence, got \"\(notAllowed)\""
    )
    let row = ViewerSessionFailureCopy.rowLine(
        for: .hostScreenRefused(reason: "host-screen-not-allowed"), hostLabel: label
    )
    expect(
        !row.contains(held) && !row.contains(label),
        "a Your Machines row already shows the machine, so its fragment never repeats the name, got \"\(row)\""
    )

    let pairing = ViewerPairingFailureCopy.copy(for: .refused(reason: "no-active-code"), hostLabel: "Studio")
    expect(
        pairing.detail == "Press Show Pairing Code there first.",
        "the pairing hint quotes the host's button as it is labelled, got \"\(pairing.detail)\""
    )

    print("PASS: failure copy holds the machine's name, names a private desktop one way and quotes the host's labels")
}
