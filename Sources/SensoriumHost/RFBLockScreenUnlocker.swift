import CommonCrypto
import CryptoKit
import Foundation
import Security
import SensoriumCore
import SystemConfiguration

/// Unlocks this Mac's locked login window on the viewer operator's behalf, by
/// typing the login password into the login window through the built-in
/// screen-sharing service (screensharingd) over a loopback RFB connection.
///
/// This route rather than the ordinary CGEvent injector because Secure Event
/// Input blocks synthesized key events at the login window: screensharingd is
/// the one path macOS itself leaves open there. The password is used for one
/// unlock and is never written to disk and never logged; every buffer this code
/// builds from it -- the credential block and the byte copy behind it -- is
/// zeroed as soon as the credentials are sent.
///
/// Provenance: the RFB security-type-30 handshake this speaks -- Diffie-
/// Hellman key agreement, AES-128-ECB with a key derived as MD5 of the shared
/// secret, the 128-byte credential block's layout, and the KeyEvent message
/// framing -- was derived independently from the public RFB protocol
/// specification, never from another implementation's source.
///
/// Out of scope: FileVault's pre-login, cold-boot unlock screen.
/// screensharingd is not running there, so this only ever reaches a Mac that
/// is already past FileVault and sitting at its ordinary login window, locked.
///
/// Operator note: turning on the built-in screen-sharing service this speaks
/// to makes port 5900 listen on every interface, not only loopback -- that is
/// the operating system's own service, not this code's. Sensorium opens no
/// listener of its own for this and only ever connects out, to 127.0.0.1.
public protocol LockScreenUnlocking: Sendable {
    func unlock(password: Data) async -> HostScreenUnlockOutcome
}

/// The bytes of one RFB connection, behind a seam so the handshake and the
/// message encoding can be driven against scripted server bytes without a live
/// screensharingd or a locked screen -- neither of which a unit test can
/// produce. The real channel is a blocking loopback socket; a fake feeds
/// scripted reads and records writes.
package protocol RFBByteChannel: AnyObject {
    /// Reads exactly `count` bytes, or throws if the connection ends first.
    func read(_ count: Int) throws -> Data
    func write(_ data: Data) throws
    func close()
}

package enum RFBClientError: Error, Equatable {
    /// The connection ended before the handshake could finish, or could not be
    /// opened at all.
    case connectionClosed
    /// The server did not offer security type 30 (Apple authentication): the
    /// only type this client can use among those the built-in screen-sharing
    /// service offers on the macOS releases this was tested against.
    case securityTypeUnavailable
    /// The server refused the credentials: a wrong login password.
    case authenticationRejected
    /// The server sent something this client cannot parse.
    case protocolViolation
    /// The system CSPRNG did not report success. Surfaced rather than
    /// proceeding with whatever `SecRandomCopyBytes` left in the buffer -- a
    /// zero-filled draw would otherwise silently become the DH private
    /// exponent or the credential block's random padding.
    case secureRandomUnavailable
}

