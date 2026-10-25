import Foundation

/// One thing the person should know before they start, with a single button
/// that takes it away. Never a question, never a gate: whatever it describes,
/// the viewer behind it already works. Kept here rather than in a window so
/// every platform says the same thing.
public struct ViewerNotice: Equatable, Sendable {
    public let headline: String
    public let detail: String
    public let continueTitle: String

    public init(headline: String, detail: String, continueTitle: String) {
        self.headline = headline
        self.detail = detail
        self.continueTitle = continueTitle
    }
}

/// What this machine can decode video with. One question, asked once per
/// launch, because the answer is a property of the hardware and its drivers
/// rather than of a session.
public protocol VideoDecodeCapabilities: Sendable {
    /// Whether an H.264 stream can be decoded by hardware here. `false` means
    /// software decode, which works and costs more power.
    func hasH264HardwareDecoder() -> Bool
}

/// Everything the viewer tells the person at launch, before any machine has
/// been reached. The decision is a pure function of what the arguments asked
/// for and what this machine can do, so it is verified without a window.
public enum ViewerFirstRunNotices {
    public static let softwareDecode = ViewerNotice(
        headline: "This machine decodes video in software, which uses more power.",
        detail: "\(ViewerCopyWrapping.control("Session Diagnostics")) links to a guide for faster video.",
        continueTitle: "Continue"
    )

    @MainActor
    public static func showNotices(
        arguments: [String], capabilities: any VideoDecodeCapabilities,
        acknowledgements: ViewerFirstRunNoticeStore,
        show: @MainActor (ViewerNotice) async -> Void
    ) async {
        for notice in notices(arguments: arguments, capabilities: capabilities, acknowledgements: acknowledgements) {
            await show(notice)
            acknowledgements.acknowledgeSoftwareDecode()
        }
    }

    /// The notices this launch should show, in order. Empty for a run that is
    /// only printing its usage or tracing a session: neither opens a window to
    /// show one in, and the decoder probe opens a device node that such a run
    /// has no reason to touch.
    public static func notices(
        arguments: [String],
        capabilities: any VideoDecodeCapabilities,
        acknowledgements: ViewerFirstRunNoticeStore? = nil
    ) -> [ViewerNotice] {
        guard !arguments.contains("--help"), !arguments.contains("--trace") else { return [] }
        guard acknowledgements?.hasAcknowledgedSoftwareDecode() != true else { return [] }
        return capabilities.hasH264HardwareDecoder() ? [] : [softwareDecode]
    }
}

/// Acknowledgements in the viewer's Application Support directory, written
/// atomically with the same owner-only file policy as the strip's pin memory.
public struct ViewerFirstRunNoticeStore: Sendable {
    private let url: URL
    private struct Record: Codable {
        let softwareDecode: Bool
    }

    public init(url: URL) { self.url = url }

    public func hasAcknowledgedSoftwareDecode() -> Bool {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        return record.softwareDecode
    }

    public func acknowledgeSoftwareDecode() {
        guard let data = try? JSONEncoder().encode(Record(softwareDecode: true)) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
