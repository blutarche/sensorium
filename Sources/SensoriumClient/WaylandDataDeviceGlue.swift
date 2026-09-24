#if canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec)
import CWayland
import Foundation
import SensoriumCore
#if canImport(Glibc)
import Glibc
#endif

/// `WaylandSessionWindow`'s conformer of `WaylandDataDeviceIO`: the one
/// object that actually touches `wl_data_device`, `wl_data_offer` and
/// `wl_data_source`. Everything checkable without a compositor lives in
/// `WaylandPasteboard`; this class exists to give that state machine real
/// events to react to.
///
/// One data offer is tracked at a time for the selection, `currentOffer`, and
/// one more, `pendingOffer`, for an offer this device has announced but not
/// yet classified -- `wl_data_offer.offer` events naming its mime types
/// arrive between `data_offer` and whatever tells this class what the offer
/// is for. Drag-and-drop is declined outright: this viewer neither accepts a
/// drop nor starts a drag, so an offer that turns out to be one is destroyed
/// once `leave` or `drop` says it is done.
/// Not actor-isolated, like `SystemPasteboard`: `ClipboardPasteboard`'s
/// synchronous `read()`/`write()` contract admits no `await`, so its
/// conformers can't be. This is safe because the Wayland connection this
/// class wraps, and the GLib loop that pumps it, never leave the process's
/// one main thread.
final class WaylandDataDeviceGlue: WaylandDataDeviceIO {
    private let display: OpaquePointer
    private let dataDeviceManager: OpaquePointer
    private let dataDevice: OpaquePointer
    private let log: @Sendable (String) -> Void

    private var pendingOffer: OpaquePointer?
    private var pendingMimes: [String] = []
    private var dragOffer: OpaquePointer?

    private(set) var currentOffer: OpaquePointer?
    private(set) var currentOfferMimeTypes: [String]?
    private(set) var currentOfferIsOwnSource = false
    private(set) var changeCount = 0

    private var currentSource: OpaquePointer?
    private var currentProvider: ((String) -> Data?)?
    /// Set the moment this class asks for `set_selection` against a source it
    /// just created, and consumed by the very next `selection` event -- the
    /// compositor answers `set_selection` with exactly one `selection`
    /// event, delivered before `wl_display_roundtrip` returns.
    private var awaitingOwnSelectionEcho = false

    /// A `wl_data_offer.offer` event names a mime type this session never
    /// asked for and never bounds -- a hostile or buggy local client is the
    /// only source of an offer this large. Extra entries beyond either limit
    /// are dropped with no log, since nothing this project does depends on
    /// seeing them.
    private static let maximumMimeTypeCount = 256
    private static let maximumMimeTypeByteCount = 256

    /// The pipe a `send` event hands this class is served on
    /// `DispatchQueue.global`, off the Wayland/GLib thread that also decodes,
    /// presents and reads input -- see `handleSourceSend`'s own doc comment.
    /// Two seconds is generous for any real local reader and short enough
    /// that a wedged one cannot hold the fd, and the source it belongs to,
    /// open indefinitely.
    private static let sendDeadlineNanoseconds: Int64 = 2_000_000_000