/// An RFB client speaking Apple's security type 30 (Diffie-Hellman key
/// agreement, then AES-128-ECB over a fixed credential block). Clean-room from
/// the public protocol description. The big-integer modular exponentiation is
/// this project's own native `modularExponentiation`; MD5 and AES come from
/// Apple's public CryptoKit and CommonCrypto.
package struct RFBType30Client {
    let channel: RFBByteChannel
    /// Injectable so a test can pin the client's private DH exponent and the
    /// credential block's random fill and get deterministic emitted bytes, or
    /// make the draw fail to prove the failure path never falls back to a
    /// zero-filled buffer. Production draws from the system CSPRNG and
    /// throws rather than returning one on failure.
    let randomBytes: (Int) throws -> [UInt8]

    package init(
        channel: RFBByteChannel,
        randomBytes: @escaping (Int) throws -> [UInt8] = RFBType30Client.systemRandomBytes
    ) {
        self.channel = channel
        self.randomBytes = randomBytes
    }

    /// The system CSPRNG, its status checked: anything but `errSecSuccess`
    /// throws instead of handing back the buffer `SecRandomCopyBytes` leaves
    /// behind on failure, which is still all zero.
    static func systemRandomBytes(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else {
            throw RFBClientError.secureRandomUnavailable
        }
        return buffer
    }

    package static let returnKeysym: UInt32 = 0xFF0D

    /// The X11 keysym for one unicode scalar, by the RFB rule: a scalar below
    /// 0x100 is its own keysym, anything higher is `0x01000000 + scalar`.
    package static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        scalar.value < 0x100 ? scalar.value : 0x01000000 + scalar.value
    }

    /// One RFB KeyEvent message (type 4): the down flag, two pad bytes, and the
    /// keysym as a 4-byte big-endian integer.
    package static func keyEventMessage(keysym: UInt32, down: Bool) -> Data {
        var message = Data([4, down ? 1 : 0, 0, 0])
        var bigEndian = keysym.bigEndian
        withUnsafeBytes(of: &bigEndian) { message.append(contentsOf: $0) }
        return message
    }

    package func sendKeyEvent(keysym: UInt32, down: Bool) throws {
        try channel.write(Self.keyEventMessage(keysym: keysym, down: down))
    }

    /// Runs the RFB 003.008 handshake, selects security type 30, performs the
    /// Apple DH+AES authentication with the given credentials, and completes
    /// ClientInit/ServerInit so the connection is ready for KeyEvent messages.
    ///
    /// `password` is copied into the credential block and that copy is zeroed
    /// before this returns; nothing here logs it.
    package func authenticate(username: String, password: Data) throws {
        // A throwaway draw, checked before anything at all is written to the
        // wire: a broken CSPRNG must fail right here, not after the version
        // and security-type negotiation already went out.
        _ = try randomBytes(1)

        // ProtocolVersion: read the server's 12-byte banner, answer 3.8.
        _ = try channel.read(12)
        try channel.write(Data("RFB 003.008\n".utf8))

        // Security types on offer.
        let typeCount = Int(try readByte())
        if typeCount == 0 {
            // A zero count is a refusal with a reason string following.
            _ = try? readFailureReason()
            throw RFBClientError.securityTypeUnavailable
        }
        let types = try channel.read(typeCount)
        guard types.contains(30) else {
            throw RFBClientError.securityTypeUnavailable
        }
        try channel.write(Data([30]))

        // Apple DH parameters: generator (2 bytes), key length (2 bytes),
        // prime (keyLen bytes), server public value (keyLen bytes).
        let header = try channel.read(4)
        let generator = beUInt16(header, 0)
        let keyLen = Int(beUInt16(header, 2))
        guard keyLen > 0, keyLen <= 1024 else {
            throw RFBClientError.protocolViolation
        }
        let prime = [UInt8](try channel.read(keyLen))
        let serverPublic = [UInt8](try channel.read(keyLen))

        // Client key pair and shared secret.
        var privateExponent = try randomBytes(keyLen)
        defer { zero(&privateExponent) }
        let generatorBytes = [UInt8(generator >> 8), UInt8(generator & 0xFF)]
        let clientPublic = leftPadded(
            modularExponentiation(base: generatorBytes, exponent: privateExponent, modulus: prime),
            to: keyLen
        )
        var shared = leftPadded(
            modularExponentiation(base: serverPublic, exponent: privateExponent, modulus: prime),
            to: keyLen
        )
        defer { zero(&shared) }

        // AES-128 key is MD5 of the shared secret.
        var aesKey = Array(Insecure.MD5.hash(data: Data(shared)))
        defer { zero(&aesKey) }

        var credentials = try credentialBlock(username: username, password: password)
        defer { zero(&credentials) }
        let ciphertext = try aesECBEncrypt(credentials, key: aesKey)

        try channel.write(Data(ciphertext))
        try channel.write(Data(clientPublic))

        // SecurityResult: zero is success; anything else is a rejection with a
        // reason string following under 3.8.
        let securityResult = try readUInt32()
        if securityResult != 0 {
            _ = try? readFailureReason()
            throw RFBClientError.authenticationRejected
        }

        // ClientInit (shared session) then ServerInit, whose trailing name is
        // read and discarded so the byte stream is left at the message
        // boundary a KeyEvent starts on.
        try channel.write(Data([1]))
        let serverInit = try channel.read(24)
        let nameLength = Int(beUInt32(serverInit, 20))
        // Bounded the same way `readFailureReason`'s length is: a hostile or
        // corrupt value must not turn into an unbounded allocation and read.
        guard nameLength < 4096 else {
            throw RFBClientError.protocolViolation
        }
        if nameLength > 0 {
            _ = try channel.read(nameLength)
        }
    }

    /// The 128-byte Apple credential block: random-filled, then username at
    /// offset 0 and password at offset 64, each NUL-terminated and truncated to
    /// 63 bytes so its terminator always fits.
    private func credentialBlock(username: String, password: Data) throws -> [UInt8] {
        var block = try randomBytes(128)
        let usernameBytes = Array(username.utf8)
        var passwordBytes = [UInt8](password)
        defer { zero(&passwordBytes) }
        for (index, byte) in usernameBytes.prefix(63).enumerated() {
            block[index] = byte
        }
        block[min(usernameBytes.count, 63)] = 0
        for (index, byte) in passwordBytes.prefix(63).enumerated() {
            block[64 + index] = byte
        }
        block[64 + min(passwordBytes.count, 63)] = 0
        return block
    }

    private func readByte() throws -> UInt8 {
        let data = try channel.read(1)
        guard let first = data.first else {
            throw RFBClientError.connectionClosed
        }
        return first
    }

    private func readUInt32() throws -> UInt32 {
        beUInt32(try channel.read(4), 0)
    }

    /// Reads and discards a 3.8 failure reason (a 4-byte length then that many
    /// bytes), bounded so a hostile length cannot ask for an unbounded read.
    private func readFailureReason() throws {
        let length = Int(try readUInt32())
        guard length > 0, length < 4096 else {
            return
        }
        _ = try channel.read(length)
    }

    private func beUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    private func beUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }
}

