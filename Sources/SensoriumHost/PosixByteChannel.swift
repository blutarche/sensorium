import Foundation

public enum PosixByteChannelError: Error, Equatable {
    case closed
    case readFailed(Int32)
    case writeFailed(Int32)
}

/// A connected stream socket behind the same async surface the session loop
/// uses for NWConnection.
///
/// Exists because this OS build's NWListener cannot serve an accepted
/// connection when `requiredLocalEndpoint` is set — the accepted side inherits
/// the requirement, re-binds the listener's own endpoint, and dies with
/// EADDRINUSE before any byte moves. BSD sockets bind the tailnet address the
/// ordinary way, so the verification transport is served from them instead.
///
/// Blocking I/O on the caller's continuation-backed threads is deliberate:
/// one session, two directions, no throughput requirement beyond the encoder's.
public final class PosixByteChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32?
    /// Two concurrent `send` calls (the video path and the control path both
    /// write the same fd) must not interleave their partial-write loops. A
    /// dedicated serial queue gives that ordering for free: each `send`
    /// dispatches its blocking write loop onto it and suspends its caller via
    /// the continuation, so no cooperative-pool thread blocks while a large
    /// write drains -- only this queue's own thread does, one send at a time.
    /// `receive` stays on the concurrent global queue; serializing reads
    /// against writes would deadlock a socket's independent directions.
    private let sendQueue = DispatchQueue(label: "com.sensorium.host.posix-byte-channel.send")

    /// Takes ownership: the channel closes the descriptor exactly once.
    public init(ownedFileDescriptor: Int32) {
        fileDescriptor = ownedFileDescriptor
        // A viewer that vanishes mid-write must surface as EPIPE, not kill the
        // process with SIGPIPE.
        var noSigpipe: Int32 = 1
        setsockopt(ownedFileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    private var currentDescriptor: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return fileDescriptor
    }

    public func cancel() {
        lock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = nil
        lock.unlock()
        if let descriptor {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    public func send(_ data: Data) async throws {
        let descriptor = currentDescriptor
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async {
                guard let descriptor else {
                    continuation.resume(throwing: PosixByteChannelError.closed)
                    return
                }
                var remaining = data
                while !remaining.isEmpty {
                    let written = remaining.withUnsafeBytes { bytes in
                        write(descriptor, bytes.baseAddress, bytes.count)
                    }
                    if written > 0 {
                        remaining = remaining.dropFirst(written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        continuation.resume(throwing: PosixByteChannelError.writeFailed(errno))
                        return
                    }
                }
                continuation.resume()
            }
        }
    }

    /// Reads exactly `count` bytes or throws; a short read means the viewer went
    /// away and the session must end, exactly like the NWConnection path.
    public func receive(count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        let descriptor = currentDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let descriptor else {
                    continuation.resume(throwing: PosixByteChannelError.closed)
                    return
                }
                var collected = Data(capacity: count)
                var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
                while collected.count < count {
                    let wanted = min(buffer.count, count - collected.count)
                    let received = read(descriptor, &buffer, wanted)
                    if received > 0 {
                        collected.append(contentsOf: buffer[0..<received])
                    } else if received < 0 && errno == EINTR {
                        continue
                    } else if received == 0 {
                        continuation.resume(throwing: PosixByteChannelError.closed)
                        return
                    } else {
                        continuation.resume(throwing: PosixByteChannelError.readFailed(errno))
                        return
                    }
                }
                continuation.resume(returning: collected)
            }
        }
    }
}
