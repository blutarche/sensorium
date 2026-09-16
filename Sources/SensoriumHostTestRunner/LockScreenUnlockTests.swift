import CommonCrypto
import CryptoKit
import Foundation
import SensoriumCore
import SensoriumHost

/// A scripted RFB byte channel: hands back the server bytes it was primed with,
/// in order and in whatever chunk sizes the client asks for, and records every
/// write so a test can assert the client's emitted bytes exactly.
final class ScriptedRFBChannel: RFBByteChannel, @unchecked Sendable {
    private var toDeliver: Data
    private(set) var writes: [Data] = []
    private(set) var closed = false

    init(serverBytes: Data) {
        toDeliver = serverBytes
    }

    func read(_ count: Int) throws -> Data {
        guard toDeliver.count >= count else {
            throw RFBClientError.connectionClosed
        }
        let chunk = toDeliver.prefix(count)
        toDeliver.removeFirst(count)
        return Data(chunk)
    }

    func write(_ data: Data) throws {
        writes.append(data)
    }

    func close() {
        closed = true
    }

    /// Every written byte concatenated, for assertions that do not care where
    /// one write ended and the next began.
    var allWritten: Data {
        writes.reduce(into: Data()) { $0.append($1) }
    }
}

struct FakeScreenLockState: ScreenLockStateReading {
    let locked: Bool
    func isScreenLocked() -> Bool { locked }
}

/// A lock reader that starts locked and reports unlocked once flipped, so a
/// success path that types and then re-checks can be driven deterministically.
final class FlippableLockState: ScreenLockStateReading, @unchecked Sendable {
    private let lock = NSLock()
    private var locked: Bool
    init(locked: Bool) { self.locked = locked }
    func setLocked(_ value: Bool) { lock.lock(); locked = value; lock.unlock() }
    func isScreenLocked() -> Bool { lock.lock(); defer { lock.unlock() }; return locked }
}

private func aesECBDecryptForTest(_ ciphertext: Data, key: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: ciphertext.count)
    var moved = 0
    let bytes = [UInt8](ciphertext)
    _ = CCCrypt(
        CCOperation(kCCDecrypt),
        CCAlgorithm(kCCAlgorithmAES128),
        CCOptions(kCCOptionECBMode),
        key, key.count,
        nil,
        bytes, bytes.count,
        &output, output.count,
        &moved
    )
    return Array(output.prefix(moved))
}

private func padLeft(_ value: [UInt8], to width: Int) -> [UInt8] {
    value.count >= width ? Array(value.suffix(width)) : [UInt8](repeating: 0, count: width - value.count) + value
}

