import AppKit
import Foundation
import SensoriumCore

final class FakeClipboardPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 0
    private(set) var readCount = 0
    private(set) var writtenContents: [ClipboardContent] = []
    private var readout = ClipboardReadout(content: nil, isExcludedByType: false)

    /// A copy made by some other app on this machine: new contents, and a
    /// change count the engine has never accounted for.
    func stageLocalCopy(_ readout: ClipboardReadout) {
        self.readout = readout
        changeCount += 1
    }

    func read() -> ClipboardReadout {
        readCount += 1
        return readout
    }

    @discardableResult
    func write(_ content: ClipboardContent) -> Int {
        writtenContents.append(content)
        readout = ClipboardReadout(content: content, isExcludedByType: false)
        changeCount += 1
        return changeCount
    }
}

func testClipboardTextAndImageRoundTripThroughTransport() {
    let contents: [ClipboardContent] = [
        .text(""),
        .text("plain ascii"),
        .text("h\u{00E9}llo \u{1F30D} \u{65E5}\u{672C}\u{8A9E}"),
        .image(format: .png, data: Data((0..<4096).map { UInt8($0 % 251) })),
        .image(format: .tiff, data: Data([0x4D, 0x4D, 0x00, 0x2A]))
    ]
    for content in contents {
        let frame = try! SensoriumTransportPacketCodec.encode(.clipboard(content))
        guard case let .clipboard(decoded) = try! SensoriumTransportPacketCodec.decode(frame) else {
            expect(false, "a clipboard frame decodes as a clipboard packet")
            return
        }
        expect(decoded == content, "clipboard content round-trips byte-identically")
    }
}

func testOversizeClipboardIsRefusedCleanlyOnBothSendAndReceive() {
    let oversize = ClipboardContent.image(
        format: .png,
        data: Data(repeating: 7, count: ClipboardPolicy.maximumContentBytes + 1)
    )
    var encodeError: SensoriumProtocolError?
    do {
        _ = try SensoriumTransportPacketCodec.encode(.clipboard(oversize))
    } catch {
        encodeError = error as? SensoriumProtocolError
    }
    expect(encodeError == .frameTooLarge, "an oversize clipboard is refused at encode, never truncated")

    let pasteboard = FakeClipboardPasteboard()
    let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
    pasteboard.stageLocalCopy(ClipboardReadout(content: oversize, isExcludedByType: false))
    let tooLarge = ClipboardRefusal.tooLarge(
        byteCount: oversize.byteCount,
        limit: ClipboardPolicy.maximumContentBytes
    )
    expect(engine.poll() == .refused(tooLarge), "an oversize local copy is refused with a reason instead of sent")
    expect(engine.apply(oversize) == .refused(tooLarge), "an oversize clipboard from the peer is refused, never applied")
    expect(pasteboard.writtenContents.isEmpty, "a refused clipboard never reaches the pasteboard")
    expect(engine.poll() == .nothingToSend, "a refusal is accounted for once, not retried on every poll")
}

func testApplyingAReceivedClipboardIsNeverSentBack() {
    let pasteboard = FakeClipboardPasteboard()
    let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
    expect(engine.poll() == .nothingToSend, "an untouched pasteboard has nothing to send")

    let received = ClipboardContent.text("from the peer")
    expect(
        engine.apply(received) == .applied(description: received.logDescription, byteCount: received.byteCount),
        "a received clipboard is applied to the local pasteboard"
    )
    expect(pasteboard.writtenContents == [received], "exactly one write reached the pasteboard")

    for _ in 0..<10 {
        expect(engine.poll() == .nothingToSend, "the change count an apply produced is never offered back to the peer")
    }
    expect(pasteboard.readCount == 0, "an already-accounted change count is never even read")

    pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied here"), isExcludedByType: false))
    expect(engine.poll() == .send(.text("copied here")), "a real local copy made after an apply is still sent")
    expect(engine.poll() == .nothingToSend, "and is sent exactly once")
}

