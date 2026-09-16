import Foundation
import SensoriumCore

/// The remote lock-screen unlock messages on the wire: the viewer's password
/// request, the host's outcome, and the host's lock-state notice. The
/// password is raw bytes so the host can zero it, and it must survive the
/// round trip intact; every outcome token must round-trip, and a malformed
/// one must refuse rather than decode as a silently-accepted third answer.
private func unlockFrame(fromJSON json: String) -> Data {
    let payload = Data(json.utf8)
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
}

private func expectUnlockMalformed(_ json: String, _ message: String) {
    do {
        _ = try SensoriumFrameCodec.decode(unlockFrame(fromJSON: json))
        expect(false, message)
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "\(message) (wrong error: \(error))")
    }
}

func testHostScreenUnlockProtocol() {
    // A password carrying a NUL byte and non-ASCII bytes must survive
    // unchanged: it is raw UTF-8, not a String the codec is free to normalise.
    let password = Data([0x70, 0x40, 0x00, 0xC3, 0xA9, 0x21])
    let messages: [SensoriumMessage] = [
        .hostScreenUnlockRequest(password: password),
        .hostScreenUnlockRequest(password: Data()),
        .hostScreenUnlockResult(.unlocked),
        .hostScreenUnlockResult(.wrongPassword),
        .hostScreenUnlockResult(.screenSharingUnavailable),
        .hostScreenUnlockResult(.notLocked),
        .hostScreenUnlockResult(.notAuthorized),
        .hostScreenUnlockResult(.tooManyAttempts),
        .hostScreenUnlockResult(.passwordTooLong),
        .hostScreenUnlockResult(.presenceRequired),
        .hostScreenUnlockResult(.failed(reason: "still locked after typing")),
        .hostScreenLockState(locked: true),
        .hostScreenLockState(locked: false),
        .hostScreenUnlockChallengeRequest,
        .hostScreenUnlockChallenge(challenge: Data([0x11, 0x00, 0x22, 0xFE])),
        .hostScreenUnlockArm(presence: .signed(
            credentialID: Data([0x01, 0x02]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x03, 0x00, 0x04])
        )),
        .hostScreenUnlockArm(presence: .resumeTicket(Data([0xAB, 0xCD])))
    ]
    for message in messages {
        let encoded = try! SensoriumFrameCodec.encode(message)
        let decoded = try! SensoriumFrameCodec.decode(encoded)
        expect(decoded == message, "\(message) round-trips through encode and decode unchanged")
    }

    // The password bytes specifically, not just the field's presence.
    let decodedRequest = try! SensoriumFrameCodec.decode(
        try! SensoriumFrameCodec.encode(.hostScreenUnlockRequest(password: password))
    )
    guard case let .hostScreenUnlockRequest(decodedPassword) = decodedRequest else {
        expect(false, "the round-tripped message is still a hostScreenUnlockRequest")
        return
    }
    expect(decodedPassword == password, "the exact password bytes survive the round trip, NUL and all")

    print("PASS: hostScreenUnlockRequest, every hostScreenUnlockResult outcome, hostScreenLockState, and the challenge/arm handshake round-trip, and the password bytes survive intact")

    expectUnlockMalformed(
        "{\"type\":\"hostScreenUnlockRequest\"}",
        "a hostScreenUnlockRequest with no password is rejected, not treated as an empty unlock"
    )
    expectUnlockMalformed(
        "{\"type\":\"hostScreenUnlockResult\"}",
        "a hostScreenUnlockResult naming no outcome is rejected"
    )
    expectUnlockMalformed(
        "{\"type\":\"hostScreenUnlockResult\",\"hostScreenUnlockOutcome\":\"unlocked-somehow\"}",
        "a hostScreenUnlockResult with an outcome token this build does not know is rejected, not decoded as a third answer"
    )
    expectUnlockMalformed(
        "{\"type\":\"hostScreenUnlockResult\",\"hostScreenUnlockOutcome\":\"failed\"}",
        "a failed outcome with no reason is rejected -- failed is the one case that must say why"
    )
    expectUnlockMalformed(
        "{\"type\":\"hostScreenLockState\"}",
        "a hostScreenLockState that does not say whether the screen is locked is rejected"
    )
    expectUnlockMalformed(
        "{\"type\":\"hostScreenUnlockChallenge\"}",
        "a hostScreenUnlockChallenge carrying no challenge bytes is rejected"
    )
    expectUnlockMalformed(
        "{\"type\":\"hostScreenUnlockArm\"}",
        "a hostScreenUnlockArm carrying neither a signed proof nor a ticket is rejected"
    )
    expectUnlockMalformed(
        "{\"type\":\"hostScreenUnlockArm\",\"resumeTicket\":\"qg==\",\"credentialID\":\"AQ==\"}",
        "a hostScreenUnlockArm mixing a ticket and a signed proof is rejected, never partially trusted"
    )

    print("PASS: a malformed unlock message refuses to decode rather than falling back to an accepted outcome")

    let futureType = unlockFrame(fromJSON: "{\"type\":\"hostScreenUnlockSomethingNotInvented\"}")
    expect(
        try! SensoriumFrameCodec.decode(futureType) == .unrecognized(type: "hostScreenUnlockSomethingNotInvented"),
        "an unlock message type this build has never heard of decodes as .unrecognized and is skippable"
    )

    print("PASS: an unknown unlock message decodes as .unrecognized, so an older peer skips it rather than dying")
}
