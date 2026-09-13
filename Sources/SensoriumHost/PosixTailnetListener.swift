import Foundation

public enum PosixTailnetListenerError: Error, Equatable {
    case nonTailnetBindAddress
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// TCP listener for the local-verification transport, on BSD sockets.
///
/// Binds exactly one tailnet IPv4 address and one port — never a wildcard —
/// and validates the address against the Tailscale ranges before any socket
/// call. Accepted connections are re-checked against the same source policy.
public final class PosixTailnetListener: @unchecked Sendable {
    private let socketDescriptor: Int32
    private let acceptQueue = DispatchQueue(label: "com.sensorium.posix-listener")
    private let stateLock = NSLock()
    private var isStopped = false

    public let boundAddress: String
    public let boundPort: UInt16

    public init(tailnetAddress: String, port: UInt16) throws {
        guard SourceAddressPolicy.isTailnetSource(tailnetAddress) else {
            throw PosixTailnetListenerError.nonTailnetBindAddress
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, tailnetAddress, &address.sin_addr) == 1 else {
            throw PosixTailnetListenerError.nonTailnetBindAddress
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PosixTailnetListenerError.socketFailed(errno)
        }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw PosixTailnetListenerError.bindFailed(code)
        }
        guard listen(descriptor, 4) == 0 else {
            let code = errno
            close(descriptor)
            throw PosixTailnetListenerError.listenFailed(code)
        }
        socketDescriptor = descriptor
        boundAddress = tailnetAddress
        boundPort = port
    }

    /// Accept loop. A non-tailnet source is closed before any session state
    /// exists, mirroring the QUIC listener's accept-time check.
    public func start(onConnection: @escaping @Sendable (PosixByteChannel) -> Void) {
        acceptQueue.async { [self] in
            while true {
                var peer = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let accepted = withUnsafeMutablePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                        accept(socketDescriptor, raw, &length)
                    }
                }
                guard accepted >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &peer.sin_addr, &host, socklen_t(host.count))
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let source = String(decoding: bytes, as: UTF8.self)
                guard SourceAddressPolicy.isTailnetSource(source) else {
                    close(accepted)
                    continue
                }
                onConnection(PosixByteChannel(ownedFileDescriptor: accepted))
            }
        }
    }

    public func stop() {
        stateLock.lock()
        let alreadyStopped = isStopped
        isStopped = true
        stateLock.unlock()
        guard !alreadyStopped else { return }
        close(socketDescriptor)
    }
}