/// Left-pads a big-endian value with zero bytes to exactly `width`, or trims
/// leading bytes if it somehow came back longer -- the RFB wire fields for the
/// client public value and shared secret are exactly `keyLen` bytes.
func leftPadded(_ value: [UInt8], to width: Int) -> [UInt8] {
    if value.count == width {
        return value
    }
    if value.count > width {
        return Array(value.suffix(width))
    }
    return [UInt8](repeating: 0, count: width - value.count) + value
}

/// Overwrites every byte with zero. Used on every buffer that held the shared
/// secret, the derived key, or the password.
func zero(_ buffer: inout [UInt8]) {
    for index in buffer.indices {
        buffer[index] = 0
    }
}

/// The same overwrite for the per-character keysyms `type` derives from the
/// password: they are as revealing as the bytes they came from, so they are
/// zeroed the same way and under the same unique-ownership rule.
func zero(_ buffer: inout [UInt32]) {
    for index in buffer.indices {
        buffer[index] = 0
    }
}

/// AES-128 in ECB mode with no padding, over exactly the 128-byte credential
/// block. ECB with no padding is what the Apple type-30 protocol specifies;
/// CommonCrypto is Apple's public framework for it.
func aesECBEncrypt(_ plaintext: [UInt8], key: [UInt8]) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: plaintext.count)
    var moved = 0
    let status = CCCrypt(
        CCOperation(kCCEncrypt),
        CCAlgorithm(kCCAlgorithmAES128),
        CCOptions(kCCOptionECBMode),
        key, key.count,
        nil,
        plaintext, plaintext.count,
        &output, output.count,
        &moved
    )
    guard status == kCCSuccess else {
        throw RFBClientError.protocolViolation
    }
    return Array(output.prefix(moved))
}

