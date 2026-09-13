#if canImport(AppKit)
import AppKit
import Foundation

/// The real `NSPasteboard` behind `ClipboardPasteboard`. Deliberately the
/// thinnest possible glue: every decision — what may be sent, what may be
/// applied, what must never leave the machine, and how a loop is prevented —
/// lives in `ClipboardSyncEngine`, which has no AppKit dependency and is
/// verified against a fake pasteboard. Nothing here is exercised by the test
/// runners; a real pasteboard needs a window server session.
public final class SystemPasteboard: ClipboardPasteboard {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    /// Images are preferred over text: a copied screenshot often also offers a
    /// throwaway string flavour, and the picture is what was copied.
    public func read() -> ClipboardReadout {
        // Every item's types, not `pasteboard.types`, which reports the first
        // item only: a marker on any item marks the pasteboard.
        let itemTypeIdentifiers = pasteboard.pasteboardItems?.map { item in
            item.types.map(\.rawValue)
        }
        guard !ClipboardPolicy.isExcluded(itemTypeIdentifiers: itemTypeIdentifiers) else {
            return ClipboardReadout(content: nil, isExcludedByType: true)
        }
        if let png = pasteboard.data(forType: .png) {
            return ClipboardReadout(content: .image(format: .png, data: png), isExcludedByType: false)
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return ClipboardReadout(content: .image(format: .tiff, data: tiff), isExcludedByType: false)
        }
        if let text = pasteboard.string(forType: .string) {
            return ClipboardReadout(content: .text(text), isExcludedByType: false)
        }
        return ClipboardReadout(content: nil, isExcludedByType: false)
    }

    /// Reads the change count back after writing rather than trusting
    /// `clearContents()`'s return value: the engine's loop prevention only
    /// needs the count that a subsequent poll will observe, and reading it
    /// here is true whatever `setData`/`setString` do to the counter.
    @discardableResult
    public func write(_ content: ClipboardContent) -> Int {
        pasteboard.clearContents()
        switch content {
        case let .text(text):
            pasteboard.setString(text, forType: .string)
        case let .image(format, data):
            pasteboard.setData(data, forType: format == .png ? .png : .tiff)
        }
        return pasteboard.changeCount
    }
}
#endif