/// Feeds the client a scripted type-30 handshake with a small (32-bit) DH group
/// and a pinned private exponent and credential fill, then checks every byte
/// the client emits: the version reply, the security-type selection, the client
/// public value (checked against an independent modexp), and the encrypted
/// credential block (decrypted here with the DH-derived key to confirm its
/// layout). The screensharingd leg is a manual test; this proves the wire
/// encoding without a live service.
func testRFBUnlockClientEncoding() async {
    let keyLen = 4
    let prime: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFB] // 4294967291, a 32-bit prime
    let generator: [UInt8] = [0x00, 0x02]
    let serverPublic: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    let privateExponent: [UInt8] = [0x00, 0x00, 0x00, 0x07]
    let credsFill = [UInt8](repeating: 0xAA, count: 128)

    var serverBytes = Data()
    serverBytes.append(Data("RFB 003.889\n".utf8)) // 12-byte ProtocolVersion banner
    serverBytes.append(Data([0x01]))               // one security type on offer
    serverBytes.append(Data([30]))                 // type 30
    serverBytes.append(Data([0x00, 0x02]))         // generator = 2
    serverBytes.append(Data([0x00, 0x04]))         // keyLen = 4
    serverBytes.append(Data(prime))
    serverBytes.append(Data(serverPublic))
    serverBytes.append(Data([0x00, 0x00, 0x00, 0x00])) // SecurityResult = 0 (success)
    var serverInit = [UInt8](repeating: 0, count: 24) // ServerInit, name length 0 at offset 20
    serverInit[20] = 0; serverInit[21] = 0; serverInit[22] = 0; serverInit[23] = 0
    serverBytes.append(Data(serverInit))

    let channel = ScriptedRFBChannel(serverBytes: serverBytes)
    let client = RFBType30Client(channel: channel, randomBytes: { count in
        count == keyLen ? privateExponent : credsFill
    })
    let loginPassword = Data("s3cr3t-üü".utf8)
    try! client.authenticate(username: "tester", password: loginPassword)

    expect(channel.writes.count == 5, "the client emits exactly five writes for a full type-30 handshake")
    expect(channel.writes[0] == Data("RFB 003.008\n".utf8), "the client answers the version banner with RFB 003.008")
    expect(channel.writes[1] == Data([30]), "the client selects security type 30")
    expect(channel.writes[2].count == 128, "the client sends a 128-byte encrypted credential block")

    let expectedClientPublic = padLeft(
        modularExponentiation(base: generator, exponent: privateExponent, modulus: prime),
        to: keyLen
    )
    expect(channel.writes[3] == Data(expectedClientPublic), "the client public value is g^priv mod p, left-padded to keyLen")
    expect(channel.writes[4] == Data([1]), "ClientInit requests a shared session")

    // Independently derive the AES key from the DH exchange and decrypt the
    // credential block to prove its layout.
    let shared = padLeft(
        modularExponentiation(base: serverPublic, exponent: privateExponent, modulus: prime),
        to: keyLen
    )
    let aesKey = Array(Insecure.MD5.hash(data: Data(shared)))
    let block = aesECBDecryptForTest(channel.writes[2], key: aesKey)
    expect(block.count == 128, "the decrypted credential block is 128 bytes")
    let usernameBytes = Array("tester".utf8)
    expect(Array(block.prefix(usernameBytes.count)) == usernameBytes, "the username sits at offset 0")
    expect(block[usernameBytes.count] == 0, "the username is NUL-terminated")
    let passwordBytes = [UInt8](loginPassword)
    expect(Array(block[64..<(64 + passwordBytes.count)]) == passwordBytes, "the password sits at offset 64, bytes intact")
    expect(block[64 + passwordBytes.count] == 0, "the password is NUL-terminated")
    // The bytes the credentials did not overwrite are the random fill, not zero.
    expect(block[usernameBytes.count + 1] == 0xAA, "the bytes between username and password are the random fill")

    // Key-event encoding: type 4, down flag, two pad bytes, 4-byte big-endian keysym.
    expect(
        RFBType30Client.keyEventMessage(keysym: 0x0041, down: true) == Data([4, 1, 0, 0, 0x00, 0x00, 0x00, 0x41]),
        "a key-down event encodes the keysym as a 4-byte big-endian integer after the down flag and two pad bytes"
    )
    expect(
        RFBType30Client.keyEventMessage(keysym: RFBType30Client.returnKeysym, down: false) == Data([4, 0, 0, 0, 0x00, 0x00, 0xFF, 0x0D]),
        "Return is keysym 0xFF0D, and a key-up event clears the down flag"
    )
    expect(RFBType30Client.keysym(for: "A") == 0x41, "an ASCII scalar is its own keysym")
    expect(RFBType30Client.keysym(for: "€") == 0x01000000 + 0x20AC, "a scalar at or above 0x100 maps to 0x01000000 + scalar")

    print("PASS: the RFB type-30 client emits the correct handshake, credential block, client public value, and key events")
}

