import Foundation
import SensoriumClient
import SensoriumCore

/// What the viewer measures about its own end of the wire, and what the panel
/// says once the host reports what it applied and why.
func runViewerTelemetryAndFidelityHUDTests() {
    viewerTelemetryBuilderReportsOnlyWhatWasMeasured()
    fidelitySectionNamesTheFrameRateQualityAndReason()
    streamSectionNamesTheFramesThisViewerGaveUp()
    latencySectionNamesTheHoldThisMachineAdded()
    heldBackSentenceNamesNoStageWithoutACeilingOrAClampedChoice()
    heldBackSentenceNamesBothMachinesNumbersWhenTheHostsEchoDisagrees()
    print("PASS: the viewer reports its own stages and the panel names what is holding fidelity back")
}

/// Field evidence: a host-screen session whose applied scale was held below
/// what the viewer's own geometry asked for by nothing the host ever
/// measured -- no `sustainableScaleCeiling`, no `clampedFromUserChoice` --
/// yet still carried a `fidelityLimitReason` naming a stage. That stage was
/// not why the scale differed: naming it anyway told a person their host's
/// encoder could not keep up with a request the host had, in fact, never
/// been told to try.
private func heldBackSentenceNamesNoStageWithoutACeilingOrAClampedChoice() {
    func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
        sections.flatMap(\.rows).first { $0.label == label }
    }

    let unmeasured = SurfaceTelemetrySample(
        surfaceID: 0,
        capture: nil,
        encode: nil,
        send: nil,
        framesPerSecond: 29.8,
        encoderInputDropped: 0,
        globalAdmissionDropped: 0,
        sendQueueDropped: 0,
        appliedStreamScale: 1.5,
        sustainableScaleCeiling: nil,
        clampedFromUserChoice: nil,
        appliedFramesPerSecond: 30,
        qualityScale: 1.0,
        fidelityLimitReason: FidelityLimitReason.encoder
    )
    let sections = SessionHUDPanel.sections(
        telemetry: SessionHUDSnapshot(
            surfaceID: 0,
            availability: .fresh(unmeasured),
            clientMetrics: SessionMetrics(),
            stream: ClientStreamReading(pixelWidth: 3072, pixelHeight: 1728, bitsPerSecond: 8_000_000),
            requestedStreamScale: 1.75,
            streamScalePreference: .automatic,
            decoder: .hardwareAccelerated,
            hostName: "Studio"
        ),
        session: nil
    )
    expect(
        hudRow(sections, "CEILING")?.value == "not measured",
        "the ceiling this sentence would need is what the row already says is absent"
    )
    expect(
        hudRow(sections, "REQUESTED")?.note
            == "Held to 1.50x at 30 fps. Automatic asked for 1.75x, but Studio is streaming a different scale.",
        "with no measured ceiling and no clamped user choice, the sentence names no stage -- "
            + "got \(hudRow(sections, "REQUESTED")?.note ?? "nil")"
    )
}

