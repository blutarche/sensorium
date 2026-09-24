import Foundation
import SensoriumClient
import SensoriumCore

/// The dial decisions every viewer transport shares, verified where every
/// viewer transport runs. They used to be reachable only through the
/// Network.framework conformer, so nothing checked them on a platform that
/// has no such framework.
func testClientControlDialingTests() {
    let leaf = Data("one host's self-signed leaf".utf8)
    expect(
        ClientControlDialing.certificatePinMatches(
            certificateDER: leaf,
            expectedHash: HostTLSIdentity.certificateHash(for: leaf)
        ),
        "the pin recorded at pairing matches the certificate it was taken from"
    )
    expect(
        !ClientControlDialing.certificatePinMatches(
            certificateDER: Data("a different machine's leaf".utf8),
            expectedHash: HostTLSIdentity.certificateHash(for: leaf)
        ),
        "a different certificate does not match the pin"
    )

    expect(
        ClientControlDialing.resolveDialError(
            .failed(NetworkControlConnectionError.peerFailed),
            pinMismatchObserved: true
        ) as? NetworkControlConnectionError == .certificatePinMismatch,
        "an observed pin mismatch outranks whatever error the dial itself produced"
    )
    expect(
        ClientControlDialing.resolveDialError(
            .failed(NetworkControlConnectionError.peerFailed),
            pinMismatchObserved: false
        ) as? NetworkControlConnectionError == .peerFailed,
        "absent a mismatch, the dial's own error passes through unchanged"
    )
    expect(
        ClientControlDialing.resolveDialError(.timedOut, pinMismatchObserved: false)
            as? NetworkControlConnectionError == .timedOut,
        "a dial that ran out of time reports the deadline"
    )
    print("PASS: the shared dial decisions hold on every platform")

    expect(
        ViewerPairingOutcome.classify(NetworkControlConnectionError.timedOut) == .unreachable,
        "a pairing dial that timed out reads as an unreachable machine"
    )
    expect(
        ViewerPairingOutcome.classify(NetworkControlConnectionError.certificatePinMismatch) == .unverifiedHost,
        "a pairing dial refused on the pin reads as an unverified host"
    )
    expect(
        ViewerSessionFailure.classify(NetworkControlConnectionError.certificatePinMismatch) == .unverifiedHost,
        "a session refused on the pin reads as an unverified host"
    )
    expect(
        ViewerSessionFailure.classify(NetworkControlConnectionError.closed) == .unreachable,
        "a session whose transport closed reads as an unreachable machine"
    )
    print("PASS: a transport error reads the same way on every platform")
}
