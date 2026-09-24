#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec)
import Foundation
import SensoriumCore

/// What `WaylandPasteboard` needs of the compositor's data device, kept
/// behind a seam so the state machine below can be checked without a real
/// Wayland connection -- the same reasoning `WaylandPointerLocking` follows
/// for captured-pointer mode.
///
/// The real conformer is a small object `WaylandSessionWindow` owns, wired to
/// `wl_data_device`, `wl_data_offer` and `wl_data_source`. `changeCount` and
/// `currentOfferIsOwnSource` are the two signals that state needs to reach
/// `WaylandPasteboard` on: the compositor delivers everything else through
/// events the real conformer answers on its own, never through this seam.
public protocol WaylandDataDeviceIO: AnyObject {
    /// The current selection offer's mime types. `nil` for a cleared
    /// clipboard, and before this device has ever seen a `selection` event.
    var currentOfferMimeTypes: [String]? { get }

    /// Whether the current offer is this client's own most recent write,
    /// confirmed by the compositor's own echo of `set_selection`. Goes false
    /// again once another client's `set_selection` cancels this source.
    var currentOfferIsOwnSource: Bool { get }

    /// Advances by exactly one on every `wl_data_device.selection` event --
    /// this client's own included, and a cleared clipboard included -- so
    /// `WaylandPasteboard.changeCount` can read it directly.
    var changeCount: Int { get }

    /// Asks the offer's source to write `mime`'s bytes into a pipe this call
    /// reads from, waiting at most `timeoutMilliseconds`. `nil` on timeout,
    /// a read error, or no current offer.
    func receive(mime: String, timeoutMilliseconds: Int) -> Data?

    /// Creates a data source offering `mimeTypes`, ready to serve whichever
    /// of them the eventual `set_selection` caller (`WaylandPasteboard`
    /// itself, always) is asked to fill. `provider` is called with the mime
    /// type actually requested and returns the bytes to send, or `nil` to
    /// send nothing.
    func offer(mimeTypes: [String], provider: @escaping (String) -> Data?)

    /// `wl_data_device.set_selection` against the most recently created
    /// source, with `serial` as the input event serial it requires.
    func setSelection(serial: UInt32)

    /// `wl_display_roundtrip`: flushes this client's requests and processes
    /// the compositor's replies to them synchronously, including the
    /// `selection` echo a `set_selection` this call follows produces.
    func roundtrip()

    /// True the moment a `set_selection` call this pasteboard just made is
    /// still unconfirmed after the `roundtrip()` that follows it -- the
    /// compositor's way of ignoring a stale input serial. Clears the flag as
    /// a side effect once read, so a later unrelated `selection` event is
    /// never mistaken for this stale request's echo.
    func selectionRequestWasRejected() -> Bool
}

/// The Wayland conformer of `ClipboardPasteboard`: a compositor's data
/// device, focus-scoped by the platform rather than by this project's own
/// choice -- see `WaylandDataDeviceIO`'s doc comment and
/// `docs/`-adjacent Wayland facts in the phase this shipped in.
///
/// Every member runs on the main actor, which on this platform is also the
/// Wayland and GLib event loop's own thread -- see `WaylandSessionWindow`.
/// `read()` can therefore block that thread for up to 250 ms while a pipe is
/// drained; that stall is accepted rather than hidden, and is why the
/// timeout is short.
public final class WaylandPasteboard: ClipboardPasteboard {
    private let io: any WaylandDataDeviceIO
    /// The newest input event serial the window has seen since it last lost
    /// keyboard focus, or `nil` while it has none -- see
    /// `WaylandSessionWindow.noteInputSerial(_:)`. `set_selection` needs one
    /// and is ignored with a stale one, so a write with none yet is held
    /// rather than sent.
    private let latestInputSerial: () -> UInt32?
    /// The most recent content this pasteboard returned from `read()` or
    /// accepted in `write(_:)`, for duplicate suppression: a focus round trip
    /// re-offers the same selection, and that re-offer must not look like a
    /// fresh copy to the engine polling this pasteboard.
    private var lastKnownContent: ClipboardContent?
    /// The last offer `read()` refused without reading it, excluded or with
    /// no supported form, so a focus round trip re-offering it is not
    /// refused again. `nil` once any other offer has been seen.
    private var lastRefusedOffer: (mimes: [String], isExcludedByType: Bool)?
    /// What this machine last wrote, kept so a read of this client's own
    /// offer never has to go through the pipe -- the one case that would
    /// deadlock, because nothing else would be left to serve it.
    private var lastWrittenContent: ClipboardContent?
    /// A write made while the window had no keyboard focus, held until the
    /// next `wl_keyboard.enter` supplies a serial `set_selection` will
    /// accept. Once the person leaves the window, nothing can update their
    /// clipboard until they return -- a Wayland rule, not this project's.
    private var pendingSelection: ClipboardContent?

