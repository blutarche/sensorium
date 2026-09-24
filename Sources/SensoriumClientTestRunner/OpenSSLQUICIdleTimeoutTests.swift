#if canImport(COpenSSL)
import Foundation
import SensoriumClient

/// The one check that needs OpenSSL itself rather than a scripted session:
/// that the idle timeout the viewer configures is the one OpenSSL reports
/// back. No socket is opened; the value can only be set before a connection
/// is established, so it is read back from a fresh connection object.
func testOpenSSLQUICIdleTimeoutTests() {
    let requested = OpenSSLQUICIdleTimeout.requestedMilliseconds()
    expect(
        requested == 30_000,
        "the viewer asks OpenSSL for a 30 s QUIC idle timeout -- got \(String(describing: requested))"
    )
    print("PASS: the QUIC idle timeout OpenSSL reports back is the 30 s this viewer asked for")
}

/// The session thread must sleep on events, not on a clock. A read waiting on
/// a connection with nothing to read is the whole life of a session, so a
/// thread that retries on a fixed interval burns a core for as long as the
/// session lasts.
///
/// Nothing is dialled here: no `start(timeout:)` is called, so the session
/// opens no socket and the read simply waits. What is counted is how many
/// times the loop came back to try the read again.
func testOpenSSLSessionThreadIdleTests() async {
    let connection = OpenSSLQUICConnection(host: "host.invalid", port: 7443, tlsCertificateHash: nil)
    let reader = Task { try? await connection.receiveWirePacket() }
    try? await Task.sleep(for: .seconds(1))
    let attempts = connection.readProgressAttempts
    expect(
        attempts <= 2,
        "a second of waiting costs the session thread at most a couple of wake-ups -- got \(attempts)"
    )
    reader.cancel()
    await connection.close()
    print("PASS: a session thread with nothing to read waits on events rather than on a clock")
}
#else
/// Nothing to read back where OpenSSL's QUIC implementation is not the
/// transport.
func testOpenSSLQUICIdleTimeoutTests() {}
func testOpenSSLSessionThreadIdleTests() async {}
#endif