func testConcealedOrTransientClipboardIsNeverSent() {
    expect(
        ClipboardPolicy.excludedTypeIdentifiers.contains("org.nspasteboard.ConcealedType"),
        "the concealed marker a password manager sets is excluded"
    )
    expect(
        ClipboardPolicy.excludedTypeIdentifiers.contains("org.nspasteboard.TransientType"),
        "the transient marker is excluded"
    )
    expect(
        ClipboardPolicy.excludedTypeIdentifiers.contains("public.file-url"),
        "a file reference is excluded: file transfer is a v1 non-goal"
    )

    let pasteboard = FakeClipboardPasteboard()
    let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
    pasteboard.stageLocalCopy(ClipboardReadout(content: .text("vault-item"), isExcludedByType: true))
    expect(engine.poll() == .refused(.excludedType), "marked content is refused rather than sent")
    expect(engine.poll() == .nothingToSend, "and is not retried")
}

func testDisabledClipboardSyncNeitherSendsNorApplies() {
    let pasteboard = FakeClipboardPasteboard()
    let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: false)
    pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied here"), isExcludedByType: false))
    expect(engine.poll() == .nothingToSend, "a disabled engine sends nothing")
    expect(engine.apply(.text("from the peer")) == .refused(.syncDisabled), "a disabled engine applies nothing")
    expect(
        pasteboard.readCount == 0 && pasteboard.writtenContents.isEmpty,
        "a disabled engine never reads or writes the pasteboard at all"
    )
}

func testClipboardSharingDefaultsOnAtTheViewerAndTheHostWaitsForTheViewer() {
    expect(ClipboardSyncEngine.sharingEnabledByDefault, "the viewer starts a session with clipboard sharing on")
    expect(
        !ClipboardSyncEngine.hostSharingEnabledAtConnect,
        "the host starts every connection with sharing off until the viewer says what it wants"
    )

    let pasteboard = FakeClipboardPasteboard()
    let host = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: ClipboardSyncEngine.hostSharingEnabledAtConnect)
    pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied before the viewer spoke"), isExcludedByType: false))
    expect(host.poll() == .nothingToSend, "a host that has not heard from the viewer sends nothing")
    expect(host.apply(.text("from the peer")) == .refused(.syncDisabled), "and applies nothing")
    expect(
        pasteboard.readCount == 0 && pasteboard.writtenContents.isEmpty,
        "and never reads or writes the pasteboard at all"
    )

    host.setEnabled(true)
    expect(host.poll() == .nothingToSend, "what was on the pasteboard before the viewer turned it on is never sent")
    pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied after"), isExcludedByType: false))
    expect(host.poll() == .send(.text("copied after")), "a copy made after the viewer turned it on is sent")
}

/// docs/ux-spec.md's live "Clipboard: on or off" -- `ClipboardSyncEngine
/// .setEnabled(_:)`. The tests above exercise what happens at a fixed
/// state; this proves the *transition* between the two states is safe.
func testClipboardSyncEnabledToggleAccountsChangesAcrossBothDirections() {
    // Turning ON: a copy made while off -- however long ago -- must not
    // be sent the instant sync comes back on, only ever a genuinely new
    // one made after.
    do {
        let pasteboard = FakeClipboardPasteboard()
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: false)
        pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied while off"), isExcludedByType: false))
        expect(engine.poll() == .nothingToSend, "a disabled engine sends nothing, matching the existing construction-time behaviour")

        engine.setEnabled(true)
        expect(engine.isEnabled, "the engine reports the new state immediately")
        expect(
            engine.poll() == .nothingToSend,
            "the copy made before this call is absorbed as the new baseline, not sent the instant sync turns on"
        )

        pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied after turning on"), isExcludedByType: false))
        expect(
            engine.poll() == .send(.text("copied after turning on")),
            "a genuinely new copy, made after enabling, is sent normally"
        )
    }

    // Turning OFF: takes effect immediately, and needs no bookkeeping of
    // its own -- every method already guards on `isEnabled` on every call.
    do {
        let pasteboard = FakeClipboardPasteboard()
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
        expect(engine.poll() == .nothingToSend, "nothing to send from an untouched pasteboard")

        engine.setEnabled(false)
        expect(!engine.isEnabled, "the engine reports the new state immediately")
        pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied while off"), isExcludedByType: false))
        expect(engine.poll() == .nothingToSend, "a copy made after turning off is never sent")
        expect(engine.apply(.text("from the peer")) == .refused(.syncDisabled), "and nothing from the peer is applied either")
    }

    // Off, then on, then off again, then on again: each ON re-baselines
    // against whatever is on the pasteboard at that exact moment, however
    // many times the state has flipped.
    do {
        let pasteboard = FakeClipboardPasteboard()
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
        engine.setEnabled(false)
        pasteboard.stageLocalCopy(ClipboardReadout(content: .text("first, while off"), isExcludedByType: false))
        engine.setEnabled(true)
        expect(engine.poll() == .nothingToSend, "the first stale copy is absorbed by the first re-enable")
        engine.setEnabled(false)
        pasteboard.stageLocalCopy(ClipboardReadout(content: .text("second, while off"), isExcludedByType: false))
        engine.setEnabled(true)
        expect(engine.poll() == .nothingToSend, "and the second stale copy, made during the second off period, is absorbed by the second re-enable")

        pasteboard.stageLocalCopy(ClipboardReadout(content: .text("after everything"), isExcludedByType: false))
        expect(engine.poll() == .send(.text("after everything")), "a copy made after the last re-enable is still sent normally")
    }

    // A no-op transition -- already in the requested state -- changes
    // nothing, including the baseline: it must not re-absorb a copy made
    // between two redundant enable calls.
    do {
        let pasteboard = FakeClipboardPasteboard()
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
        engine.setEnabled(true)
        pasteboard.stageLocalCopy(ClipboardReadout(content: .text("copied while already on"), isExcludedByType: false))
        engine.setEnabled(true)
        expect(
            engine.poll() == .send(.text("copied while already on")),
            "a redundant setEnabled(true) does not re-baseline and swallow a real copy made in between"
        )
    }

    print("PASS: setEnabled keeps the change-count baseline correct across repeated flips, and a redundant call is a no-op")
}