    public init(io: any WaylandDataDeviceIO, latestInputSerial: @escaping () -> UInt32?) {
        self.io = io
        self.latestInputSerial = latestInputSerial
    }

    public var changeCount: Int { io.changeCount }

    /// Reads in the offer's own mime order, the form the copying app listed
    /// first before the other, and the other only when the first is missing
    /// or over the limit: those are the only forms `ClipboardSyncEngine`
    /// will look at, and every read can stall this thread.
    public func read() -> ClipboardReadout {
        if io.currentOfferIsOwnSource {
            lastRefusedOffer = nil
            guard let lastWrittenContent else {
                return Self.nothingNew
            }
            return ClipboardReadout(content: lastWrittenContent, isExcludedByType: false)
        }
        guard let mimes = io.currentOfferMimeTypes else {
            lastKnownContent = nil
            lastRefusedOffer = nil
            return Self.nothingNew
        }
        guard !ClipboardPolicy.isExcluded(itemTypeIdentifiers: [mimes]) else {
            return refusal(mimes: mimes, isExcludedByType: true)
        }
        let offersText = Self.textMimesInPreferenceOrder.contains { mimes.contains($0) }
        let offersImage = mimes.contains(Self.pngMime)
        guard offersText || offersImage else {
            return refusal(mimes: mimes, isExcludedByType: false)
        }
        lastRefusedOffer = nil
        var text: String?
        var image: ClipboardImage?
        var forms: [ClipboardContent] = []
        let prefersImage = ClipboardPolicy.prefersImage(firstItemTypeIdentifiers: mimes)
        for readsImage in prefersImage ? [true, false] : [false, true] {
            let form: ClipboardContent?
            if readsImage {
                image = offersImage ? readImage() : nil
                form = image.map { .image(format: $0.format, data: $0.data) }
            } else {
                text = offersText ? readText(mimes: mimes) : nil
                form = text.map(ClipboardContent.text)
            }
            guard let form else { continue }
            forms.append(form)
            if form.byteCount <= ClipboardPolicy.maximumContentBytes { break }
        }
        // What the engine will act on: the form it sends, or the one it
        // refuses as too large. `nil` when every read failed, which was
        // already logged and is not the copy being unsupported.
        guard let decisive = forms.first(where: { $0.byteCount <= ClipboardPolicy.maximumContentBytes })
            ?? forms.first else {
            return Self.nothingNew
        }
        guard decisive != lastKnownContent else {
            return Self.nothingNew
        }
        lastKnownContent = decisive
        return ClipboardReadout(text: text, image: image, firstItemTypeIdentifiers: mimes, isExcludedByType: false)
    }

    private func refusal(mimes: [String], isExcludedByType: Bool) -> ClipboardReadout {
        if let lastRefusedOffer, lastRefusedOffer.mimes == mimes,
           lastRefusedOffer.isExcludedByType == isExcludedByType {
            return Self.nothingNew
        }
        lastRefusedOffer = (mimes, isExcludedByType)
        return ClipboardReadout(text: nil, image: nil, firstItemTypeIdentifiers: mimes, isExcludedByType: isExcludedByType)
    }

    @discardableResult
    public func write(_ content: ClipboardContent) -> Int {
        lastKnownContent = content
        lastWrittenContent = content
        lastRefusedOffer = nil
        guard let serial = latestInputSerial() else {
            // No source is created yet either: there is nothing to offer it
            // against until a serial exists, and creating one early would
            // just be destroyed and remade by `keyboardDidEnter(serial:)`.
            pendingSelection = content
            return io.changeCount
        }
        pendingSelection = nil
        announceSelection(content, serial: serial)
        return io.changeCount
    }

