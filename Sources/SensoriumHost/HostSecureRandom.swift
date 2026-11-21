import Foundation
#if os(macOS)
import Security
#endif

/// Unguessable bytes from the platform's own cryptographic source, for
/// tokens and resume tickets.
///
/// Fatal on failure rather than falling back to a weaker source: a host that
/// cannot draw random bytes cannot hand back anything actually unguessable,
/// and there is nothing it could do to recover.
package enum HostSecureRandom {
    package static func bytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        #if os(macOS)
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
        #else
        // `SystemRandomNumberGenerator` is the platform's own cryptographic
        // generator, and traps rather than return a weak value.
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
        #endif
    }
}
