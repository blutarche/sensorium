import Foundation

/// The image encodings clipboard sync carries. Deliberately only two: PNG and
/// TIFF are what macOS actually puts on a pasteboard for a copied image, and
/// every other pasteboard flavour (rich text, file promises, app-private
/// types) is out of scope — v1 has no file transfer.
public enum ClipboardImageFormat: String, CaseIterable, Equatable, Sendable {
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
    /// A clipboard arrived on a connection that has no authenticated,
    /// granted session: a pairing-only connection, one still handshaking,
    /// or one whose session has ended.
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
            "the connection has no granted session"
        }
    }
}

extension ClipboardRefusal {
    /// The token `SensoriumMessage.clipboardRefused` carries on the wire.
    public var wireToken: String {
        switch self {
        case .syncDisabled:
            "sync-disabled"
        case .excludedType:
            "excluded-type"
        case .tooLarge:
            "too-large"
        case .unsupportedContent:
            "unsupported-content"
        case .sessionNotActive:
            "session-not-active"
        }
    }

    /// `nil` for a token this build does not know, and for `too-large`
    /// without two non-negative sizes.
    public init?(wireToken: String, byteCount: Int?, limit: Int?) {
        switch wireToken {
        case "sync-disabled":
            self = .syncDisabled
        case "excluded-type":
            self = .excludedType
        case "too-large":
            guard let byteCount, let limit, byteCount >= 0, limit >= 0 else {
                return nil
            }
            self = .tooLarge(byteCount: byteCount, limit: limit)
        case "unsupported-content":
            self = .unsupportedContent
        case "session-not-active":
            self = .sessionNotActive
        default:
            return nil
        }
    }
}

public enum ClipboardPolicy {
    /// The largest clipboard payload that will be sent or applied: whatever
    /// one transport packet can carry after the clipboard header, about
    /// 4 MiB.
    ///
    /// A clipboard travels as one packet on the same connection as the
    /// video, so this is also the longest stall one can put ahead of the next
    /// frame, and it is no longer than a single video frame is already
    /// allowed to cause. Anything larger is refused with a reason rather than
    /// truncated.
    public static let maximumContentBytes =
        SensoriumTransportPacketCodec.maximumPayloadLength - ClipboardPacketCodec.maximumHeaderLength

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
    /// `NSPasteboard`. Honouring them is therefore best effort: an app that
    /// sets none of them is indistinguishable from any other copy.
    ///
    /// `public.file-url` is here for a different reason: a Finder copy is a
    /// file reference, and file transfer is an explicit v1 non-goal. Skipping
    /// it beats pasting a path that means nothing on the other machine.
    public static let excludedTypeIdentifiers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "public.file-url",
        // KDE's and KeePassXC's Wayland password-manager marker mime type.
        "x-kde-passwordManagerHint"
    ]

    /// Pasteboard types that mean "this copy has a text form", plain or rich.
    /// Only plain text is ever sent, but a rich form listed ahead of an
    /// image still says the copying app considers the copy text. The mime
    /// types are the same forms as a Wayland offer names them.
    public static let textTypeIdentifiers: Set<String> = [
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
        "public.plain-text",
        "public.rtf",
        "com.apple.flat-rtfd",
        "public.html",
        "text/plain;charset=utf-8",
        "text/plain;charset=UTF-8",
        "text/plain",
        "UTF8_STRING",
        "text/rtf",
        "text/html"
    ]

    /// Pasteboard types that mean "this copy has an image form" this project
    /// can send.
    public static let imageTypeIdentifiers: Set<String> = [
        "public.png",
        "public.tiff",
        "image/png"
    ]

    /// Whether a copy offering both forms should be sent as its image.
    /// Follows the copying app's own order for the first item: a screenshot
    /// lists its image first, a spreadsheet lists its text first. With no
    /// order to go by, the image wins, since a copy that has one usually is
    /// a picture.
    public static func prefersImage(firstItemTypeIdentifiers: [String]) -> Bool {
        let firstText = firstItemTypeIdentifiers.firstIndex { textTypeIdentifiers.contains($0) }
        let firstImage = firstItemTypeIdentifiers.firstIndex { imageTypeIdentifiers.contains($0) }
        switch (firstText, firstImage) {
        case let (.some(text), .some(image)):
            return image < text
        case (.some, nil):
            return false
        default:
            return true
        }
    }

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
    /// The header plus the longest format name any payload can carry.
    public static let maximumHeaderLength =
        headerLength + ClipboardImageFormat.allCases.map { $0.rawValue.utf8.count }.max()!
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
