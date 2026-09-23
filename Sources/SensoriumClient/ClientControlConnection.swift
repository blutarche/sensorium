import Foundation
import SensoriumCore

/// Which transport the viewer dials. `tcpLocalVerification` matches the host's
/// mode of the same name: a single machine cannot hairpin QUIC through the
/// tailnet interface, so the live verification session runs over TCP. The
/// Ed25519 handshake and signed canvas are unchanged; only TLS is absent, which
/// is why the mode is explicit and never a fallback.
public enum ClientTransportKind: String, Equatable, Sendable {
    case quic
    case tcpLocalVerification
}

/// Named for the first conformer rather than for the framework: the viewer's
/// copy tables, its pairing outcomes and its session failure lines all switch
/// over these cases, and every platform's dial reports the same five.
public enum NetworkControlConnectionError: Error, Equatable {
    case notReady
    case closed
    case peerFailed
    case timedOut
    /// The host answered but presented a certificate other than the one
    /// pinned at pairing. TLS tears the connection down without saying why it
    /// rejected the certificate, so this is reported only when the verify
    /// block itself observed the mismatch.
    case certificatePinMismatch
}

/// Records whether the TLS verify block rejected the host's certificate
/// against the pin, so `start(timeout:)` can tell that failure apart from
/// every other way a dial ends. The block runs on TLS's own queue, which may
/// outlive the dial that started it, so recording is locked rather than
/// assumed single-threaded.
public final class PinMismatchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var mismatchObserved = false

    public init() {}

    public func recordMismatch() {
        lock.lock()
        mismatchObserved = true
        lock.unlock()
    }

    public var observed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mismatchObserved
    }
}

/// One dial attempt ends in exactly one of these ways: the machine or route
/// produced its own error (which also covers a local cancellation, already
/// turned into `NetworkControlConnectionError.peerFailed` before it reaches
/// here), or the dial's own deadline ran out first.
public enum DialTermination {
    case failed(any Error)
    case timedOut
}

/// The decisions every viewer transport makes the same way, whichever
/// platform's QUIC stack is underneath: how long silence is allowed to last,
/// whether a certificate matches its pin, and which error one dial reports.
public enum ClientControlDialing {
    /// The viewer sends a clock-sync message roughly every ten seconds while
    /// a session is live, so this much true silence means the link is dead,
    /// not merely quiet. Not the transport's own idle timeout: that fires
    /// only once the OS itself gives up on the socket, which in the field
    /// can run far longer than this.
    public static let defaultHostSilenceTimeout: Duration = .seconds(30)

    public static func certificatePinMatches(certificateDER: Data, expectedHash: Data) -> Bool {
        HostTLSIdentity.certificateHash(for: certificateDER) == expectedHash
    }

    /// Given how a dial ended and whether the TLS verify block saw the
    /// host's certificate fail to match the pin, decides which error the
    /// caller reports. A pin mismatch always wins: a TLS stack tears the
    /// connection down without saying why it rejected the certificate, so a
    /// mismatch the verify block itself observed is the only place that
    /// reason survives. Absent a mismatch, the dial's own error passes
    /// through unchanged.
    public static func resolveDialError(
        _ termination: DialTermination,
        pinMismatchObserved: Bool
    ) -> any Error {
        guard !pinMismatchObserved else {
            return NetworkControlConnectionError.certificatePinMismatch
        }
        switch termination {
        case let .failed(error): return error
        case .timedOut: return NetworkControlConnectionError.timedOut
        }
    }
}

/// What the viewer needs of a control connection beyond reading and writing
/// packets: dialling it with a deadline, and arming the silence watch once a
/// session is live. Every platform's QUIC stack conforms, so the session
/// runner names this rather than the one implementation it happened to be
/// written against.
public protocol ClientControlConnection: SensoriumControlTransport {
    func start(timeout: TimeInterval) async throws
    /// Video and clipboard travel the same stream as control, so a session
    /// writes whole transport packets as well as control messages.
    func send(_ packet: SensoriumTransportPacket) async throws
    func beginHostSilenceWatch()
    func endHostSilenceWatch()
}
