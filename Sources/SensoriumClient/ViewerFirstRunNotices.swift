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
        headline: "This machine has no hardware video decoder Sensorium can use, so it will decode in "
            + "software and use more power.",
        detail: "Fedora leaves the decoder out; it comes from the RPM Fusion package named "
            + "mesa-va-drivers-freeworld.",
        continueTitle: "Continue"
    )

    /// The notices this launch should show, in order. Empty for a run that is
    /// only printing its usage or tracing a session: neither opens a window to
    /// show one in, and the decoder probe opens a device node that such a run
    /// has no reason to touch.
    public static func notices(
        arguments: [String],
        capabilities: any VideoDecodeCapabilities
    ) -> [ViewerNotice] {
        guard !arguments.contains("--help"), !arguments.contains("--trace") else { return [] }
        return capabilities.hasH264HardwareDecoder() ? [] : [softwareDecode]
    }
}