func testClipboardDescriptionsCarrySizesAndOutcomesOnly() {
    let phrase = "correct horse battery staple"
    let text = ClipboardContent.text(phrase)
    expect(text.logDescription == "text, 28 bytes", "a text description is kind and size only")
    expect(
        !"\(text)".contains(phrase) && !String(reflecting: text).contains(phrase),
        "interpolating clipboard content cannot leak it into a log line"
    )
    let image = ClipboardContent.image(format: .png, data: Data(repeating: 9, count: 2048))
    expect(image.logDescription == "image/png, 2048 bytes", "an image description is kind and size only")
    let decision = ClipboardSendDecision.send(text)
    expect(!"\(decision)".contains(phrase), "a send decision cannot leak content either")
    let refusal = ClipboardRefusal.tooLarge(byteCount: 5_000_000, limit: ClipboardPolicy.maximumContentBytes)
    expect(
        refusal.logReason.contains("5000000") && refusal.logReason.contains("\(ClipboardPolicy.maximumContentBytes)"),
        "an oversize refusal names both sizes so the limit is diagnosable"
    )
}

func testAClipboardFrameIsSkippableByAPeerThatPredatesIt() {
    let frame = try! SensoriumTransportPacketCodec.encode(.clipboard(.text("hello")))
    expect(frame[0] == 3, "clipboard travels on transport tag 3")
    let declaredLength = frame.withUnsafeBytes { bytes in
        UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
    }
    expect(
        Int(declaredLength) == frame.count - 5,
        "tag 3 carries the same [tag][length][payload] shape as every other tag, so a peer that never heard of it skips exactly its bytes"
    )
    // The same frame under a tag this build does not know: an unrecognized
    // packet, not a thrown error, which is exactly what a pre-clipboard peer
    // does with tag 3 itself.
    var unknownTag = Data([9])
    unknownTag.append(frame.dropFirst())
    expect(
        try! SensoriumTransportPacketCodec.decode(unknownTag) == .unrecognized(tag: 9, payload: Data(frame.dropFirst(5))),
        "an unknown transport tag decodes to .unrecognized rather than throwing"
    )
}

