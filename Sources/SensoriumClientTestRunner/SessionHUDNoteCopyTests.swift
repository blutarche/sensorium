import Foundation
import SensoriumClient
import SensoriumCore

private func hudRows(
    hostName: String?,
    availability: SurfaceTelemetryAvailability = .unavailable,
    decoder: DecoderHardwareAccelerationStatus? = nil,
    softwareDecodeGuide: String? = nil,
    isPointerCaptured: Bool = false
) -> [SessionHUDRow] {
    let snapshot = SessionHUDSnapshot(
        surfaceID: 1,
        availability: availability,
        clientMetrics: SessionMetrics(),
        stream: ClientStreamReading(pixelWidth: 1920, pixelHeight: 1080, bitsPerSecond: nil, decodedFrameCount: 0),
        requestedStreamScale: nil,
        streamScalePreference: .automatic,
        decoder: decoder,
        isPointerCaptured: isPointerCaptured,
        hostName: hostName,
        softwareDecodeGuide: softwareDecodeGuide
    )
    return SessionHUDPanel.sections(telemetry: snapshot, session: nil).flatMap(\.rows)
}

/// The notes under the SESSION and DECODER rows say what the person can do or
/// what is wrong, in the same words on both platforms.
func testSessionHUDNoteCopyTests() {
    let heldName = ViewerCopyWrapping.name("west-annex studio")
    let namedReadings = hudRows(hostName: "west-annex studio").first { $0.label == "READINGS" }
    expect(
        namedReadings?.note?.hasPrefix(heldName + " has sent no measurements.") == true,
        "the readings note holds the host name whole, got \(String(describing: namedReadings?.note))"
    )

    // The plain release is the pointer-capture toggle; the escape gesture also
    // hides the app, leaves full screen and minimises, so it is not named here.
    #if os(macOS)
    let captureChord = "Control-Option-Command-G"
    #else
    let captureChord = "Ctrl-Alt-Super-G"
    #endif
    let captured = hudRows(hostName: "Workstation", isPointerCaptured: true).first { $0.label == "POINTER" }
    expect(
        captured?.note.map(unbound) == "\(captureChord) releases it back to this machine.",
        "a captured pointer names the capture toggle as the way out, got \(String(describing: captured?.note))"
    )
    let free = hudRows(hostName: "Workstation").first { $0.label == "POINTER" }
    expect(free?.note == nil, "a free pointer needs no note")

    // One note whichever path, so the two platforms read alike.
    let softwareNote = "Video is decoded in software, which uses more power."
    let withGuide = hudRows(
        hostName: "Workstation", decoder: .softwareFallback, softwareDecodeGuide: "https://example.com/guide"
    ).first { $0.label == "DECODER" }
    let withoutGuide = hudRows(
        hostName: "Workstation", decoder: .softwareFallback, softwareDecodeGuide: nil
    ).first { $0.label == "DECODER" }
    expect(
        withGuide?.note.map(unbound) == softwareNote,
        "software decoding says what it costs where a guide exists, got \(String(describing: withGuide?.note))"
    )
    expect(
        withoutGuide?.note.map(unbound) == softwareNote,
        "and says the same where none does, got \(String(describing: withoutGuide?.note))"
    )
    expect(
        withGuide?.link?.title == "Faster video" && withoutGuide?.link == nil,
        "the Faster video link stays only where a guide exists"
    )

    // The note opens a sentence, so the host's name leads it as given and the
    // fallback for a host nobody has named yet takes a capital.
    let named = hudRows(hostName: "Workstation").first { $0.label == "READINGS" }
    expect(
        named?.note.map(unbound) == "Workstation has sent no measurements. It may predate them.",
        "the readings note names the host, got \(String(describing: named?.note))"
    )
    let unnamed = hudRows(hostName: nil).first { $0.label == "READINGS" }
    expect(
        unnamed?.note.map(unbound) == "The host has sent no measurements. It may predate them.",
        "and capitalises the fallback at the start of the sentence, got \(String(describing: unnamed?.note))"
    )

    print("PASS: the HUD notes name the right way out, the cost of software decoding and the host")
}