/// The same field evidence as the sentence above, but from a host new enough
/// to echo what it derived. Nothing measured the request as unsustainable --
/// the host simply derived a different scale than this machine did from the
/// same drawable size -- so the sentence says both machines' numbers and
/// names no stage.
private func heldBackSentenceNamesBothMachinesNumbersWhenTheHostsEchoDisagrees() {
    func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
        sections.flatMap(\.rows).first { $0.label == label }
    }

    let echoed = SurfaceTelemetrySample(
        surfaceID: 0,
        capture: nil,
        encode: nil,
        send: nil,
        framesPerSecond: 29.8,
        encoderInputDropped: 0,
        globalAdmissionDropped: 0,
        sendQueueDropped: 0,
        appliedStreamScale: 1.5,
        sustainableScaleCeiling: nil,
        clampedFromUserChoice: nil,
        hostRequestedStreamScale: 1.5,
        appliedFramesPerSecond: 30,
        qualityScale: 1.0,
        fidelityLimitReason: FidelityLimitReason.encoder
    )
    let sections = SessionHUDPanel.sections(
        telemetry: SessionHUDSnapshot(
            surfaceID: 0,
            availability: .fresh(echoed),
            clientMetrics: SessionMetrics(),
            stream: ClientStreamReading(pixelWidth: 3072, pixelHeight: 1728, bitsPerSecond: 8_000_000),
            requestedStreamScale: 1.75,
            requestedDrawablePixelWidth: 3584,
            requestedDrawablePixelHeight: 2016,
            streamScalePreference: .automatic,
            decoder: .hardwareAccelerated,
            hostName: "blut-macminim4"
        ),
        session: nil
    )
    expect(
        hudRow(sections, "REQUESTED")?.value == "1.50x",
        "the row shows the host's own echoed request once it has one, got "
            + "\(hudRow(sections, "REQUESTED")?.value ?? "nil")"
    )
    expect(
        hudRow(sections, "REQUESTED")?.note
            == "Held to 1.50x at 30 fps. This machine asked for 1.75x from 3584x2016 px. "
            + "blut-macminim4 derived 1.50x.",
        "the two machines' own numbers are said, naming no stage, got "
            + "\(hudRow(sections, "REQUESTED")?.note ?? "nil")"
    )
}

/// A person watching a stream stutter needs to know which end gave the frames
/// up. The host's own dropped count cannot say: a frame the host sent and this
/// machine skipped is not dropped anywhere the host can see.
private func streamSectionNamesTheFramesThisViewerGaveUp() {
    func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
        sections.flatMap(\.rows).first { $0.label == label }
    }

    func sections(beforeDecode: Int, beforePresent: Int, grew: Bool) -> [SessionHUDSection] {
        SessionHUDPanel.sections(
            telemetry: SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Studio",
                viewerDroppedBeforeDecode: beforeDecode,
                viewerDroppedBeforePresent: beforePresent,
                viewerDropsGrew: grew
            ),
            session: nil
        )
    }

    let quiet = sections(beforeDecode: 0, beforePresent: 0, grew: false)
    expect(
        hudRow(quiet, "DROPPED HERE")?.value == "0 before decode, 0 before present",
        "the panel names both places this viewer can give a frame up, got: \(hudRow(quiet, "DROPPED HERE")?.value ?? "nil")"
    )
    expect(
        hudRow(quiet, "DROPPED HERE")?.tone == nil,
        "a viewer that has given up nothing is not marked"
    )
    expect(
        hudRow(quiet, "DROPPED")?.value == "unavailable",
        "and the host's own count is still its own, still unavailable when the host has sent none"
    )
    expect(
        hudRow(quiet, "DROPPED HERE")?.note?.contains("Studio") == true,
        "the row says whose count it is not, by the machine's own name, got: \(hudRow(quiet, "DROPPED HERE")?.note ?? "nil")"
    )

    let growing = sections(beforeDecode: 12, beforePresent: 3, grew: true)
    expect(
        hudRow(growing, "DROPPED HERE")?.value == "12 before decode, 3 before present",
        "both counts are shown as themselves, got: \(hudRow(growing, "DROPPED HERE")?.value ?? "nil")"
    )
    expect(
        hudRow(growing, "DROPPED HERE")?.tone == .warn,
        "a count still growing is the session skipping frames right now, which is worth marking"
    )
    expect(
        hudRow(sections(beforeDecode: 12, beforePresent: 3, grew: false), "DROPPED HERE")?.tone == nil,
        "a count that stopped growing describes a moment that has passed, so the panel stops marking it"
    )
}

