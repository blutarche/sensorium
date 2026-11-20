#if os(Linux)
import COpenSSL
import Foundation
import Glibc

/// What a bare OpenSSL QUIC client saw of a handshake with the server.
struct RawHandshakeOutcome: Sendable {
    let completed: Bool
    let negotiatedProtocol: String?
    /// The idle timeout the server asked for, from its transport parameters.
    let peerRequestedIdleTimeout: UInt64?
    let negotiatedIdleTimeout: UInt64?
}

/// A minimal client, independent of the viewer's, for the checks the
/// viewer cannot make: it offers any ALPN and reports the server's own
/// transport parameters. Certificates are not verified; pinning is the
/// viewer's job and has its own test.
func rawHandshake(port: UInt16, offering alpn: String) async -> RawHandshakeOutcome {
    await withCheckedContinuation { continuation in
        // The handshake blocks its thread until it finishes or fails.
        Thread.detachNewThread {
            continuation.resume(returning: blockingRawHandshake(port: port, offering: alpn))
        }
    }
}

private func blockingRawHandshake(port: UInt16, offering alpn: String) -> RawHandshakeOutcome {
    let failed = RawHandshakeOutcome(
        completed: false, negotiatedProtocol: nil, peerRequestedIdleTimeout: nil, negotiatedIdleTimeout: nil
    )
    defer { ERR_clear_error() }
    let descriptor = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
    guard descriptor >= 0 else { return failed }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        Glibc.close(descriptor)
        return failed
    }
    defer { Glibc.close(descriptor) }

    guard let context = SSL_CTX_new(OSSL_QUIC_client_method()) else { return failed }
    defer { SSL_CTX_free(context) }
    SSL_CTX_set_verify(context, SSL_VERIFY_NONE, nil)
    guard let connection = SSL_new(context) else { return failed }
    defer { SSL_free(connection) }

    var protocols = [UInt8(alpn.utf8.count)]
    protocols.append(contentsOf: Array(alpn.utf8))
    guard SSL_set_alpn_protos(connection, protocols, UInt32(protocols.count)) == 0,
          sensorium_ssl_set_tlsext_host_name(connection, "sensorium-host") == 1,
          let bio = BIO_new_dgram(descriptor, BIO_NOCLOSE),
          let peer = BIO_ADDR_new() else { return failed }
    defer { BIO_ADDR_free(peer) }
    let made = withUnsafeBytes(of: &address.sin_addr) {
        BIO_ADDR_rawmake(peer, AF_INET, $0.baseAddress, $0.count, address.sin_port)
    }
    SSL_set_bio(connection, bio, bio)
    guard made == 1, SSL_set1_initial_peer_addr(connection, peer) == 1 else { return failed }

    guard SSL_connect(connection) == 1 else { return failed }
    var selected: UnsafePointer<UInt8>?
    var length: UInt32 = 0
    SSL_get0_alpn_selected(connection, &selected, &length)
    let negotiated = selected.map {
        String(decoding: UnsafeBufferPointer(start: $0, count: Int(length)), as: UTF8.self)
    }
    var peerRequest: UInt64 = 0
    let hasPeerRequest = SSL_get_value_uint(
        connection, UInt32(SSL_VALUE_CLASS_FEATURE_PEER_REQUEST), UInt32(SSL_VALUE_QUIC_IDLE_TIMEOUT), &peerRequest
    ) == 1
    var settled: UInt64 = 0
    let hasSettled = SSL_get_value_uint(
        connection, UInt32(SSL_VALUE_CLASS_FEATURE_NEGOTIATED), UInt32(SSL_VALUE_QUIC_IDLE_TIMEOUT), &settled
    ) == 1
    return RawHandshakeOutcome(
        completed: true,
        negotiatedProtocol: negotiated,
        peerRequestedIdleTimeout: hasPeerRequest ? peerRequest : nil,
        negotiatedIdleTimeout: hasSettled ? settled : nil
    )
}
#endif
