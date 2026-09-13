import Foundation

/// The image encodings clipboard sync carries. Deliberately only two: PNG and
/// TIFF are what macOS actually puts on a pasteboard for a copied image, and
/// every other pasteboard flavour (rich text, file promises, app-private
/// types) is out of scope — v1 has no file transfer.
public enum ClipboardImageFormat: String, Equatable, Sendable {
    case png
    case tiff
}

/// One clipboard payload, in the only two shapes this project syncs.
///
/// `description`/`debugDescription` deliberately report kind and size instead
/// of the payload: a clipboard routinely holds a credential a password
/// manager put there, so interpolating one of these values into a log line
/// must not be able to leak it.
public enum ClipboardContent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case text(String)
    case image(format: ClipboardImageFormat, data: Data)

    /// Bytes as they travel: the payload length, not the character count.
    public var byteCount: Int {
        switch self {
        case let .text(text):
            text.utf8.count
        case let .image(_, data):
            data.count
        }
    }

    /// The only description of a clipboard payload anything in this project is
    /// allowed to log.
    public var logDescription: String {
        switch self {
        case .text:
            "text, \(byteCount) bytes"
        case let .image(format, _):
            "image/\(format.rawValue), \(byteCount) bytes"
        }
    }

    public var description: String { logDescription }

    public var debugDescription: String { logDescription }
}

/// Why a clipboard payload was not sent or not applied. Carries sizes and
/// reasons, never content.
public enum ClipboardRefusal: Equatable, Sendable {
    case syncDisabled
    /// The pasteboard is marked as something that must not be copied off this
    /// machine — see `ClipboardPolicy.excludedTypeIdentifiers`.
    case excludedType
    case tooLarge(byteCount: Int, limit: Int)
    /// The pasteboard holds something this project does not sync, e.g. a rich
    /// or app-private flavour with no plain text or image alongside it.
    case unsupportedContent
    /// A clipboard arrived on a connection that has not authenticated and
    /// created a canvas — a pairing-only session, or one still handshaking.
    case sessionNotActive

    public var logReason: String {
        switch self {
        case .syncDisabled:
            "clipboard sync is off"
        case .excludedType:
            "the pasteboard is marked concealed, transient, or a file reference"
        case let .tooLarge(byteCount, limit):
            "\(byteCount) bytes is over the \(limit)-byte clipboard limit"
        case .unsupportedContent:
            "the pasteboard holds no plain text or image"
        case .sessionNotActive:
            "the session is not authenticated with an active canvas"
        }
    }
}

public enum ClipboardPolicy {
    /// The largest clipboard payload that will be sent or applied.
    ///
    /// Chosen against what shares the wire, not against what a pasteboard can
    /// hold: the same connection carries 60 fps video, and a clipboard write
    /// is a single blocking send ahead of the next frame. 1 MiB covers
    /// ordinary copied text and a typical screenshot while bounding that stall
    /// to a fraction of the 4 MiB a single video frame is already allowed.
    /// Anything larger is refused with a reason rather than truncated.
    public static let maximumContentBytes = 1024 * 1024

    /// macOS has no pasteboard-change notification, so `changeCount` must be
    /// polled. 200 ms puts worst-case detection inside the window where a
    /// copy here and a paste there still feels immediate, at five reads of one
    /// integer per second — orders of magnitude below the per-frame work the
    /// same process is already doing.
    public static let pollIntervalSeconds: Double = 0.2

    /// The shortest interval between two writes of a received clipboard onto
    /// this machine's pasteboard.
    ///
    /// The send side is already floored at `pollIntervalSeconds`, so an honest
    /// peer never offers clipboards faster than this and never meets the
    /// limit; a peer that does is writing the user's real pasteboard, on the
    /// main actor, ahead of the workspace and the capture pipeline. Applies
    /// inside the interval are coalesced rather than dropped: a peer sends
    /// only when its pasteboard changes and never re-offers, so a dropped
    /// clipboard is gone, whereas a coalesced one still lands the newest
    /// thing the user copied.
    public static let minimumApplyIntervalSeconds: Double = pollIntervalSeconds