/// The builder is the whole of what the viewer sends: a live session only
/// feeds it the numbers it already holds. Every field is a measurement, so
/// every field is absent until there is one -- a zero here would tell the
/// host the link is perfect.
private func viewerTelemetryBuilderReportsOnlyWhatWasMeasured() {
    var builder = ViewerTelemetryBuilder()
    let second: Int64 = 1_000_000_000

    let firstTick = builder.sample(
        surfaceID: 0,
        metrics: SessionMetrics(),
        stream: ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil),
        presentedFrameCount: 0,
        atNanoseconds: 10 * second
    )
    expect(
        firstTick == ViewerTelemetrySample(
            surfaceID: 0,
            endToEnd: nil,
            receive: nil,
            decode: nil,
            presentedFramesPerSecond: nil,
            decodedFramesPerSecond: nil,
            receivedBitsPerSecond: nil
        ),
        "a viewer that has measured nothing reports nothing, not a set of zeroes"
    )

    var metrics = SessionMetrics()
    for (stage, milliseconds) in [
        (SessionMetricStage.receive, 8.0),
        (.decode, 3.0),
        (.endToEnd, 21.0),
        (.inputRoundTrip, 40.0)
    ] {
        metrics.record(
            stage: stage,
            startedAtNanoseconds: 0,
            endedAtNanoseconds: Int64(milliseconds * 1_000_000)
        )
    }
    let secondTick = builder.sample(
        surfaceID: 0,
        metrics: metrics,
        stream: ClientStreamReading(
            pixelWidth: 2880,
            pixelHeight: 1800,
            bitsPerSecond: 41_800_000,
            decodedFrameCount: 60
        ),
        presentedFrameCount: 30,
        atNanoseconds: 11 * second
    )
    expect(
        secondTick.endToEnd == StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: 21_000_000)
            && secondTick.receive == StageLatencySample(p50Nanoseconds: 8_000_000, p95Nanoseconds: 8_000_000)
            && secondTick.decode == StageLatencySample(p50Nanoseconds: 3_000_000, p95Nanoseconds: 3_000_000),
        "each stage the viewer measured travels as its own p50 and p95"
    )
    expect(
        secondTick.presentedFramesPerSecond == 30 && secondTick.decodedFramesPerSecond == 60,
        "what this machine decoded and what it managed to put on screen are two numbers, not one"
    )
    expect(
        secondTick.receivedBitsPerSecond == 41_800_000,
        "the rate reported is the one this machine counted, not one derived from a scale"
    )

    // Half a second later, half as many frames: still 30 a second. A rate
    // divided by a fixed interval rather than the real one would read 15 and
    // have the host stepping fidelity down for nothing.
    let halfTick = builder.sample(
        surfaceID: 0,
        metrics: metrics,
        stream: ClientStreamReading(
            pixelWidth: 2880,
            pixelHeight: 1800,
            bitsPerSecond: 41_800_000,
            decodedFrameCount: 90
        ),
        presentedFrameCount: 45,
        atNanoseconds: 11 * second + second / 2
    )
    expect(
        halfTick.presentedFramesPerSecond == 30 && halfTick.decodedFramesPerSecond == 60,
        "both rates are measured against the real gap between ticks, not an assumed one"
    )

    // The second surface keeps its own count. Sharing one would report the
    // first canvas's frames as the second canvas's rate.
    let otherSurface = builder.sample(
        surfaceID: 1,
        metrics: metrics,
        stream: ClientStreamReading(
            pixelWidth: nil,
            pixelHeight: nil,
            bitsPerSecond: nil,
            decodedFrameCount: 900
        ),
        presentedFrameCount: 900,
        atNanoseconds: 12 * second
    )
    expect(
        otherSurface.surfaceID == 1
            && otherSurface.presentedFramesPerSecond == nil
            && otherSurface.decodedFramesPerSecond == nil,
        "a surface's first tick has no earlier tick to measure a rate against, whatever the other surface did"
    )
}

