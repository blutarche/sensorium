#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec)
import Foundation
import SensoriumClient
import SensoriumCore

/// A scripted `WaylandDataDeviceIO`: every request is recorded, and every
/// answer is whatever the test staged, so `WaylandPasteboard`'s state
/// machine can be driven without a compositor.
private final class FakeWaylandDataDeviceIO: WaylandDataDeviceIO {
    var currentOfferMimeTypes: [String]?
    var currentOfferIsOwnSource = false
    var changeCount = 0
    /// What `receive(mime:timeoutMilliseconds:)` answers for a given mime;
    /// a mime with no entry answers `nil`, the same as a real timeout.
    var receiveResults: [String: Data] = [:]
    private(set) var receiveCallCount = 0
    private(set) var receivedMimes: [String] = []
    private(set) var offerCallCount = 0
    private(set) var offeredMimeTypes: [String]?
    private(set) var setSelectionSerials: [UInt32] = []
    private(set) var roundtripCallCount = 0
    /// Matches the real glue's own behaviour right after `set_selection`:
    /// the compositor answers with exactly one `selection` event, delivered
    /// synchronously inside the round trip that follows it.
    var roundtripSimulatesOwnEcho = false
    /// Mirrors the real glue's `awaitingOwnSelectionEcho`: set the moment
    /// `setSelection` runs, cleared by the round trip's own echo when
    /// `roundtripSimulatesOwnEcho` is true -- and left set, exactly as the
    /// real compositor leaves it, when the round trip is told not to echo.
    private var awaitingOwnSelectionEcho = false

    func receive(mime: String, timeoutMilliseconds: Int) -> Data? {
        receiveCallCount += 1
        receivedMimes.append(mime)
        return receiveResults[mime]
    }

    func offer(mimeTypes: [String], provider: @escaping (String) -> Data?) {
        offerCallCount += 1
        offeredMimeTypes = mimeTypes
    }

    func setSelection(serial: UInt32) {
        setSelectionSerials.append(serial)
        awaitingOwnSelectionEcho = true
    }

    func roundtrip() {
        roundtripCallCount += 1
        guard roundtripSimulatesOwnEcho else { return }
        changeCount += 1
        currentOfferIsOwnSource = true
        awaitingOwnSelectionEcho = false
    }

    func selectionRequestWasRejected() -> Bool {
        guard awaitingOwnSelectionEcho else { return false }
        awaitingOwnSelectionEcho = false
        return true
    }
}