func testMalformedClipboardPayloadsAreRejected() {
    let frame = try! SensoriumTransportPacketCodec.encode(.clipboard(.text("hello")))
    var wrongMagic = frame
    wrongMagic[5] = 0x00
    var magicError: SensoriumProtocolError?
    do {
        _ = try SensoriumTransportPacketCodec.decode(wrongMagic)
    } catch {
        magicError = error as? SensoriumProtocolError
    }
    expect(magicError == .malformedMessage, "a clipboard payload without the clipboard magic is rejected")

    var truncated = Data([3])
    var length = UInt32(4).bigEndian
    withUnsafeBytes(of: &length) { truncated.append(contentsOf: $0) }
    truncated.append(Data([0x43, 0x4C, 0x49, 0x50]))
    var shortError: SensoriumProtocolError?
    do {
        _ = try SensoriumTransportPacketCodec.decode(truncated)
    } catch {
        shortError = error as? SensoriumProtocolError
    }
    expect(shortError == .frameTooShort, "a clipboard payload too short to hold its header is rejected")
}

func testAnyPasteboardItemCarryingAnExcludedTypeRefusesTheWholePasteboard() {
    // `NSPasteboard.types` reports the first item only, so a marker sitting on
    // a later item of a multi-item pasteboard reads as unmarked. The decision
    // is made over every item's types instead, and made here rather than in
    // `SystemPasteboard` so it is testable without a window server.
    expect(
        ClipboardPolicy.isExcluded(itemTypeIdentifiers: [
            ["public.utf8-plain-text"],
            ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
        ]),
        "a concealed marker on a later pasteboard item still refuses the pasteboard"
    )
    expect(
        ClipboardPolicy.isExcluded(itemTypeIdentifiers: [["public.utf8-plain-text"], ["public.file-url"]]),
        "and so does a file reference on a later item"
    )
    expect(
        !ClipboardPolicy.isExcluded(itemTypeIdentifiers: [["public.utf8-plain-text"], ["public.png"]]),
        "an ordinary multi-item pasteboard is not refused"
    )
    expect(
        ClipboardPolicy.isExcluded(itemTypeIdentifiers: nil),
        "an item list that cannot be read fails closed: refuse rather than send what could not be checked"
    )
}

/// docs/ux-spec.md's "Clipboard: on or off," on the wire -- a viewer-to-host
/// message, live for the session it arrives on.
func testClipboardSharingRoundTripsAndRefusesMalformed() {
    for enabled in [true, false] {
        let message = SensoriumMessage.clipboardSharing(enabled: enabled)
        expect(
            try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
            "a clipboardSharing(\(enabled)) round-trips its own value unchanged"
        )
    }

    func frame(fromObject object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    do {
        _ = try SensoriumFrameCodec.decode(frame(fromObject: ["type": "clipboardSharing"]))
        expect(false, "a clipboardSharing with no enabled value at all is refused as malformed")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "a clipboardSharing missing its enabled value reports malformedMessage, not some other error")
    }

    do {
        _ = try SensoriumFrameCodec.decode(frame(fromObject: ["type": "clipboardSharing", "clipboardSharingEnabled": "yes"]))
        expect(false, "a clipboardSharing whose enabled value is not a boolean is refused, not silently coerced")
    } catch is DecodingError {
        // The field's own type mismatch is caught by JSONDecoder before
        // SensoriumFrameCodec's own malformed-shape check ever runs --
        // still refused, the same as testMalformedControlJSONStillThrows'
        // own genuinely-malformed-JSON case.
    } catch {
        expect(false, "a clipboardSharing with a non-boolean enabled value reports a decoding error, not some other kind of failure")
    }
}


/// The clipboard limit is the largest payload one transport packet can carry,
/// so a clipboard is only ever refused for size where the wire itself would
/// refuse it.
func testClipboardLimitIsTheLargestPayloadOneTransportPacketCarries() {
    let limit = ClipboardPolicy.maximumContentBytes
    let atLimit = ClipboardContent.image(format: .tiff, data: Data(repeating: 1, count: limit))
    guard let frame = try? SensoriumTransportPacketCodec.encode(.clipboard(atLimit)) else {
        expect(false, "a clipboard exactly at the limit, in the longest format name, encodes into one transport packet")
        return
    }
    expect(
        frame.count - 5 == SensoriumTransportPacketCodec.maximumPayloadLength,
        "and fills that packet exactly, so no larger clipboard could fit -- got \(frame.count - 5) of \(SensoriumTransportPacketCodec.maximumPayloadLength)"
    )
    expect(
        (try? SensoriumTransportPacketCodec.decode(frame)) == .clipboard(atLimit),
        "a clipboard at the limit decodes back unchanged"
    )
    let overLimit = ClipboardContent.text(String(repeating: "a", count: limit + 1))
    expect(
        (try? SensoriumTransportPacketCodec.encode(.clipboard(overLimit))) == nil,
        "one byte over the limit is refused at encode"
    )
    expect(limit >= 4 * 1024 * 1024, "the limit is at least 4 MiB, matching the video frame cap it derives from")
}