/// The real unlocker over a fake channel and lock reader: a rejected security
/// result reads as a wrong password, a type-30-less or unopenable service reads
/// as unavailable, and a successful auth reads as unlocked or still-locked
/// depending only on what the lock reader says afterwards.
private func unlockHandshake(securityResult: [UInt8], offerType30: Bool = true, includeServerInit: Bool) -> Data {
    var bytes = Data()
    bytes.append(Data("RFB 003.889\n".utf8))
    bytes.append(Data([0x01]))
    bytes.append(Data([offerType30 ? 30 : 2]))
    if offerType30 {
        bytes.append(Data([0x00, 0x02, 0x00, 0x04]))
        bytes.append(Data([0xFF, 0xFF, 0xFF, 0xFB]))
        bytes.append(Data([0x12, 0x34, 0x56, 0x78]))
        bytes.append(Data(securityResult))
        bytes.append(Data([0x00, 0x00, 0x00, 0x00])) // failure-reason length 0
        if includeServerInit {
            bytes.append(Data([UInt8](repeating: 0, count: 24)))
        }
    }
    return bytes
}

func testLockScreenUnlockerOutcomes() async {
    let loginPassword = Data("open-sesame".utf8)

    // A wrong password gives a non-zero SecurityResult.
    let wrong = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: { ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 1], includeServerInit: false)) },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    expect(await wrong.unlock(password: loginPassword) == .wrongPassword, "a non-zero SecurityResult reads as a wrong password")

    // Type 30 not offered.
    let noType = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: { ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 0], offerType30: false, includeServerInit: false)) },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    expect(await noType.unlock(password: loginPassword) == .screenSharingUnavailable, "a service that does not offer type 30 reads as unavailable")

    // No channel at all.
    let noChannel = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: { nil },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    expect(await noChannel.unlock(password: loginPassword) == .screenSharingUnavailable, "a service that cannot be reached reads as unavailable")

    // Success then verified unlocked.
    let unlockedReader = FlippableLockState(locked: false)
    let success = RFBLockScreenUnlocker(
        lockStateReader: unlockedReader,
        makeChannel: { ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 0], includeServerInit: true)) },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    expect(await success.unlock(password: loginPassword) == .unlocked, "a successful auth followed by an unlocked screen reads as unlocked")

    // Success but still locked afterwards.
    let stillLocked = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: { ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 0], includeServerInit: true)) },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    if case .failed = await stillLocked.unlock(password: loginPassword) {
        print("PASS: the unlocker maps every handshake outcome and reports still-locked when typing did not take")
    } else {
        expect(false, "a successful auth that leaves the screen locked reads as failed, not unlocked")
    }
}

/// A failing CSPRNG must never fall back to the zero-filled buffer
/// `SecRandomCopyBytes` leaves behind on failure -- that buffer would collapse
/// the DH exponent to zero and wrap the credential block in a fixed, public
/// key. Checked both when the draw fails outright and when it fails only on
/// the credential block's own random padding.
func testFailedRandomnessNeverProducesAZeroKeyHandshake() async {
    struct InjectedRandomFailure: Error {}
    let loginPassword = Data("open-sesame".utf8)

    let channel = ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 0], includeServerInit: true))
    let unlocker = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: { channel },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1,
        randomBytes: { _ in throw InjectedRandomFailure() }
    )
    let outcome = await unlocker.unlock(password: loginPassword)
    expect(outcome == .screenSharingUnavailable, "a CSPRNG that fails outright surfaces as screenSharingUnavailable, not a completed handshake")
    expect(channel.writes.isEmpty, "a CSPRNG that fails outright sends no handshake bytes at all")

    // A CSPRNG that succeeds for every draw except the 128-byte
    // credential-block padding must still abort before the credential block
    // or the DH public value that would wrap it is ever written.
    let partialChannel = ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 0], includeServerInit: true))
    let partialUnlocker = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: { partialChannel },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1,
        randomBytes: { count in
            guard count != 128 else {
                throw InjectedRandomFailure()
            }
            return [UInt8](repeating: 0x07, count: count)
        }
    )
    let partialOutcome = await partialUnlocker.unlock(password: loginPassword)
    expect(partialOutcome == .screenSharingUnavailable, "a CSPRNG that fails only on the credential-block draw still surfaces as screenSharingUnavailable")
    expect(
        !partialChannel.writes.contains { $0.count == 128 },
        "a CSPRNG that fails only on the credential-block draw never sends the 128-byte credential block"
    )

    print("PASS: a failing CSPRNG draw, whether it fails outright or only on the credential block's padding, never produces a zero-key handshake")
}

