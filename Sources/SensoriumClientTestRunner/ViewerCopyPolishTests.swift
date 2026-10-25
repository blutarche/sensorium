import Foundation
import SensoriumClient
import SensoriumCore

/// A line that quotes a token this build does not know may break right after
/// the colon that introduces it; the token itself, quotes and hyphens, never
/// splits.
func testViewerQuotedReasonBreaksAfterTheColonTests() {
    let reason = "a-reason-this-build-has-never-seen"
    let lines = [
        "host screen": HostScreenRefusalCopy.line(reason: reason, hostLabel: "Workstation"),
        "host screen resolution": HostScreenRefusalCopy.modeRefusalLine(reason: reason, hostLabel: "Workstation"),
        "private desktop count": DisplayCountRefusalCopy.line(reason: reason, hostLabel: "Workstation"),
        "private desktop request": ViewerSessionFailureCopy.line(
            for: .canvasRefused(reason: reason), hostLabel: "Workstation"
        )
    ]
    for (name, line) in lines {
        guard let colon = line.range(of: "know:") else {
            expect(false, "the \(name) line introduces the token with a colon, got \"\(line)\"")
            continue
        }
        let after = line[colon.upperBound...]
        expect(
            after.hasPrefix(" \u{201C}"),
            "the \(name) line may break between the colon and the token: an ordinary space, got \"\(line)\""
        )
        guard let close = after.firstIndex(of: "\u{201D}") else {
            expect(false, "the \(name) line closes the quote, got \"\(line)\"")
            continue
        }
        let reasonText = after[after.index(after.startIndex, offsetBy: 2)..<close]
        expect(
            !reasonText.contains(" ") && !reasonText.contains("-"),
            "the \(name) line keeps the token whole, got \"\(reasonText)\""
        )
    }

    print("PASS: a quoted unknown reason may start a new line, and never splits")
}

/// Every refusal names the machine the way its siblings do.
func testViewerRefusalsNameTheMachineTests() {
    expect(
        HostScreenRefusalCopy.line(
            reason: HostScreenRefusalCopy.noneAvailableReason, hostLabel: "Workstation"
        ) == "Workstation has no screen to share right now. Trying again asks for its screen once more.",
        "an empty offer names the machine, got "
            + HostScreenRefusalCopy.line(reason: HostScreenRefusalCopy.noneAvailableReason, hostLabel: "Workstation")
    )
    expect(
        HostScreenRefusalCopy.line(reason: HostScreenRefusalCopy.noneAvailableReason)
            == "That machine has no screen to share right now. Trying again asks for its screen once more.",
        "and says \"That machine\" where the caller has no name for it"
    )

    let label = "Kestrel Laptop"
    let unreachable = ViewerSessionFailureCopy.line(for: .unreachable, hostLabel: label)
    expect(
        unbound(unreachable).contains("Check that Kestrel Laptop is awake"),
        "an unreachable machine's body names the machine to check, got \"\(unreachable)\""
    )
    expect(
        !unreachable.contains("other machine"),
        "and never calls it \"the other machine\" when it has the name, got \"\(unreachable)\""
    )

    print("PASS: refusals name the machine they are about")
}

/// A straight apostrophe inside a word is a typewriter mark; the viewer's
/// words use the typographic one.
func testViewerCopyUsesTypographicApostrophesTests() {
    func straight(_ text: String) -> Bool {
        let characters = Array(text)
        return characters.indices.dropFirst().dropLast().contains { index in
            characters[index] == "'" && characters[index - 1].isLetter && characters[index + 1].isLetter
        }
    }
    var checked: [(String, String)] = []
    for reason in [FidelityLimitReason.encoder, FidelityLimitReason.link, FidelityLimitReason.viewer] {
        let sample = SurfaceTelemetrySample(
            surfaceID: 0,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: 29.8,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0,
            appliedStreamScale: 1.5,
            sustainableScaleCeiling: 1.5,
            appliedFramesPerSecond: 30,
            qualityScale: 0.75,
            fidelityLimitReason: reason
        )
        let sections = SessionHUDPanel.sections(
            telemetry: SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(sample),
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Workstation"
            ),
            session: nil
        )
        for row in sections.flatMap(\.rows) {
            checked.append(("the \(reason) HUD row \(row.label) value", row.value))
            checked.append(("the \(reason) HUD row \(row.label) note", row.note ?? ""))
        }
    }
    for line in ClientShortcutPermissionReport.lines(
        mode: .remoteWhenFocused, accessibilityGranted: false, usesAccessibility: true
    ) {
        checked.append(("the shortcut report", line))
    }
    for (name, text) in checked {
        expect(!straight(text), "\(name) has a straight apostrophe inside a word, got \"\(text)\"")
    }
    expect(
        checked.contains { $0.1.contains("Workstation\u{2019}s encoder") },
        "the encoder limit names whose encoder it is with the typographic apostrophe"
    )

    print("PASS: the viewer's own words use typographic apostrophes")
}

/// A HUD note that wraps never leaves a lone word on its last line, whichever
/// platform draws it: the binding is in the text itself.
func testSessionHUDNotesKeepTheirTailTogetherTests() {
    let sample = SurfaceTelemetrySample(
        surfaceID: 0,
        capture: nil,
        encode: nil,
        send: nil,
        framesPerSecond: 29.8,
        encoderInputDropped: 0,
        globalAdmissionDropped: 0,
        sendQueueDropped: 0,
        appliedStreamScale: 1.5,
        sustainableScaleCeiling: 1.5,
        appliedFramesPerSecond: 30,
        qualityScale: 0.75,
        fidelityLimitReason: FidelityLimitReason.link
    )
    let sections = SessionHUDPanel.sections(
        telemetry: SessionHUDSnapshot(
            surfaceID: 0,
            availability: .fresh(sample),
            clientMetrics: SessionMetrics(),
            stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
            requestedStreamScale: 2.0,
            streamScalePreference: .automatic,
            decoder: .hardwareAccelerated,
            hostName: "Workstation"
        ),
        session: nil
    )
    let notes = sections.flatMap(\.rows).compactMap(\.note)
    expect(!notes.isEmpty, "the panel carries notes to check")
    for note in notes {
        expect(
            note == ViewerCopyWrapping.keepingTailTogether(note),
            "a row's note keeps its closing words together, got \"\(note)\""
        )
    }
    let link = notes.first { unbound($0).contains("link capacity") }
    expect(
        link?.hasSuffix("by\u{00A0}both\u{00A0}machines.") == true,
        "the link note never ends on \"machines.\" alone, got \(link ?? "nil")"
    )

    let section = SessionHUDSection(title: "TEST", note: "Nothing arrived from the host for a while.", rows: [])
    expect(
        section.note == "Nothing arrived from the host\u{00A0}for\u{00A0}a\u{00A0}while.",
        "a section's note keeps its closing words together too, got \(section.note ?? "nil")"
    )

    print("PASS: HUD notes keep their closing words together")
}
