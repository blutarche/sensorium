import Foundation
import SensoriumCore

/// Where `WaylandPasteboardProxy` looks for the real thing. On Wayland the
/// clipboard belongs to a surface, so only a window has one -- and the session
/// asks the platform for a pasteboard whether or not a window is open yet.
public protocol ClipboardPasteboardSource: AnyObject, Sendable {
    var currentPasteboard: (any ClipboardPasteboard)? { get }
}

/// The one place the window's clipboard is published, filled in when a session
/// window opens and emptied when it closes. Locked rather than isolated: the
/// clipboard engine polls from wherever its own timer runs, and the window is
/// set from the event loop's thread.
public final class ClipboardPasteboardBox: ClipboardPasteboardSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pasteboard: (any ClipboardPasteboard)?

    public init() {}

    public var currentPasteboard: (any ClipboardPasteboard)? {
        lock.lock()
        defer { lock.unlock() }
        return pasteboard
    }

    public func set(_ pasteboard: (any ClipboardPasteboard)?) {
        lock.lock()
        defer { lock.unlock() }
        self.pasteboard = pasteboard
    }
}

/// The clipboard the Linux viewer hands a session, standing in for the one the
/// window will own. A machine with no window open has no clipboard to offer,
/// and says exactly that: nothing copied, nothing excluded, and a write that
/// went nowhere -- never a stale readout from a window that has closed.
public final class WaylandPasteboardProxy: ClipboardPasteboard {
    private let source: any ClipboardPasteboardSource

    public init(source: any ClipboardPasteboardSource) {
        self.source = source
    }

    public var changeCount: Int { source.currentPasteboard?.changeCount ?? 0 }

    public func read() -> ClipboardReadout {
        source.currentPasteboard?.read() ?? ClipboardReadout(content: nil, isExcludedByType: false)
    }

    @discardableResult
    public func write(_ content: ClipboardContent) -> Int {
        source.currentPasteboard?.write(content) ?? 0
    }
}
