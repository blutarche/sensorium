import Foundation

/// Whether macOS's own Screen Sharing service was found on, as far as this
/// host has looked.
public enum ScreenSharingStatus: Equatable, Sendable {
    /// No probe has answered yet. Nothing is asked of the person at this
    /// machine until one has found the service off.
    case notChecked
    case on
    case off
}

/// Answers whether Screen Sharing is on. Blocking; callers run it off the main
/// actor. A seam so tests never touch a socket.
public protocol ScreenSharingProbing: Sendable {
    func isScreenSharingOn() -> Bool
}

/// Finds out whether Screen Sharing is on the one way public behavior allows:
/// macOS's own service listens on TCP port 5900, so a loopback connection
/// that is accepted means it is on, and one refused or unanswered means it is
/// off. The connection is closed as soon as it opens; nothing is sent or
/// read, so no RFB is ever spoken. Only ever this machine's own loopback
/// address and that one port.
///
/// Something else bound to loopback port 5900 would read as on. No public API
/// tells the two apart, and the alert this feeds only ever asks a person to
/// turn a switch on.
public struct LoopbackScreenSharingProbe: ScreenSharingProbing {
    public static let address = "127.0.0.1"
    public static let port: UInt16 = 5900
    /// Loopback answers at once whether or not anything listens; this only
    /// bounds a machine too busy to.
    public static let timeoutSeconds: Double = 1

    /// The socket, behind a seam so a test can see where it would connect
    /// without opening one.
    private let connect: @Sendable (String, UInt16, Double) -> Bool

    public init(
        connect: @escaping @Sendable (String, UInt16, Double) -> Bool = LoopbackScreenSharingProbe.connectAndClose
    ) {
        self.connect = connect
    }

    public func isScreenSharingOn() -> Bool {
        connect(Self.address, Self.port, Self.timeoutSeconds)
    }

    /// A non-blocking connect, waited on with `poll` because `SO_SNDTIMEO`
    /// does not bound `connect` here. True only when the connection was
    /// accepted; closed before returning either way.
    @Sendable
    public static func connectAndClose(address: String, port: UInt16, timeoutSeconds: Double) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            return false
        }
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pollDescriptor, 1, Int32(timeoutSeconds * 1000))
        guard ready == 1 else {
            return false
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }
}