/// The `ServerInit` name length is a raw 32-bit field off the wire; an
/// oversized value must be rejected before it becomes an allocation and a
/// read of that size, the same way `readFailureReason`'s length already is.
func testServerInitNameLengthIsBounded() {
    let keyLen = 4
    let prime: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFB]
    let serverPublic: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    let privateExponent: [UInt8] = [0x00, 0x00, 0x00, 0x07]
    let credsFill = [UInt8](repeating: 0xAA, count: 128)

    var serverBytes = Data()
    serverBytes.append(Data("RFB 003.889\n".utf8))
    serverBytes.append(Data([0x01]))
    serverBytes.append(Data([30]))
    serverBytes.append(Data([0x00, 0x02, 0x00, 0x04]))
    serverBytes.append(Data(prime))
    serverBytes.append(Data(serverPublic))
    serverBytes.append(Data([0x00, 0x00, 0x00, 0x00]))
    var serverInit = [UInt8](repeating: 0, count: 24)
    serverInit[20] = 0xFF
    serverInit[21] = 0xFF
    serverInit[22] = 0xFF
    serverInit[23] = 0xFF
    serverBytes.append(Data(serverInit))

    let channel = ScriptedRFBChannel(serverBytes: serverBytes)
    let client = RFBType30Client(channel: channel, randomBytes: { count in count == keyLen ? privateExponent : credsFill })
    expectThrows(
        RFBClientError.protocolViolation,
        { try client.authenticate(username: "tester", password: Data("pw".utf8)) },
        "an oversized ServerInit name length is rejected as a protocol violation rather than allocating an unbounded read"
    )
    print("PASS: an oversized ServerInit name length is rejected as a protocol violation")
}

/// The type-30 credential block's password field is 64 bytes with a
/// mandatory NUL terminator: 63 is the most a password can be without being
/// silently truncated into a password that will never match what is typed at
/// the login window.
func testPasswordExceeding63BytesReportsPasswordTooLongWithoutOpeningAConnection() async {
    let longPassword = Data(repeating: 0x61, count: 64)
    let unlocker = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: {
            expect(false, "a password over 63 bytes must never open a connection to try it")
            return nil
        },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    let outcome = await unlocker.unlock(password: longPassword)
    expect(outcome == .passwordTooLong, "a password over 63 bytes reports passwordTooLong rather than being silently truncated and typed")

    // Exactly 63 bytes still fits the field's 64-byte, NUL-terminated slot
    // and must proceed normally, not be refused as too long.
    let boundaryPassword = Data(repeating: 0x62, count: 63)
    let boundaryUnlocker = RFBLockScreenUnlocker(
        lockStateReader: FlippableLockState(locked: false),
        makeChannel: { ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 0], includeServerInit: true)) },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    let boundaryOutcome = await boundaryUnlocker.unlock(password: boundaryPassword)
    expect(boundaryOutcome == .unlocked, "a password of exactly 63 bytes is not refused as too long")

    print("PASS: a password over the type-30 credential field's 63-byte budget reports passwordTooLong and never opens a connection; exactly 63 bytes still proceeds")
}

/// A decode error partway through the password must abort typing rather than
/// abandoning the rest of the password while still sending Return -- that
/// would submit a password that is not the one this connection was given.
func testNonUTF8PasswordBytesAbortTypingWithoutSendingReturn() async {
    let channel = ScriptedRFBChannel(serverBytes: unlockHandshake(securityResult: [0, 0, 0, 0], includeServerInit: true))
    let unlocker = RFBLockScreenUnlocker(
        lockStateReader: FakeScreenLockState(locked: true),
        makeChannel: { channel },
        usernameProvider: { "tester" },
        keyPressDownSeconds: 0, keyPressGapSeconds: 0, verifyDelaySeconds: 0, verifyAttempts: 1
    )
    // 'A', then a byte that is never a valid UTF-8 lead or continuation byte,
    // then a 'B' that must never be reached.
    let outcome = await unlocker.unlock(password: Data([0x41, 0xFF, 0x42]))
    if case .failed = outcome {
    } else {
        expect(false, "non-UTF-8 password bytes report a failure outcome, not unlocked -- got \(outcome)")
    }
    let returnDown = RFBType30Client.keyEventMessage(keysym: RFBType30Client.returnKeysym, down: true)
    let returnUp = RFBType30Client.keyEventMessage(keysym: RFBType30Client.returnKeysym, down: false)
    expect(
        !channel.writes.contains(returnDown) && !channel.writes.contains(returnUp),
        "a decode error aborts typing before Return is ever sent"
    )

    print("PASS: non-UTF-8 password bytes abort typing and never send the trailing Return")
}

