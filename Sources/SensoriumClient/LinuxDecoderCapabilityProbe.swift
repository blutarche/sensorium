#if canImport(CAVCodec)
import CAVCodec
import Foundation

/// Asks this machine's render nodes whether any of them can decode H.264 in
/// hardware. The answer decides one sentence at launch and nothing else:
/// software decode is always available, so a machine that answers `false`
/// still runs every session, and a probe that cannot open a single node
/// answers `false` rather than refusing anything.
///
/// Two things must both hold. libavcodec must open its own `h264` decoder,
/// the only one that decodes through a VA-API device; a build whose H.264
/// decoder is OpenH264 decodes on the CPU whatever the driver offers. And
/// the driver installed on this machine must offer an H.264 profile, which
/// is asked of libva directly, since libavcodec cannot say.
public struct LinuxDecoderCapabilityProbe: VideoDecodeCapabilities {
    /// The render nodes a Linux machine numbers its GPUs with. A machine with
    /// one GPU has `renderD128`; the rest are the next seven, which is as many
    /// as this needs to find one that answers.
    private static let renderNodeNumbers = 128...135

    public init() {}

    public func hasH264HardwareDecoder() -> Bool {
        ViewerDecoderSelection.decodesInHardware(
            decoderName: ViewerDecoderSelection.platformDecoderName,
            driverOffersH264: Self.renderNodeNumbers.contains { offersH264(atRenderNode: "/dev/dri/renderD\($0)") }
        )
    }

    private func offersH264(atRenderNode path: String) -> Bool {
        // Read-write, which is what a VA-API display over DRM needs even to
        // be queried; a node this user may not open is simply not one of
        // this machine's answers.
        let descriptor = open(path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        guard let display = vaGetDisplayDRM(descriptor) else { return false }
        var major: Int32 = 0
        var minor: Int32 = 0
        guard vaInitialize(display, &major, &minor) == VA_STATUS_SUCCESS else { return false }
        defer { vaTerminate(display) }

        let capacity = Int(vaMaxNumProfiles(display))
        guard capacity > 0 else { return false }
        var profiles = [VAProfile](repeating: VAProfileNone, count: capacity)
        var count: Int32 = 0
        guard vaQueryConfigProfiles(display, &profiles, &count) == VA_STATUS_SUCCESS else { return false }

        let offered = profiles.prefix(Int(max(0, min(count, Int32(capacity)))))
        return offered.contains { profile in
            profile == VAProfileH264Main
                || profile == VAProfileH264High
                || profile == VAProfileH264ConstrainedBaseline
        }
    }
}
#endif