/// The panel's answer to "why does this look softer than what I asked for":
/// the frame rate and the quality step, which are the two the host reaches
/// for first when it holds the scale back.
private func fidelitySectionNamesTheFrameRateQualityAndReason() {
    func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
        sections.flatMap(\.rows).first { $0.label == label }
    }

    func sample(
        appliedStreamScale: Double?,
        appliedFramesPerSecond: Int?,
        qualityScale: Double?,
        fidelityLimitReason: String?
    ) -> SurfaceTelemetrySample {
        SurfaceTelemetrySample(
            surfaceID: 0,
            capture: nil,
            encode: nil,
            send: nil,
            framesPerSecond: 29.8,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0,
            appliedStreamScale: appliedStreamScale,
            sustainableScaleCeiling: appliedStreamScale,
            appliedFramesPerSecond: appliedFramesPerSecond,
            qualityScale: qualityScale,
            fidelityLimitReason: fidelityLimitReason
        )
    }

    func sections(_ sample: SurfaceTelemetrySample) -> [SessionHUDSection] {
        SessionHUDPanel.sections(
            telemetry: SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(sample),
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Studio"
            ),
            session: nil
        )
    }

    let limited = sections(sample(
        appliedStreamScale: 1.5,
        appliedFramesPerSecond: 30,
        qualityScale: 0.75,
        fidelityLimitReason: FidelityLimitReason.link
    ))
    expect(
        limited.contains { $0.title == "FIDELITY" } && !limited.contains { $0.title == "RESOLUTION" },
        "the section is named for everything it now reports, not for the one thing it used to"
    )
    // Neither row is a setting a person chose. Both are measured limits, and
    // the words say so on the row itself rather than leaving the number to be
    // read as somebody's preference.
    expect(
        hudRow(limited, "FRAME RATE")?.value == "limited to 30 fps",
        "a frame rate the host was forced down to says it was forced, not just what it is"
    )
    expect(
        hudRow(limited, "QUALITY")?.value == "limited to 75%",
        "a quality below full says it was limited rather than reading as a chosen level"
    )
    expect(
        hudRow(limited, "LIMITED BY")?.value == "the link",
        "the reason is said in the panel's own words, not in the wire's token"
    )
    // Neither machine can see a link on its own, so the sentence says the two of
    // them together measured it -- and names them the way the rest of the
    // panel already does, where "this machine" is the one the panel is drawn on.
    expect(
        hudRow(limited, "REQUESTED")?.note
            == "Held to 1.50x at 30 fps. Automatic asked for 2.00x, which the link cannot carry, "
                + "by what this machine and Studio measured.",
        "the sentence names the frame rate, what cannot keep up, and whose measurement says so"
    )

    for (token, words, clause) in [
        (FidelityLimitReason.encoder, "Studio's encoder", "which Studio's encoder cannot keep up with"),
        (FidelityLimitReason.viewer, "this machine", "which this machine cannot keep up with")
    ] {
        let rows = sections(sample(
            appliedStreamScale: 1.5,
            appliedFramesPerSecond: 30,
            qualityScale: 1.0,
            fidelityLimitReason: token
        ))
        expect(
            hudRow(rows, "LIMITED BY")?.value == words,
            "the \(token) limit reads as \"\(words)\""
        )
        expect(
            hudRow(rows, "REQUESTED")?.note
                == "Held to 1.50x at 30 fps. Automatic asked for 2.00x, \(clause).",
            "the \(token) limit is named in the sentence too"
        )
    }

    // The encoder belongs to whichever machine is streaming, so the row names it
    // rather than saying "this machine" on a panel where that already means the
    // machine the panel is drawn on. Before anything has said who the far machine is,
    // the panel's own generic word stands in.
    let anonymousHost = SessionHUDPanel.sections(
        telemetry: SessionHUDSnapshot(
            surfaceID: 0,
            availability: .fresh(sample(
                appliedStreamScale: 1.5,
                appliedFramesPerSecond: 30,
                qualityScale: 1.0,
                fidelityLimitReason: FidelityLimitReason.encoder
            )),
            clientMetrics: SessionMetrics(),
            stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
            requestedStreamScale: 2.0,
            streamScalePreference: .automatic,
            decoder: .hardwareAccelerated,
            hostName: nil
        ),
        session: nil
    )
    expect(
        hudRow(anonymousHost, "LIMITED BY")?.value == "the host's encoder",
        "a session that has not learned the other machine's name yet still says whose encoder it is"
    )

    // A reason this build has never heard of is shown as it arrived. Saying
    // nothing for a host that plainly did report one would be a lie this
    // viewer told to avoid admitting it is the older of the two.
    expect(
        hudRow(
            sections(sample(
                appliedStreamScale: 1.5,
                appliedFramesPerSecond: 30,
                qualityScale: 1.0,
                fidelityLimitReason: "thermal"
            )),
            "LIMITED BY"
        )?.value == "thermal",
        "a reason from a newer host is repeated rather than swallowed"
    )

    // A host that predates all three fields. Nothing may be invented for it:
    // no frame rate, no quality, and the sentence it always said, unchanged.
    let old = sections(sample(
        appliedStreamScale: 1.5,
        appliedFramesPerSecond: nil,
        qualityScale: nil,
        fidelityLimitReason: nil
    ))
    expect(
        hudRow(old, "FRAME RATE")?.value == "\u{2014}"
            && hudRow(old, "QUALITY")?.value == "\u{2014}"
            && hudRow(old, "LIMITED BY")?.value == "\u{2014}",
        "a host that predates the fields reports nothing rather than a fabricated full-quality reading"
    )
    expect(
        hudRow(old, "REQUESTED")?.note
            == "Held to 1.50x. Automatic asked for 2.00x, which Studio measured as unsustainable.",
        "the sentence a host with nothing new to say produces is exactly the one it always produced"
    )

    // Full fidelity: the rows still say what is running, and nothing claims
    // anything is being held back.
    let healthy = sections(sample(
        appliedStreamScale: 2.0,
        appliedFramesPerSecond: 60,
        qualityScale: 1.0,
        fidelityLimitReason: nil
    ))
    expect(
        hudRow(healthy, "FRAME RATE")?.value == "60 fps" && hudRow(healthy, "QUALITY")?.value == "100%",
        "a session giving nothing up says what it is running at, with no word about being limited"
    )
    expect(
        hudRow(healthy, "LIMITED BY")?.value == "\u{2014}" && hudRow(healthy, "REQUESTED")?.note == nil,
        "a host holding nothing back names no reason, and explains nothing it is not doing"
    )
}