    /// Called from `wl_keyboard.enter`: flushes a write that arrived while
    /// this window had no keyboard focus, now that a serial `set_selection`
    /// will accept exists.
    public func keyboardDidEnter(serial: UInt32) {
        guard let pending = pendingSelection else { return }
        pendingSelection = nil
        announceSelection(pending, serial: serial)
    }

    private func announceSelection(_ content: ClipboardContent, serial: UInt32) {
        io.offer(mimeTypes: mimeTypes(for: content)) { [content] _ in payload(for: content) }
        io.setSelection(serial: serial)
        io.roundtrip()
        if io.selectionRequestWasRejected() {
            // The serial went stale between being noted and being used --
            // held again for the next keyboard enter, which will have a
            // fresh one.
            pendingSelection = content
            print("Sensorium: clipboard set_selection was rejected by the compositor; it will retry on the next keyboard focus")
        }
    }

    /// Drops every pasteboard state this object remembers: the last content
    /// read or written, and any write parked for the next keyboard focus.
    /// Called from `WaylandSessionWindow.close()` so a window going away
    /// leaves nothing stale behind it.
    public func clear() {
        lastKnownContent = nil
        lastWrittenContent = nil
        lastRefusedOffer = nil
        pendingSelection = nil
    }

    private func readImage() -> ClipboardImage? {
        guard let data = io.receive(mime: Self.pngMime, timeoutMilliseconds: Self.receiveTimeoutMilliseconds) else {
            logReceiveFailure(mime: Self.pngMime)
            return nil
        }
        return ClipboardImage(format: .png, data: data)
    }

    /// Plain text under whichever mime a source actually used. `nil` when
    /// the read of the first one offered failed, or no offered one decoded.
    private func readText(mimes: [String]) -> String? {
        for textMime in Self.textMimesInPreferenceOrder where mimes.contains(textMime) {
            guard let data = io.receive(mime: textMime, timeoutMilliseconds: Self.receiveTimeoutMilliseconds) else {
                logReceiveFailure(mime: textMime)
                return nil
            }
            if data.count > ClipboardPolicy.maximumContentBytes {
                // Strict UTF-8 decoding would fail here whenever the read
                // cap cut the payload off mid multi-byte sequence, and a
                // `nil` would then be indistinguishable from "nothing here
                // is text" -- silently dropping an oversize copy instead of
                // letting the engine refuse it. Lossy decoding never shrinks
                // the byte count below the limit, so the refusal below is
                // still accurate.
                return String(decoding: data, as: UTF8.self)
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            return text
        }
        return nil
    }

    private func logReceiveFailure(mime: String) {
        print("Sensorium: clipboard read of \(mime) timed out or failed")
    }

    /// Nothing the engine should act on: no offer, this client's own, a
    /// re-offer of what was last read, or a read that failed.
    private static let nothingNew = ClipboardReadout(
        text: nil, image: nil, firstItemTypeIdentifiers: [], hasItems: false, isExcludedByType: false
    )
    private static let pngMime = "image/png"
    private static let textMimesInPreferenceOrder = [
        "text/plain;charset=utf-8",
        "text/plain",
        "UTF8_STRING",
        "text/plain;charset=UTF-8"
    ]
    /// Short enough that a stalled peer never holds the event loop -- the
    /// same thread draws frames and handles input -- for longer than a
    /// fraction of a second.
    private static let receiveTimeoutMilliseconds = 250
}

/// The mime types this pasteboard offers a written payload under. All the
/// text mimes name the same bytes; which one a requester asks for does not
/// change what is sent.
private func mimeTypes(for content: ClipboardContent) -> [String] {
    switch content {
    case .text:
        ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"]
    case .image(.png, _):
        ["image/png"]
    case .image(.tiff, _):
        // Offered as is: a Linux application that cannot read TIFF simply
        // sees no paste, which is what an unreadable flavour has always
        // meant on this platform.
        ["image/tiff"]
    }
}

private func payload(for content: ClipboardContent) -> Data {
    switch content {
    case let .text(text):
        Data(text.utf8)
    case let .image(_, data):
        data
    }
}
#endif