/// A blocking loopback RFB socket to this Mac's own screensharingd on
/// 127.0.0.1:5900, with every read and write bounded by a timeout. The unlock
/// flow that drives it holds a guess slot for as long as one attempt runs, so
/// an unbounded wait on a stalled peer would hold that slot open forever.
///
/// Residual risk, named rather than papered over: whatever is listening on
/// loopback port 5900 is not authenticated by this code, and no public API can
/// prove it is the operating system's own screen-sharing service. Anything
/// already able to bind that port on this Mac -- which takes local code running
/// as this user or as root -- could stand in for it and be handed the password
/// this connection types. Enabling that service is the operator's own choice on
/// the host.
package final class RFBLoopbackSocketChannel: RFBByteChannel {
    /// How long one blocking read or write may wait before the attempt is
    /// abandoned as unreachable. Generous next to loopback latency, and far
    /// short of leaving a stalled peer holding the attempt open.
    package static let defaultTimeoutSeconds: Double = 10

    private let descriptor: Int32

    init?(port: UInt16 = 5900, timeoutSeconds: Double = RFBLoopbackSocketChannel.defaultTimeoutSeconds) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        Self.applyTimeouts(to: fd, seconds: timeoutSeconds)
        descriptor = fd
    }

    /// An already-connected descriptor this channel takes over and closes, so a
    /// test can drive the real blocking read and write -- timeouts included --
    /// against a local socket pair, with no service and no listener.
    package init(descriptor: Int32, timeoutSeconds: Double = RFBLoopbackSocketChannel.defaultTimeoutSeconds) {
        self.descriptor = descriptor
        Self.applyTimeouts(to: descriptor, seconds: timeoutSeconds)
    }

    /// Bounds both directions. A read or write that hits the bound returns -1
    /// with `EAGAIN`/`EWOULDBLOCK`, which the guards below turn into
    /// `connectionClosed` -- the same path a peer that hung up takes, and the
    /// one the unlocker reports as an unreachable screen-sharing service.
    private static func applyTimeouts(to descriptor: Int32, seconds: Double) {
        let whole = seconds.rounded(.down)
        var timeout = timeval(
            tv_sec: Int(whole),
            tv_usec: Int32((seconds - whole) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    package func read(_ count: Int) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: Swift.max(count, 1))
        while output.count < count {
            let received = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(descriptor, pointer.baseAddress, count - output.count)
            }
            // Zero is a peer that hung up; -1 is an error, the timeout's
            // `EAGAIN`/`EWOULDBLOCK` among them. Both end the attempt.
            guard received > 0 else {
                throw RFBClientError.connectionClosed
            }
            output.append(contentsOf: buffer[0..<received])
        }
        return output
    }

    package func write(_ data: Data) throws {
        try data.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let written = Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                // As in `read`: a hung-up peer and a timed-out write both end
                // the attempt rather than spinning on a socket going nowhere.
                guard written > 0 else {
                    throw RFBClientError.connectionClosed
                }
                offset += written
            }
        }
    }

    package func close() {
        Darwin.close(descriptor)
    }
}

/// The real unlocker. Opens a loopback RFB connection, authenticates as the
/// console user with the supplied password, types it plus Return into the
/// login window, and confirms the screen is no longer locked.
///
/// The console user is read with `SCDynamicStoreCopyConsoleUser` (the public
/// SystemConfiguration API): at the login window that is still the logged-in
/// user whose password unlocks the screen, which `getpwuid(getuid())` would
/// not be if the host ran as a different user. `getpwuid` is the fallback when
/// the store answers nothing usable.
public struct RFBLockScreenUnlocker: LockScreenUnlocking {
    private let lockStateReader: any ScreenLockStateReading
    private let makeChannel: @Sendable () -> RFBByteChannel?
    private let usernameProvider: @Sendable () -> String?
    private let keyPressDownSeconds: Double
    private let keyPressGapSeconds: Double
    private let verifyDelaySeconds: Double
    private let verifyAttempts: Int
    private let randomBytes: @Sendable (Int) throws -> [UInt8]

    public init(lockStateReader: any ScreenLockStateReading = CGSessionScreenLockState()) {
        self.init(
            lockStateReader: lockStateReader,
            makeChannel: { RFBLoopbackSocketChannel() },
            usernameProvider: { RFBLockScreenUnlocker.consoleUsername() }
        )
    }

    package init(
        lockStateReader: any ScreenLockStateReading,
        makeChannel: @escaping @Sendable () -> RFBByteChannel?,
        usernameProvider: @escaping @Sendable () -> String?,
        keyPressDownSeconds: Double = 0.045,
        keyPressGapSeconds: Double = 0.090,
        verifyDelaySeconds: Double = 1.5,
        verifyAttempts: Int = 3,
        randomBytes: @escaping @Sendable (Int) throws -> [UInt8] = RFBType30Client.systemRandomBytes
    ) {
        self.lockStateReader = lockStateReader
        self.makeChannel = makeChannel
        self.usernameProvider = usernameProvider
        self.keyPressDownSeconds = keyPressDownSeconds
        self.keyPressGapSeconds = keyPressGapSeconds
        self.verifyDelaySeconds = verifyDelaySeconds
        self.verifyAttempts = verifyAttempts
        self.randomBytes = randomBytes
    }

    /// The type-30 credential block's password field is 64 bytes with a
    /// mandatory NUL terminator, so 63 is the most a password can be without
    /// being silently truncated -- and a truncated password would then never
    /// match what is typed at the login window, no matter how many times the
    /// same wrong-looking outcome is retried.
    static let maximumPasswordBytes = 63