private func bytes(fromHex hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// Hard-coded vectors for the native modular exponentiation, generated with
/// Python's `pow(base, exponent, modulus)` at authoring time and frozen here.
/// The shipping code never calls Python: these are the arithmetic's ground
/// truth, small enough to check by eye and one large enough (a 632-bit
/// modulus) to catch a carry or borrow bug the small ones would not.
private func testModularExponentiationMatchesKnownVectors() {
    let vectors: [(base: String, exponent: String, modulus: String, expected: String)] = [
        ("04", "0d", "01f1", "01bd"),
        ("41", "11", "0ca1", "0ae6"),
        ("075bcd15", "03e9", "0186a3", "8016"),
        ("3039", "00", "018697", "01"),
        ("3ade68b1", "01", "3b9aca07", "3ade68b1"),
        (
            "e465bd9c66b3ad3c2d6d1a3d1fa7bc8960a923b8c1e9392456de3eb13b9046685257bdd640fb06671ad11c80317fa3b1799d",
            "8fad06cb0fb39a1de644815ef6d13b8faa1837f8a88b17fc695a07a0ca6e0822e8f36c031199972a846916419f828b9d2434",
            "0c037c37588b4329887e61c2da3324b1ba4b81a63f9748fed2d8a410c2fc21b1232f0d3bfa024276cfd88448197aae486a63bfca7b8bf7754dfb327c7201f6fd17fd7fd74158bd31be32414a2e90f8",
            "093e3a4589f0e3c680f2698873f726677aa4b654b6d989b9cd780aecb9d3d6d25dde606ae72cc4a6ca9107a6b675422f8041f13fcb5048de453f10bf7faebf45efe4249b9e6c505cbf944b8d06bd99"
        )
    ]
    for vector in vectors {
        let result = modularExponentiation(
            base: bytes(fromHex: vector.base),
            exponent: bytes(fromHex: vector.exponent),
            modulus: bytes(fromHex: vector.modulus)
        )
        expect(
            result == bytes(fromHex: vector.expected),
            "modularExponentiation(\(vector.base)^\(vector.exponent) mod \(vector.modulus)) is \(vector.expected), got \(result.map { String(format: "%02x", $0) }.joined())"
        )
    }

    // A base larger than the modulus is reduced first, not fed in raw.
    expect(
        modularExponentiation(base: bytes(fromHex: "075bcd15"), exponent: [1], modulus: bytes(fromHex: "0186a3"))
            == modularExponentiation(base: BigEndianReduceProbe.reduce(bytes(fromHex: "075bcd15"), bytes(fromHex: "0186a3")), exponent: [1], modulus: bytes(fromHex: "0186a3")),
        "a base larger than the modulus reduces to the same answer as its already-reduced form"
    )

    // Leading zero bytes on any input change nothing.
    expect(
        modularExponentiation(base: [0x00, 0x00, 0x04], exponent: [0x00, 0x0d], modulus: [0x00, 0x01, 0xf1])
            == bytes(fromHex: "01bd"),
        "leading zero bytes on the inputs do not change the result"
    )

    print("PASS: native modular exponentiation matches every known vector, reduces an oversize base, and ignores leading zero bytes")
}

/// A stand-in so the test can reduce a value the same way the production code
/// does, to prove the oversize-base path without hard-coding a second vector.
private enum BigEndianReduceProbe {
    static func reduce(_ value: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
        // Repeated subtraction is enough for this small probe; the production
        // reduction is exercised by the vectors above.
        var remainder = value
        func ge(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            let na = Array(a.drop { $0 == 0 })
            let nb = Array(b.drop { $0 == 0 })
            if na.count != nb.count { return na.count > nb.count }
            return na.lexicographicallyPrecedes(nb) == false
        }
        func sub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
            var r: [UInt8] = []
            var borrow = 0
            var i = a.count - 1
            var j = b.count - 1
            while i >= 0 {
                var d = Int(a[i]) - (j >= 0 ? Int(b[j]) : 0) - borrow
                if d < 0 { d += 256; borrow = 1 } else { borrow = 0 }
                r.append(UInt8(d)); i -= 1; j -= 1
            }
            return Array(r.reversed().drop { $0 == 0 })
        }
        while ge(remainder, modulus) {
            remainder = sub(remainder, modulus)
        }
        return remainder
    }
}