/// The viewer holds each frame a little past its capture time so the motion
/// stays even. That is latency this machine added on purpose, so a person
/// reading the panel is shown it rather than left to find it inside the
/// end-to-end figure.
private func latencySectionNamesTheHoldThisMachineAdded() {
    func hudRow(_ sections: [SessionHUDSection], _ label: String) -> SessionHUDRow? {
        sections.flatMap(\.rows).first { $0.label == label }
    }

    func sections(hold: Int64) -> [SessionHUDSection] {
        SessionHUDPanel.sections(
            telemetry: SessionHUDSnapshot(
                surfaceID: 0,
                availability: .unavailable,
                clientMetrics: SessionMetrics(),
                stream: ClientStreamReading(pixelWidth: 2880, pixelHeight: 1800, bitsPerSecond: 8_000_000),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                presentationHoldNanoseconds: hold,
                hostName: "Studio"
            ),
            session: nil
        )
    }

    let holding = sections(hold: 16_666_667)
    expect(
        hudRow(holding, "HOLD")?.value == "16.7 ms",
        "the panel names the hold in the same units as every other stage, got: \(hudRow(holding, "HOLD")?.value ?? "nil")"
    )
    expect(
        hudRow(holding, "HOLD")?.note == "Added on this machine to steady the motion.",
        "and says whose latency it is, got: \(hudRow(holding, "HOLD")?.note ?? "nil")"
    )
    let labels = holding.flatMap(\.rows).map(\.label)
    expect(
        labels.firstIndex(of: "HOLD") ?? 0 < labels.firstIndex(of: "END-TO-END") ?? 0,
        "the hold is read before the figure it is part of, got \(labels)"
    )
    expect(
        hudRow(sections(hold: 0), "HOLD")?.value == "not yet",
        "a session that has shown no frame yet holds nothing to report, got:"
            + " \(hudRow(sections(hold: 0), "HOLD")?.value ?? "nil")"
    )
}