    public func unlock(password: Data) async -> HostScreenUnlockOutcome {
        guard password.count <= Self.maximumPasswordBytes else {
            return .passwordTooLong
        }
        guard let username = usernameProvider(), !username.isEmpty else {
            return .screenSharingUnavailable
        }
        guard let channel = makeChannel() else {
            return .screenSharingUnavailable
        }
        let client = RFBType30Client(channel: channel, randomBytes: randomBytes)
        do {
            try client.authenticate(username: username, password: password)
        } catch RFBClientError.authenticationRejected {
            channel.close()
            return .wrongPassword
        } catch {
            // A connection that could not be opened or finished, or a service
            // that never offered the type this client needs -- nothing was
            // typed, and the viewer's remedy is the same for all of them.
            channel.close()
            return .screenSharingUnavailable
        }

        do {
            try await type(password, through: client)
        } catch {
            channel.close()
            return .failed(reason: "could not type the password")
        }
        channel.close()

        for _ in 0..<max(verifyAttempts, 1) {
            try? await Task.sleep(nanoseconds: UInt64(verifyDelaySeconds * 1_000_000_000))
            if !lockStateReader.isScreenLocked() {
                return .unlocked
            }
        }
        return .failed(reason: "still locked after typing")
    }

    /// Thrown when the password's bytes are not valid UTF-8, so `type` below
    /// can abort mid-password rather than sending Return after typing only
    /// part of it -- a Return in that state would submit a password that is
    /// not the one this connection was given.
    private struct PasswordNotUTF8Error: Error {}

    /// Types the password's characters and a final Return. The bytes are
    /// decoded straight from the password rather than through a `String`. Both
    /// working buffers -- the password bytes and the per-character keysyms
    /// derived from them -- are zeroed before returning, and neither has a live
    /// second reference at that moment: the byte iterator is confined to the
    /// decode scope below and gone before the zero, and the keysyms are pressed
    /// by index rather than through an iterator that would copy them. So no
    /// readable copy of the password, in either form, outlives this call.
    ///
    /// Decoding runs to completion before any key is pressed. A password that
    /// is not valid UTF-8 therefore aborts before anything is typed, never
    /// mid-word, which cannot leave a partial password sitting in the login
    /// field.
    private func type(_ password: Data, through client: RFBType30Client) async throws {
        var passwordBytes = [UInt8](password)
        defer { zero(&passwordBytes) }
        // Reserved up front so the array never outgrows its buffer mid-decode:
        // a growth would leave the old, still-readable buffer behind unzeroed.
        // One keysym per byte is an upper bound -- a multi-byte scalar yields
        // one keysym for several bytes, never the other way round.
        var keysyms: [UInt32] = []
        keysyms.reserveCapacity(passwordBytes.count)
        defer { zero(&keysyms) }
        do {
            var decoder = UTF8()
            var iterator = passwordBytes.makeIterator()
            decode: while true {
                switch decoder.decode(&iterator) {
                case let .scalarValue(scalar):
                    keysyms.append(RFBType30Client.keysym(for: scalar))
                case .emptyInput:
                    break decode
                case .error:
                    throw PasswordNotUTF8Error()
                }
            }
        }
        for index in 0..<keysyms.count {
            try await press(keysyms[index], through: client)
        }
        try await press(RFBType30Client.returnKeysym, through: client)
    }

    private func press(_ keysym: UInt32, through client: RFBType30Client) async throws {
        try client.sendKeyEvent(keysym: keysym, down: true)
        if keyPressDownSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(keyPressDownSeconds * 1_000_000_000))
        }
        try client.sendKeyEvent(keysym: keysym, down: false)
        if keyPressGapSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(keyPressGapSeconds * 1_000_000_000))
        }
    }

    /// The current console user's short name, or `nil` when the store answers
    /// nothing usable -- the login window's own `loginwindow` pseudo-user is
    /// treated as no user, so the fallback runs.
    static func consoleUsername() -> String? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if let store = SCDynamicStoreCreate(nil, "sensorium.unlock" as CFString, nil, nil),
           let name = SCDynamicStoreCopyConsoleUser(store, &uid, &gid) as String?,
           !name.isEmpty,
           name != "loginwindow" {
            return name
        }
        if let pw = getpwuid(getuid()), let name = pw.pointee.pw_name {
            let fallback = String(cString: name)
            return fallback.isEmpty ? nil : fallback
        }
        return nil
    }
}