/// A copy that offers both text and an image is sent as whichever the
/// copying app listed first, and falls back to the other when that one is
/// too large.
func testClipboardPrefersTheCopyingAppsOrderAndFallsBackWhenTooLarge() {
    let png = ClipboardImage(format: .png, data: Data(repeating: 5, count: 64))
    func decision(
        text: String?,
        image: ClipboardImage?,
        types: [String],
        limit: Int = ClipboardPolicy.maximumContentBytes
    ) -> ClipboardSendDecision {
        let pasteboard = FakeClipboardPasteboard()
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true, maximumContentBytes: limit)
        pasteboard.stageLocalCopy(ClipboardReadout(
            text: text, image: image, firstItemTypeIdentifiers: types, isExcludedByType: false
        ))
        return engine.poll()
    }

    expect(
        decision(text: "A1", image: png, types: ["public.png", "public.utf8-plain-text"])
            == .send(.image(format: .png, data: png.data)),
        "a screenshot, which lists its image first, is sent as the image"
    )
    expect(
        decision(text: "A1", image: png, types: ["public.utf8-plain-text", "public.png"])
            == .send(.text("A1")),
        "a copy that lists text first is sent as text"
    )
    expect(
        decision(text: "A1", image: png, types: ["public.html", "public.rtf", "public.tiff", "public.utf8-plain-text"])
            == .send(.text("A1")),
        "rich text listed ahead of the image counts as text first, as a spreadsheet copy does"
    )
    expect(
        decision(text: "A1", image: png, types: [])
            == .send(.image(format: .png, data: png.data)),
        "with no type order to go by, the image is sent"
    )

    let big = ClipboardImage(format: .png, data: Data(repeating: 5, count: 100))
    expect(
        decision(text: "fits", image: big, types: ["public.png", "public.utf8-plain-text"], limit: 50)
            == .send(.text("fits")),
        "an image over the limit falls back to the text copied with it"
    )
    expect(
        decision(text: String(repeating: "t", count: 100), image: png, types: ["public.utf8-plain-text", "public.png"], limit: 80)
            == .send(.image(format: .png, data: png.data)),
        "text over the limit falls back to the image copied with it"
    )
    expect(
        decision(text: String(repeating: "t", count: 60), image: big, types: ["public.png", "public.utf8-plain-text"], limit: 50)
            == .refused(.tooLarge(byteCount: 100, limit: 50)),
        "when neither fits, the refusal names the size of the one the app preferred"
    )
    expect(
        decision(text: "only text", image: nil, types: ["public.png"]) == .send(.text("only text")),
        "a single candidate is sent whatever the type order says"
    )
    expect(
        decision(text: nil, image: nil, types: ["public.utf8-plain-text"]) == .refused(.unsupportedContent),
        "a pasteboard with neither text nor an image is unsupported"
    )
}

/// TIFF is what many apps put on the pasteboard for an image, and it is
/// usually uncompressed. It is converted to PNG before the size check.
func testATIFFImageIsConvertedToPNGBeforeItIsSized() {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let tiff = bitmap.tiffRepresentation else {
        expect(false, "a test TIFF can be built")
        return
    }
    guard let png = SystemPasteboard.pngData(fromTIFF: tiff) else {
        expect(false, "a valid TIFF converts to PNG")
        return
    }
    expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "the converted data is a PNG")
    expect(png.count < tiff.count, "and smaller than the uncompressed TIFF it came from")
    expect(SystemPasteboard.pngData(fromTIFF: Data([0x00, 0x01])) == nil, "data that is not an image does not convert")
}

