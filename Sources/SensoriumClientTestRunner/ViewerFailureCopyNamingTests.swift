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
        pairing.detail == "Have Sensorium Host show the six digits on that machine first.",
        "the pairing hint names the six digits the host shows, as the code field's hint does, got \"\(pairing.detail)\""
    )

    let awkward = "west-annex studio"
    let heldAwkward = ViewerCopyWrapping.name(awkward)
    expect(
        heldAwkward == "west\u{2011}annex\u{00A0}studio",
        "a name with a hyphen and a space is held at both, got \"\(heldAwkward)\""
    )
    let pairingOutcomes: [ViewerPairingOutcome] = [
        "invalid-code", "code-expired", "code-already-consumed", "code-attempts-exhausted", "no-active-code",
        "invalid-request", "a-reason-from-a-newer-host"
    ].map { .refused(reason: $0) } + [.unreachable, .unverifiedHost, .unexpectedReply, .unknown]
    for outcome in pairingOutcomes {
        let copy = ViewerPairingFailureCopy.copy(for: outcome, hostLabel: awkward)
        let lines = [copy.headline, copy.detail]
        expect(
            lines.allSatisfy { !$0.contains(awkward) },
            "\(outcome) never carries the machine's own breakable name, got \(lines)"
        )
        expect(
            lines.contains { $0.contains(heldAwkward) },
            "\(outcome) names the machine, held whole, got \(lines)"
        )
    }

    print("PASS: failure copy holds the machine's name, names a private desktop one way and quotes the host's labels")
}