@MainActor
func testWaylandPasteboardTests() {
    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        io.currentOfferMimeTypes = ["text/plain", "image/png", "text/plain;charset=utf-8"]
        io.receiveResults = ["image/png": Data([1, 2, 3])]
        let readout = pasteboard.read()
        expect(readout.content == .image(format: .png, data: Data([1, 2, 3])), "an image mime is preferred over any text mime")
        expect(io.receivedMimes == ["image/png"], "only the preferred mime is ever fetched")

        print("PASS: an image offer is read ahead of any text flavour on the same offer")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        io.currentOfferMimeTypes = ["text/plain", "text/plain;charset=utf-8"]
        io.receiveResults = ["text/plain;charset=utf-8": Data("hello".utf8)]
        let readout = pasteboard.read()
        expect(readout.content == .text("hello"), "the utf-8 charset flavour is preferred over the bare plain one")
        expect(io.receivedMimes == ["text/plain;charset=utf-8"], "and no other text mime is fetched once it matched")

        print("PASS: text/plain;charset=utf-8 is read ahead of a bare text/plain on the same offer")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        io.currentOfferMimeTypes = ["text/plain", "x-kde-passwordManagerHint"]
        let readout = pasteboard.read()
        expect(readout.isExcludedByType, "a password-manager-hinted offer is refused by type")
        expect(readout.content == nil, "and carries no content")
        expect(io.receiveCallCount == 0, "the offer is never opened for a marked pasteboard")

        print("PASS: an offer carrying x-kde-passwordManagerHint is refused with no receive call")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
        let oversize = String(repeating: "a", count: ClipboardPolicy.maximumContentBytes + 1)
        io.currentOfferMimeTypes = ["text/plain"]
        io.receiveResults = ["text/plain": Data(oversize.utf8)]
        io.changeCount = 1
        switch engine.poll() {
        case let .refused(.tooLarge(byteCount, limit)):
            expect(byteCount == oversize.utf8.count, "the refusal reports the payload's real size")
            expect(limit == ClipboardPolicy.maximumContentBytes, "against the engine's real limit")
        default:
            print("FAIL: an offer one byte over the cap must be refused as too large by a real engine")
            Foundation.exit(1)
        }

        print("PASS: an oversize offer is read whole and refused by a real ClipboardSyncEngine, never truncated")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        io.roundtripSimulatesOwnEcho = true
        let pasteboard = WaylandPasteboard(io: io) { 42 }
        pasteboard.write(.text("mine"))
        expect(io.currentOfferIsOwnSource, "the fake's round trip already confirmed the echo, as the real one does")
        let readout = pasteboard.read()
        expect(readout.content == .text("mine"), "an own-source offer returns what this pasteboard last wrote")
        expect(io.receiveCallCount == 0, "without ever touching the pipe -- the one case that would deadlock")

        print("PASS: reading this client's own selection never opens the pipe")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        io.currentOfferMimeTypes = ["text/plain"]
        io.receiveResults = ["text/plain": Data("same".utf8)]
        let first = pasteboard.read()
        expect(first.content == .text("same"), "the first read of a genuine offer returns its content")
        // A focus round trip re-announces the very same selection.
        io.currentOfferMimeTypes = ["text/plain"]
        let second = pasteboard.read()
        expect(second.content == nil, "a re-offer of the same content is suppressed as a duplicate")
        expect(!second.isExcludedByType, "and is not mistaken for an excluded type")

        print("PASS: a focus round trip re-offering the same content reads as nothing new")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        io.roundtripSimulatesOwnEcho = true
        var serial: UInt32?
        let pasteboard = WaylandPasteboard(io: io) { serial }
        let before = io.changeCount
        let returned = pasteboard.write(.text("held"))
        expect(returned == before, "a write while unfocused returns the change count unchanged")
        expect(io.offerCallCount == 0, "and creates no source until a serial exists")
        expect(io.setSelectionSerials.isEmpty, "nor calls set_selection yet")
        serial = 7
        pasteboard.keyboardDidEnter(serial: 7)
        expect(io.offerCallCount == 1, "the next keyboard enter creates the source")
        expect(io.setSelectionSerials == [7], "and sets the selection with that enter's own serial")

        print("PASS: a write made while unfocused is held and flushed on the next keyboard enter")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        io.roundtripSimulatesOwnEcho = true
        let pasteboard = WaylandPasteboard(io: io) { 5 }
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
        switch engine.apply(.text("local copy")) {
        case .applied: break
        case let .refused(reason):
            print("FAIL: apply of a small text payload must succeed, was refused: \(reason.logReason)")
            Foundation.exit(1)
        }
        expect(engine.poll() == .nothingToSend, "the own-source echo write() already accounted for leaves nothing new to send")

        print("PASS: write()'s returned count already includes its own selection echo")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        io.roundtripSimulatesOwnEcho = true
        let pasteboard = WaylandPasteboard(io: io) { 9 }
        pasteboard.write(.text("mine"))
        expect(io.currentOfferIsOwnSource, "the write's own echo confirmed the source")
        // The compositor cancels this source once another client sets a new
        // selection -- the fake models only the resulting state, since the
        // real event carries nothing else this pasteboard reads.
        io.currentOfferIsOwnSource = false
        io.currentOfferMimeTypes = ["text/plain"]
        io.receiveResults = ["text/plain": Data("someone else's".utf8)]
        let readout = pasteboard.read()
        expect(io.receiveCallCount == 1, "cancelled clears own-source, so the next read goes to the pipe")
        expect(readout.content == .text("someone else's"), "and returns whatever that read produced")

        print("PASS: a cancelled source's next read goes through the pipe rather than replaying the old write")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        // `roundtripSimulatesOwnEcho` stays false: the compositor never
        // echoes this selection back, as it would for a serial it decided
        // was stale.
        var serial: UInt32? = 3
        let pasteboard = WaylandPasteboard(io: io) { serial }
        pasteboard.write(.text("rejected"))
        expect(!io.currentOfferIsOwnSource, "a rejected set_selection never confirms its own source")
        expect(io.setSelectionSerials == [3], "the rejected attempt still asked with the serial it had")

        io.currentOfferMimeTypes = ["text/plain"]
        io.receiveResults = ["text/plain": Data("someone else's".utf8)]
        let readout = pasteboard.read()
        expect(io.receiveCallCount == 1, "a rejected write leaves no stuck own-source flag, so an external selection is read from the pipe")
        expect(readout.content == .text("someone else's"), "and returns that external content")

        io.roundtripSimulatesOwnEcho = true
        serial = 8
        pasteboard.keyboardDidEnter(serial: 8)
        expect(io.setSelectionSerials == [3, 8], "the rejected write is retried on the next keyboard enter")
        expect(io.currentOfferIsOwnSource, "and this time the compositor's echo confirms it")

        print("PASS: a rejected set_selection is not left stuck, and is retried on the next keyboard enter")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isEnabled: true)
        var oversize = Data(repeating: UInt8(ascii: "a"), count: ClipboardPolicy.maximumContentBytes)
        // A lone lead byte of a 3-byte UTF-8 sequence, with no continuation
        // bytes following: invalid on its own, and exactly what a read cut
        // off mid character looks like.
        oversize.append(0xE2)
        io.currentOfferMimeTypes = ["text/plain"]
        io.receiveResults = ["text/plain": oversize]
        io.changeCount = 1
        switch engine.poll() {
        case let .refused(.tooLarge(byteCount, limit)):
            expect(byteCount > ClipboardPolicy.maximumContentBytes, "lossy decoding of the truncated tail never shrinks the byte count below the limit")
            expect(limit == ClipboardPolicy.maximumContentBytes, "against the engine's real limit")
        default:
            print("FAIL: an oversize payload truncated mid multi-byte sequence must be refused as too large, not silently dropped")
            Foundation.exit(1)
        }

        print("PASS: an oversize payload ending mid multi-byte sequence is refused as too large, never dropped")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        io.currentOfferMimeTypes = ["text/plain;charset=utf-8", "text/plain"]
        io.receiveResults = [
            // A lead byte with no continuation bytes: invalid UTF-8, and not
            // oversize, so this exercises the mime fallback rather than the
            // too-large path.
            "text/plain;charset=utf-8": Data([0xE2, 0x28, 0xA1]),
            "text/plain": Data("fallback".utf8)
        ]
        let readout = pasteboard.read()
        expect(readout.content == .text("fallback"), "a preferred mime with invalid UTF-8 bytes falls through to the next mime rather than losing the read")
        expect(io.receivedMimes == ["text/plain;charset=utf-8", "text/plain"], "both mimes were tried in preference order")

        print("PASS: a text mime with invalid UTF-8 bytes falls through to the next mime instead of returning nil")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        io.roundtripSimulatesOwnEcho = true
        let pasteboard = WaylandPasteboard(io: io) { 1 }
        pasteboard.write(.text("mine"))
        expect(io.currentOfferIsOwnSource, "the write's echo confirmed the source before clearing")
        pasteboard.clear()
        let afterClear = pasteboard.read()
        expect(afterClear.content == nil, "clear() drops the last written content, so an own-source read after it has nothing to return")
        expect(io.receiveCallCount == 0, "and still never opens the pipe for its own offer")

        print("PASS: clear() drops the last written content")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        let pasteboard = WaylandPasteboard(io: io) { nil }
        io.currentOfferMimeTypes = ["text/plain"]
        io.receiveResults = ["text/plain": Data("same".utf8)]
        _ = pasteboard.read()
        pasteboard.clear()
        let second = pasteboard.read()
        expect(second.content == .text("same"), "clear() drops the duplicate-suppression state, so a re-offer of the same bytes reads as fresh again")

        print("PASS: clear() drops the last known content")
    }

    do {
        let io = FakeWaylandDataDeviceIO()
        var serial: UInt32?
        let pasteboard = WaylandPasteboard(io: io) { serial }
        pasteboard.write(.text("held"))
        pasteboard.clear()
        serial = 4
        pasteboard.keyboardDidEnter(serial: 4)
        expect(io.offerCallCount == 0, "clear() drops a write that was only pending, so the next keyboard enter has nothing left to flush")

        print("PASS: clear() drops a pending selection that was never focused")
    }
}
#else
@MainActor
func testWaylandPasteboardTests() {}
#endif