private func testScreenLockStateFakeBehaves() {
    let locked = FakeScreenLockState(locked: true)
    let unlocked = FakeScreenLockState(locked: false)
    expect(locked.isScreenLocked(), "a fake set locked reports locked")
    expect(!unlocked.isScreenLocked(), "a fake set unlocked reports unlocked")

    // The real reader must at least answer without trapping in this process,
    // whatever the actual lock state of the machine the suite runs on.
    _ = CGSessionScreenLockState().isScreenLocked()

    print("PASS: the screen-lock-state fake reports what it was set to, and the real reader answers without trapping")
}

/// A peer that accepts a connection and then says nothing must not hold an
/// unlock attempt open: both directions of the real channel give up at their
/// timeout. Driven over a local socket pair -- two already-connected
/// descriptors, with no listener and nothing on the network -- and with the
/// timeout injected short so the test costs under a second.
private func testABlockingLoopbackChannelStopsAtItsTimeout() {
    var descriptors: [Int32] = [0, 0]
    expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0, "a local socket pair opens")
    // The far end stays open and silent for the whole test: what is bounded
    // here is a peer that never answers, not one that hung up.
    let channel = RFBLoopbackSocketChannel(descriptor: descriptors[0], timeoutSeconds: 0.3)

    let readStarted = MonotonicClock.nowNanoseconds()
    var readError: Error?
    do {
        _ = try channel.read(1)
    } catch {
        readError = error
    }
    let readSeconds = Double(MonotonicClock.nowNanoseconds() - readStarted) / 1_000_000_000
    expect(readError as? RFBClientError == .connectionClosed, "a read that times out ends the attempt on the unreachable path")
    expect(readSeconds < 3, "and it returns at its timeout instead of blocking forever (took \(readSeconds)s)")

    // More than any socket buffer holds, against a peer that never reads it,
    // so the write blocks and must hit its own timeout.
    let writeStarted = MonotonicClock.nowNanoseconds()
    var writeError: Error?
    do {
        try channel.write(Data(count: 4_000_000))
    } catch {
        writeError = error
    }
    let writeSeconds = Double(MonotonicClock.nowNanoseconds() - writeStarted) / 1_000_000_000
    expect(writeError as? RFBClientError == .connectionClosed, "a write that times out ends the attempt the same way")
    expect(writeSeconds < 3, "and it too returns at its timeout (took \(writeSeconds)s)")

    channel.close()
    Darwin.close(descriptors[1])
    print("PASS: a stalled peer cannot hold an unlock attempt open -- both channel directions give up at their timeout")
}

@MainActor
func runLockScreenUnlockTests() async {
    testModularExponentiationMatchesKnownVectors()
    testScreenLockStateFakeBehaves()
    await testRFBUnlockClientEncoding()
    await testLockScreenUnlockerOutcomes()
    await testFailedRandomnessNeverProducesAZeroKeyHandshake()
    testServerInitNameLengthIsBounded()
    await testPasswordExceeding63BytesReportsPasswordTooLongWithoutOpeningAConnection()
    await testNonUTF8PasswordBytesAbortTypingWithoutSendingReturn()
    testABlockingLoopbackChannelStopsAtItsTimeout()
}
