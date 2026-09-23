#if canImport(AppKit)
import AppKit
import Foundation

/// The real `NSPasteboard` behind `ClipboardPasteboard`. Deliberately the
/// thinnest possible glue: every decision — what may be sent, what may be
/// applied, what must never leave the machine, and how a loop is prevented —
/// lives in `ClipboardSyncEngine`, which has no AppKit dependency and is
/// verified against a fake pasteboard. Only `pngData(fromTIFF:)` is exercised
/// by the test runners; a real pasteboard needs a window server session.
public final class SystemPasteboard: ClipboardPasteboard {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    /// Reads every form this project can send and leaves choosing between
    /// them to `ClipboardSyncEngine`. A TIFF is converted to PNG only if the
    /// engine asks for the image.
    public func read() -> ClipboardReadout {
        // Every item's types, not `pasteboard.types`, which reports the first
        // item only: a marker on any item marks the pasteboard.
        let itemTypeIdentifiers = pasteboard.pasteboardItems?.map { item in
            item.types.map(\.rawValue)
        }
        guard !ClipboardPolicy.isExcluded(itemTypeIdentifiers: itemTypeIdentifiers) else {
            return ClipboardReadout(text: nil, image: nil, firstItemTypeIdentifiers: [], isExcludedByType: true)
        }
        let loadImage: @Sendable () -> ClipboardImage?
        if let png = pasteboard.data(forType: .png) {
            loadImage = { ClipboardImage(format: .png, data: png) }
        } else if let tiff = pasteboard.data(forType: .tiff) {
            loadImage = {
                Self.pngData(fromTIFF: tiff).map { ClipboardImage(format: .png, data: $0) }
                    ?? ClipboardImage(format: .tiff, data: tiff)
            }
        } else {
            loadImage = { nil }
        }
        return ClipboardReadout(
            text: pasteboard.string(forType: .string),
            loadImage: loadImage,
            firstItemTypeIdentifiers: itemTypeIdentifiers?.first ?? [],
            hasItems: !(itemTypeIdentifiers ?? []).isEmpty,
            isExcludedByType: false
        )
    }

    /// TIFF on a pasteboard is usually uncompressed, often several times the
    /// size of the same picture as PNG. `nil` when the data is not an image
    /// AppKit can read.
    public static func pngData(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
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