    /// Pasteboard type identifiers whose presence means "do not copy this off
    /// this machine".
    ///
    /// The three `org.nspasteboard.*` markers are the community convention
    /// (nspasteboard.org) that password managers and clipboard managers
    /// actually use; macOS itself exposes no concealed or transient flag on
    /// `NSPasteboard`. Honouring them is therefore best effort — an app that
    /// sets none of them is indistinguishable from any other copy — which is
    /// why clipboard sync is opt-in rather than on by default.
    ///
    /// `public.file-url` is here for a different reason: a Finder copy is a
    /// file reference, and file transfer is an explicit v1 non-goal. Skipping
    /// it beats pasting a path that means nothing on the other machine.
    public static let excludedTypeIdentifiers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "public.file-url"
    ]

    /// Whether a pasteboard holding these items must not be copied off this
    /// machine. `itemTypeIdentifiers` is every item's own type list, not just
    /// the first item's: a clipboard manager can put its marker on any item,
    /// and one marked item marks the pasteboard.
    ///
    /// `nil` means the items could not be read, which refuses — a pasteboard
    /// whose markers could not be checked is indistinguishable from a marked
    /// one, and the wrong answer here leaves the machine.
    public static func isExcluded(itemTypeIdentifiers: [[String]]?) -> Bool {
        guard let itemTypeIdentifiers else {
            return true
        }
        return itemTypeIdentifiers.contains { item in
            item.contains { excludedTypeIdentifiers.contains($0) }
        }
    }
}

/// Wire format for a clipboard payload. Binary rather than the JSON control
/// frame: an image is megabytes, the control frame is capped at 64 KiB, and
/// base64 inside JSON would inflate it further.
///
/// ```text
/// +---------+--------+--------------+---------------+--------+---------+
/// | magic:4 | kind:1 | formatLen:1  | payloadLen:4  | format | payload |
/// +---------+--------+--------------+---------------+--------+---------+
/// ```
public enum ClipboardPacketCodec {
    /// "CLIP".
    private static let magic: UInt32 = 0x434C_4950
    private static let headerLength = 4 + 1 + 1 + 4
    private static let textKind: UInt8 = 0
    private static let imageKind: UInt8 = 1

    public static func encode(_ content: ClipboardContent) throws -> Data {
        let kind: UInt8
        let format: Data
        let payload: Data
        switch content {
        case let .text(text):
            kind = textKind
            format = Data()
            payload = Data(text.utf8)
        case let .image(imageFormat, data):
            kind = imageKind
            format = Data(imageFormat.rawValue.utf8)
            payload = data
        }
        guard payload.count <= ClipboardPolicy.maximumContentBytes else {
            throw SensoriumProtocolError.frameTooLarge
        }
        var output = Data()
        appendBigEndian(magic, to: &output)
        output.append(kind)
        output.append(UInt8(format.count))
        appendBigEndian(UInt32(payload.count), to: &output)
        output.append(format)
        output.append(payload)
        return output
    }

    public static func decode(_ data: Data) throws -> ClipboardContent {
        guard data.count >= headerLength else {
            throw SensoriumProtocolError.frameTooShort
        }
        guard readUInt32(data, at: 0) == magic else {
            throw SensoriumProtocolError.malformedMessage
        }
        let kind = data[data.startIndex + 4]
        let formatLength = Int(data[data.startIndex + 5])
        let payloadLength = Int(readUInt32(data, at: 6))
        // Checked before the length equality below so an oversize claim is
        // reported as oversize rather than as a mismatch.
        guard payloadLength <= ClipboardPolicy.maximumContentBytes else {
            throw SensoriumProtocolError.frameTooLarge
        }
        guard data.count == headerLength + formatLength + payloadLength else {
            throw SensoriumProtocolError.frameLengthMismatch
        }
        let format = Data(data.dropFirst(headerLength).prefix(formatLength))
        let payload = Data(data.dropFirst(headerLength + formatLength))
        switch kind {
        case textKind:
            guard formatLength == 0, let text = String(data: payload, encoding: .utf8) else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .text(text)
        case imageKind:
            guard let rawFormat = String(data: format, encoding: .utf8),
                  let imageFormat = ClipboardImageFormat(rawValue: rawFormat) else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .image(format: imageFormat, data: payload)
        default:
            throw SensoriumProtocolError.malformedMessage
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