/// The host's own refusal, told to the viewer so a person there can see why a
/// copy did not arrive. Carries the reason and sizes only, never content.
func testClipboardRefusedRoundTripsAndRefusesMalformed() {
    let refusals: [ClipboardRefusal] = [
        .tooLarge(byteCount: 6_500_000, limit: ClipboardPolicy.maximumContentBytes),
        .excludedType,
        .unsupportedContent,
        .syncDisabled,
        .sessionNotActive
    ]
    for refusal in refusals {
        let message = SensoriumMessage.clipboardRefused(refusal)
        expect(
            try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
            "clipboardRefused(\(refusal)) round-trips unchanged"
        )
    }

    func frame(fromObject object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
    let malformed: [(String, [String: Any])] = [
        ("no reason at all", ["type": "clipboardRefused"]),
        ("a reason this build does not know", ["type": "clipboardRefused", "clipboardRefusal": "too-sparkly"]),
        ("too-large without its sizes", ["type": "clipboardRefused", "clipboardRefusal": "too-large"]),
        ("too-large with a negative size", [
            "type": "clipboardRefused", "clipboardRefusal": "too-large",
            "clipboardByteCount": -1, "clipboardLimit": 10
        ])
    ]
    for (name, object) in malformed {
        do {
            _ = try SensoriumFrameCodec.decode(frame(fromObject: object))
            expect(false, "a clipboardRefused with \(name) is refused as malformed")
        } catch SensoriumProtocolError.malformedMessage {
        } catch {
            expect(false, "a clipboardRefused with \(name) reports malformedMessage, got \(error)")
        }
    }
}

/// Clearing the pasteboard, as a password manager does when it forgets a
/// copied password, is not a copy, so it is neither sent nor refused.
func testAnEmptiedPasteboardIsNotReportedAsUnsupported() {
    let pasteboard = FakeClipboardPasteboard()
    let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
    pasteboard.stageLocalCopy(ClipboardReadout(
        text: nil, image: nil, firstItemTypeIdentifiers: [], hasItems: false, isExcludedByType: false
    ))
    expect(engine.poll() == .nothingToSend, "an emptied pasteboard has nothing to send and nothing to refuse")
    pasteboard.stageLocalCopy(ClipboardReadout(
        text: nil, image: nil, firstItemTypeIdentifiers: ["com.example.private"], hasItems: true, isExcludedByType: false
    ))
    expect(engine.poll() == .refused(.unsupportedContent), "a copy of something that is neither text nor an image is still refused")
}

/// Producing the image form can mean decoding a large TIFF, so it happens
/// only when the image is the form about to be sized and sent.
func testTheImageFormIsProducedOnlyWhenItIsChosen() {
    final class LoadCounter: @unchecked Sendable {
        var count = 0
    }
    let png = ClipboardImage(format: .png, data: Data(repeating: 5, count: 64))
    func decision(
        text: String,
        types: [String],
        limit: Int = ClipboardPolicy.maximumContentBytes
    ) -> (ClipboardSendDecision, loads: Int) {
        let counter = LoadCounter()
        let pasteboard = FakeClipboardPasteboard()
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true, maximumContentBytes: limit)
        pasteboard.stageLocalCopy(ClipboardReadout(
            text: text,
            loadImage: {
                counter.count += 1
                return png
            },
            firstItemTypeIdentifiers: types,
            isExcludedByType: false
        ))
        return (engine.poll(), counter.count)
    }

    let textFirst = decision(text: "A1", types: ["public.utf8-plain-text", "public.tiff"])
    expect(textFirst.0 == .send(.text("A1")), "a copy that lists text first is sent as text")
    expect(textFirst.loads == 0, "and its image form is never produced -- produced \(textFirst.loads) times")

    let imageFirst = decision(text: "A1", types: ["public.tiff", "public.utf8-plain-text"])
    expect(imageFirst.0 == .send(.image(format: .png, data: png.data)), "a copy that lists its image first is sent as the image")
    expect(imageFirst.loads == 1, "whose form is produced once -- produced \(imageFirst.loads) times")

    let fallback = decision(text: String(repeating: "t", count: 100), types: ["public.utf8-plain-text", "public.tiff"], limit: 80)
    expect(fallback.0 == .send(.image(format: .png, data: png.data)), "text over the limit falls back to the image")
    expect(fallback.loads == 1, "which is produced only then -- produced \(fallback.loads) times")
}
