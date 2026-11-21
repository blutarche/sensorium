#if os(macOS)
import CoreMedia

/// One captured picture on its way to an encoder, as the host's shared
/// admission and session logic sees it. On macOS that is the sample buffer
/// ScreenCaptureKit delivers.
public typealias HostVideoFrame = CMSampleBuffer
#else
/// One captured picture on its way to an encoder, as the host's shared
/// admission and session logic sees it. Shared code only counts and gates
/// these and never looks inside, so a platform host carries its own payload
/// beside it rather than through this type.
public struct HostVideoFrame: Sendable {
    public init() {}
}
#endif

/// Swift does not allow a generic type's extension to add a stored property
/// — even one constrained to a single concrete `Frame` — so the actual
/// process-wide instance lives at file scope; `machineWide` below only exposes
/// it. A top-level `let` is initialised at most once, lazily, the first time
/// anything reads it, and that initialisation is already thread-safe.
private let machineWideHostVideoFrameGate = SharedEncodeAdmissionGate<HostVideoFrame>(
    capacity: SharedEncodeAdmissionGate<HostVideoFrame>.machineCapacity
)

extension SharedEncodeAdmissionGate where Frame == HostVideoFrame {
    /// The bound on this machine's media engines. Process-wide on purpose, and
    /// the one gate that legitimately is: the hardware it stands for belongs
    /// to the machine, so sessions must contend for it rather than each
    /// getting their own copy of it. Every *session* gate is per session and
    /// supplied by its owner instead — see `HostSessionController`. Tests that
    /// need to observe a bound in isolation construct their own instances.
    public static var machineWide: SharedEncodeAdmissionGate<HostVideoFrame> { machineWideHostVideoFrameGate }
}