    /// A pipe this class writes into can have its reader vanish mid-write,
    /// which raises `SIGPIPE` and would otherwise kill this process outright.
    /// Every write already checks `EPIPE` on the descriptor once this signal
    /// is ignored, so nothing here needs the default disposition. Swift
    /// initializes a `static let` at most once, the first time it is read,
    /// which is what makes this run exactly once per process.
    private static let ignoreSigpipeOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    init(
        dataDeviceManager: OpaquePointer,
        seat: OpaquePointer,
        display: OpaquePointer,
        log: @escaping @Sendable (String) -> Void = { print("Sensorium: \($0)") }
    ) {
        self.dataDeviceManager = dataDeviceManager
        self.display = display
        self.log = log
        _ = Self.ignoreSigpipeOnce
        dataDevice = wl_data_device_manager_get_data_device(dataDeviceManager, seat)
        wl_data_device_add_listener(dataDevice, dataDeviceListener, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - WaylandDataDeviceIO

    func receive(mime: String, timeoutMilliseconds: Int) -> Data? {
        guard let currentOffer else { return nil }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        wl_data_offer_receive(currentOffer, mime, writeDescriptor)
        Glibc.close(writeDescriptor)
        wl_display_flush(display)
        defer { Glibc.close(readDescriptor) }

        var data = Data()
        let cap = ClipboardPolicy.maximumContentBytes + 1
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = MonotonicClock.nowNanoseconds() + Int64(timeoutMilliseconds) * 1_000_000
        while data.count < cap {
            let remainingNanoseconds = deadline - MonotonicClock.nowNanoseconds()
            guard remainingNanoseconds > 0 else { return nil }
            var descriptor = pollfd(fd: readDescriptor, events: Int16(POLLIN), revents: 0)
            let remainingMilliseconds = Int32(min(Int64(Int32.max), remainingNanoseconds / 1_000_000 + 1))
            let pollResult = poll(&descriptor, 1, remainingMilliseconds)
            guard pollResult > 0 else {
                if pollResult < 0, errno == EINTR { continue }
                return nil
            }
            let read = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                let capacity = min(rawBuffer.count, cap - data.count)
                return Glibc.read(readDescriptor, rawBuffer.baseAddress, capacity)
            }
            if read < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func offer(mimeTypes: [String], provider: @escaping (String) -> Data?) {
        if let currentSource {
            wl_data_source_destroy(currentSource)
        }
        let source = wl_data_device_manager_create_data_source(dataDeviceManager)
        for mime in mimeTypes {
            wl_data_source_offer(source, mime)
        }
        wl_data_source_add_listener(source, dataSourceListener, Unmanaged.passUnretained(self).toOpaque())
        currentSource = source
        currentProvider = provider
    }

    func setSelection(serial: UInt32) {
        // Drain anything already queued first: a `selection` catch-up event
        // from this same keyboard enter (see this class's doc comment on
        // `awaitingOwnSelectionEcho`) can still be in flight when a write
        // follows focus closely, and if it landed in the same roundtrip as
        // our own echo it would consume this flag instead, mislabelling both
        // events. Once this returns, the next `selection` event this class
        // sees can only be the echo of the request below.
        wl_display_roundtrip(display)
        awaitingOwnSelectionEcho = true
        wl_data_device_set_selection(dataDevice, currentSource, serial)
    }

    func roundtrip() {
        wl_display_roundtrip(display)
    }

    /// True the moment a `set_selection` this class sent is still waiting
    /// for its echo after the round trip that should have delivered it --
    /// the compositor's way of ignoring a stale serial with no error of its
    /// own. Clears the flag as a side effect, so a later `selection` event
    /// for something else is never mistaken for this stale request's echo.
    func selectionRequestWasRejected() -> Bool {
        guard awaitingOwnSelectionEcho else { return false }
        awaitingOwnSelectionEcho = false
        return true
    }

    /// Destroys every live offer and source. Called from
    /// `WaylandSessionWindow.close()`.
    func tearDown() {
        if let pendingOffer {
            wl_data_offer_destroy(pendingOffer)
        }
        if let dragOffer, dragOffer != pendingOffer {
            wl_data_offer_destroy(dragOffer)
        }
        if let currentOffer, currentOffer != pendingOffer, currentOffer != dragOffer {
            wl_data_offer_destroy(currentOffer)
        }
        if let currentSource {
            wl_data_source_destroy(currentSource)
        }
        wl_data_device_release(dataDevice)
        wl_display_flush(display)
    }

    // MARK: - wl_data_device events

    fileprivate func handleDataOffer(_ offer: OpaquePointer) {
        if let pendingOffer, pendingOffer != offer {
            wl_data_offer_destroy(pendingOffer)
        }
        pendingOffer = offer
        pendingMimes = []
        wl_data_offer_add_listener(offer, dataOfferListener, Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func handleOfferMimeType(offer: OpaquePointer, mime: String) {
        guard offer == pendingOffer else { return }
        guard pendingMimes.count < Self.maximumMimeTypeCount else { return }
        guard mime.utf8.count <= Self.maximumMimeTypeByteCount else { return }
        pendingMimes.append(mime)
    }

    /// A drag entering this surface. Declined outright -- see this class's
    /// own doc comment -- and tracked separately from `pendingOffer` so a
    /// clipboard read never mistakes a declined drag for the selection.
    fileprivate func handleDragEnter(serial: UInt32, offer: OpaquePointer?) {
        guard let offer else { return }
        if offer == pendingOffer {
            pendingOffer = nil
            pendingMimes = []
        }
        dragOffer = offer
        wl_data_offer_accept(offer, serial, nil)
    }

    fileprivate func handleDragLeaveOrDrop() {
        if let dragOffer {
            wl_data_offer_destroy(dragOffer)
        }
        dragOffer = nil
    }

    fileprivate func handleSelection(_ offer: OpaquePointer?) {
        if let currentOffer, currentOffer != offer {
            wl_data_offer_destroy(currentOffer)
        }
        changeCount += 1
        defer { awaitingOwnSelectionEcho = false }
        guard let offer else {
            currentOffer = nil
            currentOfferMimeTypes = nil
            currentOfferIsOwnSource = false
            return
        }
        currentOffer = offer
        if offer == pendingOffer {
            currentOfferMimeTypes = pendingMimes
            pendingOffer = nil
            pendingMimes = []
        }
        // Only the confirming echo right after `set_selection` may promote
        // this offer to "ours" -- anything else leaves the flag exactly as
        // it already was. The compositor re-announces the current selection
        // with a brand new `wl_data_offer` on every keyboard re-focus, even
        // when nothing changed, which for a still-live source of ours would
        // otherwise look like a fresh, unconfirmed, foreign one and send the
        // next `read()` down the pipe to read from ourselves -- the one case
        // that deadlocks. A source that stops being the selection always
        // gets `cancelled` first, which is what actually resets this.
        if awaitingOwnSelectionEcho {
            currentOfferIsOwnSource = true
        }
    }

    // MARK: - wl_data_source events

    /// Runs the actual write on `DispatchQueue.global`, off the Wayland/GLib
    /// thread that also decodes, presents and reads input: a local reader
    /// that stalls or never reads must not stall any of that. Nothing here
    /// touches Wayland -- only the pipe -- which is what makes that safe.
    fileprivate func handleSourceSend(source: OpaquePointer, mime: String, fileDescriptor: Int32) {
        guard source == currentSource, let data = currentProvider?(mime) else {
            Glibc.close(fileDescriptor)
            return
        }
        let log = self.log
        DispatchQueue.global(qos: .userInitiated).async {
            Self.writeSendData(data, fileDescriptor: fileDescriptor, log: log)
        }
    }

    /// `static` and given only the bytes and the fd it needs, so nothing
    /// tempts this to reach back into Wayland state from the wrong thread.
    private static func writeSendData(_ data: Data, fileDescriptor: Int32, log: @escaping @Sendable (String) -> Void) {
        defer { Glibc.close(fileDescriptor) }
        _ = fcntl(fileDescriptor, F_SETFL, O_NONBLOCK)
        let deadline = MonotonicClock.nowNanoseconds() + sendDeadlineNanoseconds
        let succeeded = data.withUnsafeBytes { rawBuffer -> Bool in
            var offset = 0
            while offset < rawBuffer.count {
                let remainingNanoseconds = deadline - MonotonicClock.nowNanoseconds()
                guard remainingNanoseconds > 0 else { return false }
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let remainingMilliseconds = Int32(min(Int64(Int32.max), remainingNanoseconds / 1_000_000 + 1))
                let pollResult = poll(&descriptor, 1, remainingMilliseconds)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard pollResult > 0 else { return false }
                let written = Glibc.write(fileDescriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    // Includes EPIPE: the reader closed its end mid-write.
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        if !succeeded {
            log("clipboard write to a local reader missed its 2-second deadline or failed; the write was abandoned")
        }
    }

    fileprivate func handleSourceCancelled(_ source: OpaquePointer) {
        guard source == currentSource else { return }
        wl_data_source_destroy(source)
        currentSource = nil
        currentProvider = nil
        currentOfferIsOwnSource = false
    }
}

private func glueFrom(_ data: UnsafeMutableRawPointer?) -> WaylandDataDeviceGlue? {
    guard let data else { return nil }
    return Unmanaged<WaylandDataDeviceGlue>.fromOpaque(data).takeUnretainedValue()
}

/// Listeners set only the events their bound version can deliver; see
/// `heapListener` in `WaylandSessionWindow.swift` for why.
private func heapListener<Listener>(_ value: Listener) -> UnsafeMutablePointer<Listener> {
    let pointer = UnsafeMutablePointer<Listener>.allocate(capacity: 1)
    pointer.initialize(to: value)
    return pointer
}

nonisolated(unsafe) private let dataDeviceListener: UnsafeMutablePointer<wl_data_device_listener> = {
    var listener = wl_data_device_listener()
    listener.data_offer = { data, _, offer in
        guard let glue = glueFrom(data), let offer else { return }
        glue.handleDataOffer(offer)
    }
    listener.enter = { data, _, serial, _, _, _, offer in
        guard let glue = glueFrom(data) else { return }
        glue.handleDragEnter(serial: serial, offer: offer)
    }
    listener.leave = { data, _ in
        guard let glue = glueFrom(data) else { return }
        glue.handleDragLeaveOrDrop()
    }
    listener.motion = { _, _, _, _, _ in }
    listener.drop = { data, _ in
        guard let glue = glueFrom(data) else { return }
        glue.handleDragLeaveOrDrop()
    }
    listener.selection = { data, _, offer in
        guard let glue = glueFrom(data) else { return }
        glue.handleSelection(offer)
    }
    return heapListener(listener)
}()

nonisolated(unsafe) private let dataOfferListener: UnsafeMutablePointer<wl_data_offer_listener> = {
    var listener = wl_data_offer_listener()
    listener.offer = { data, offer, mime in
        guard let glue = glueFrom(data), let offer, let mime else { return }
        glue.handleOfferMimeType(offer: offer, mime: String(cString: mime))
    }
    listener.source_actions = { _, _, _ in }
    listener.action = { _, _, _ in }
    return heapListener(listener)
}()

nonisolated(unsafe) private let dataSourceListener: UnsafeMutablePointer<wl_data_source_listener> = {
    var listener = wl_data_source_listener()
    listener.target = { _, _, _ in }
    listener.send = { data, source, mime, fileDescriptor in
        guard let glue = glueFrom(data), let source, let mime else { return }
        glue.handleSourceSend(source: source, mime: String(cString: mime), fileDescriptor: fileDescriptor)
    }
    listener.cancelled = { data, source in
        guard let glue = glueFrom(data), let source else { return }
        glue.handleSourceCancelled(source)
    }
    listener.dnd_drop_performed = { _, _ in }
    listener.dnd_finished = { _, _ in }
    listener.action = { _, _, _ in }
    return heapListener(listener)
}()
#endif
