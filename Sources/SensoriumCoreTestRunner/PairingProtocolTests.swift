import Foundation
import SensoriumCore

func testPairingCodeExpiresAndCannotBeReused() {
    let issuedAt = Date(timeIntervalSince1970: 1_000)
    var authority = PairingAuthority()
    let code = authority.issue(now: issuedAt, code: "123456")
    expect(code == "123456", "pairing issues the requested six-digit code")

    let grant = try! authority.approve(code: code, deviceID: "macbook", now: issuedAt.addingTimeInterval(1))
    expect(grant.deviceID == "macbook", "pairing grant binds the approved device")

    do {
        _ = try authority.approve(code: code, deviceID: "macbook", now: issuedAt.addingTimeInterval(2))
        expect(false, "pairing code cannot be reused")
    } catch PairingError.codeAlreadyConsumed {
    } catch {
        expect(false, "pairing reuse reports the expected error")
    }

    let expiredCode = authority.issue(now: issuedAt, code: "654321")
    do {
        _ = try authority.approve(code: expiredCode, deviceID: "macbook", now: issuedAt.addingTimeInterval(301))
        expect(false, "expired pairing code is rejected")
    } catch PairingError.codeExpired {
    } catch {
        expect(false, "pairing expiry reports the expected error")
    }
}

func testPairingCodeBudgetBoundsGuessesAndComparesInConstantTime() {
    let issuedAt = Date(timeIntervalSince1970: 2_000)
    let attemptedAt = issuedAt.addingTimeInterval(1)

    // The budget belongs to the issued code, so however many connections the
    // guesses arrive over, the code dies after the tenth wrong one.
    var exhausted = PairingAuthority()
    let exhaustedCode = exhausted.issue(now: issuedAt, code: "424242")
    for attempt in 1...PairingAuthority.maximumFailedAttempts {
        do {
            _ = try exhausted.approve(code: "999999", deviceID: "macbook", now: attemptedAt)
            expect(false, "wrong pairing code \(attempt) is rejected")
        } catch PairingError.invalidCode {
        } catch {
            expect(false, "wrong pairing code \(attempt) reports the expected error")
        }
    }
    do {
        _ = try exhausted.approve(code: exhaustedCode, deviceID: "macbook", now: attemptedAt)
        expect(false, "a spent failure budget retires the code even for the correct guess")
    } catch PairingError.codeAttemptsExhausted {
    } catch {
        expect(false, "an exhausted pairing code reports the expected error")
    }

    // One below the budget is still a working ceremony: a person mistyping
    // six digits must not be sent back to re-issue.
    var nearMiss = PairingAuthority()
    let nearMissCode = nearMiss.issue(now: issuedAt, code: "135790")
    for _ in 1..<PairingAuthority.maximumFailedAttempts {
        _ = try? nearMiss.approve(code: "000000", deviceID: "macbook", now: attemptedAt)
    }
    let nearMissGrant = try! nearMiss.approve(code: nearMissCode, deviceID: "macbook", now: attemptedAt)
    expect(nearMissGrant.deviceID == "macbook", "nine wrong codes still leave the tenth, correct one able to pair")
    do {
        _ = try nearMiss.approve(code: nearMissCode, deviceID: "macbook", now: attemptedAt)
        expect(false, "a code that paired cannot pair again")
    } catch PairingError.codeAlreadyConsumed {
    } catch {
        expect(false, "reuse after a near-miss pairing reports the expected error")
    }

    // Re-issuing is the recovery: a fresh code starts with a fresh budget.
    let reissuedCode = nearMiss.issue(now: issuedAt, code: "246810")
    for _ in 1..<PairingAuthority.maximumFailedAttempts {
        _ = try? nearMiss.approve(code: "000000", deviceID: "macbook", now: attemptedAt)
    }
    expect(
        (try? nearMiss.approve(code: reissuedCode, deviceID: "macbook", now: attemptedAt))?.deviceID == "macbook",
        "issuing a new code resets the failure budget"
    )

    // Expiry is refused on its own terms, with budget still to spare.
    var expiring = PairingAuthority()
    let expiringCode = expiring.issue(now: issuedAt, code: "864209")
    _ = try? expiring.approve(code: "000000", deviceID: "macbook", now: attemptedAt)
    do {
        _ = try expiring.approve(code: expiringCode, deviceID: "macbook", now: issuedAt.addingTimeInterval(301))
        expect(false, "an expired code is refused whatever the failure budget says")
    } catch PairingError.codeExpired {
    } catch {
        expect(false, "expiry with budget remaining reports the expected error")
    }

    // Constant time is asserted as a property of the comparison rather than
    // as a wall-clock measurement, which no test machine can make reliable:
    // every six-digit pair costs the same six position comparisons, whichever
    // digit differs first.
    expect(
        PairingAuthority.constantTimeCompare("424242", "424242") == (true, 6),
        "an equal pair of codes compares equal across all six positions"
    )
    for wrong in ["924242", "434242", "424243", "999999"] {
        expect(
            PairingAuthority.constantTimeCompare("424242", wrong) == (false, 6),
            "a code differing at any position still costs six comparisons, not an early return"
        )
    }
    expect(
        PairingAuthority.constantTimeCompare("424242", "4242") == (false, 0),
        "a wrong-length code is refused on length alone, which is not a secret"
    )
}

func testPairingMessagesRoundTripThroughVersionedFrame() {
    let identity = try! DeviceIdentity.generate()
    let messages: [SensoriumMessage] = [
        .pairRequest(deviceName: "MacBook", publicKey: identity.publicKey, code: "123456"),
        .pairApproved(
            hostPublicKey: identity.publicKey,
            tlsCertificateHash: Data(repeating: 0xA5, count: 32),
            signature: Data(repeating: 0x5A, count: 64)
        ),
        .pairRejected(reason: "code-expired")
    ]
    for message in messages {
        let encoded = try! SensoriumFrameCodec.encode(message)
        expect(try! SensoriumFrameCodec.decode(encoded) == message, "\(message) round-trips through versioned frame")
    }
}

/// Credential registration, riding `pairRequest` -- design §6.3.
/// `pairIntent` -- the true "shown the moment a new Mac asks to pair"
/// moment, before that Mac has a code to send at all.
func testPairIntentRoundTripsAndRefusesMalformed() {
    let message = SensoriumMessage.pairIntent(deviceName: "Kestrel MacBook Pro")
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message)) == message,
        "a pairIntent round-trips its own device name unchanged"
    )

    func frame(fromObject object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    do {
        _ = try SensoriumFrameCodec.decode(frame(fromObject: ["type": "pairIntent"]))
        expect(false, "a pairIntent with no deviceName at all is refused as malformed")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "a pairIntent missing deviceName reports malformedMessage, not some other error")
    }

    do {
        _ = try SensoriumFrameCodec.decode(frame(fromObject: ["type": "pairIntent", "deviceName": ""]))
        expect(false, "a pairIntent with an empty deviceName is refused as malformed, the same as an empty pairRequest deviceName")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "a pairIntent with an empty deviceName reports malformedMessage, not some other error")
    }
}

func testPairRequestPresenceCredentialRegistration() {
    let identity = try! DeviceIdentity.generate()
    let credential = PresenceCredentialRegistration(
        credentialID: Data(repeating: 0x11, count: 16),
        publicKey: Data(repeating: 0x22, count: 32),
        credentialFormat: "apple-secure-enclave-p256",
        strength: "hardwareBound"
    )
    let withCredential = SensoriumMessage.pairRequest(
        deviceName: "MacBook", publicKey: identity.publicKey, code: "123456", presenceCredential: credential
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withCredential)) == withCredential,
        "a pairRequest carrying a presence-credential registration round-trips it unchanged"
    )

    // CLAUDE.md: a device that can offer neither acceptable strength "may
    // pair and use a session canvas" -- no credential is not a malformed
    // request, it is the ordinary case.
    let withoutCredential = SensoriumMessage.pairRequest(
        deviceName: "MacBook", publicKey: identity.publicKey, code: "123456"
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withoutCredential)) == withoutCredential,
        "a pairRequest registering no credential still round-trips and still pairs"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(withoutCredential), as: UTF8.self).contains("presenceCredential"),
        "a pairRequest registering no credential omits the presence-credential keys entirely"
    )

    func frame(fromObject object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    let baseObject: [String: Any] = [
        "type": "pairRequest",
        "deviceName": "MacBook",
        "publicKey": identity.publicKey.base64EncodedString(),
        "code": "123456"
    ]

    // An unrecognised strength string is malformed, never a third, silently
    // accepted tier -- CLAUDE.md's own invariant: strength is recorded, not
    // trusted, and this codec is the one place that can refuse an
    // unrecognised report before it is ever recorded.
    var unknownStrengthObject = baseObject
    unknownStrengthObject["credentialID"] = credential.credentialID.base64EncodedString()
    unknownStrengthObject["credentialFormat"] = credential.credentialFormat
    unknownStrengthObject["presenceCredentialPublicKey"] = credential.publicKey.base64EncodedString()
    unknownStrengthObject["presenceCredentialStrength"] = "quantumEntangled"
    do {
        _ = try SensoriumFrameCodec.decode(frame(fromObject: unknownStrengthObject))
        expect(false, "an unrecognised presence-credential strength string is refused as malformed")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "an unrecognised presence-credential strength reports malformedMessage, not some other error")
    }

    // A partial registration -- some of the four fields present, not all --
    // is exactly as unrepresentable as a hostScreenRequest naming neither or
    // both proof shapes: never partially trusted.
    var partialObject = baseObject
    partialObject["credentialID"] = credential.credentialID.base64EncodedString()
    do {
        _ = try SensoriumFrameCodec.decode(frame(fromObject: partialObject))
        expect(false, "a pairRequest carrying only some of the four presence-credential fields is refused as malformed")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "a partial presence-credential registration reports malformedMessage, not some other error")
    }
}


/// The pairing ceremony is the one path that may replace an already-paired
/// machine's registered presence credential, so the request that carries a
/// new one must prove the machine sending it holds the identity key it
/// names. `signature` is that proof: the machine's own signature over a
/// transcript of everything the request asks the host to write.
func testPairRequestSignatureRoundTripsAndBindsEveryFieldItCovers() {
    let identity = try! DeviceIdentity.generate()
    let credential = PresenceCredentialRegistration(
        credentialID: Data(repeating: 0x11, count: 16),
        publicKey: Data(repeating: 0x22, count: 32),
        credentialFormat: "apple-secure-enclave-p256",
        strength: "hardwareBound"
    )
    let transcript = SensoriumFrameCodec.pairRequestTranscript(
        deviceName: "MacBook",
        clientPublicKey: identity.publicKey,
        code: "123456",
        presenceCredential: credential
    )
    let signature = try! identity.sign(transcript)
    let signed = SensoriumMessage.pairRequest(
        deviceName: "MacBook",
        publicKey: identity.publicKey,
        code: "123456",
        presenceCredential: credential,
        signature: signature
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(signed)) == signed,
        "a pairRequest carrying a proof of possession round-trips it unchanged"
    )
    expect(
        DeviceIdentity.verify(signature: signature, message: transcript, publicKey: identity.publicKey),
        "the transcript the sender signs is the one a host rebuilds from the same four values"
    )

    // Every value the host would write from this request is inside the
    // transcript, so a proof made for one request cannot be lifted onto
    // another that asks for something different.
    let otherCredential = PresenceCredentialRegistration(
        credentialID: Data(repeating: 0x33, count: 16),
        publicKey: Data(repeating: 0x44, count: 32),
        credentialFormat: "apple-secure-enclave-p256",
        strength: "softwarePresence"
    )
    for (label, other) in [
        ("a different machine name", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "Another MacBook", clientPublicKey: identity.publicKey, code: "123456", presenceCredential: credential
        )),
        ("a different identity key", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "MacBook", clientPublicKey: Data(repeating: 0x55, count: 32), code: "123456", presenceCredential: credential
        )),
        ("a different pairing code", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "MacBook", clientPublicKey: identity.publicKey, code: "654321", presenceCredential: credential
        )),
        ("a different credential", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "MacBook", clientPublicKey: identity.publicKey, code: "123456", presenceCredential: otherCredential
        )),
        ("no credential at all", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "MacBook", clientPublicKey: identity.publicKey, code: "123456", presenceCredential: nil
        ))
    ] {
        expect(other != transcript, "\(label) produces a different transcript, so the proof does not carry over to it")
        expect(
            !DeviceIdentity.verify(signature: signature, message: other, publicKey: identity.publicKey),
            "the proof over one request does not verify \(label)"
        )
    }

    // A machine that predates this proof sends no signature at all, and
    // that request still decodes and still pairs -- the same
    // forward-compatibility the presence-credential fields already have.
    let unsigned = SensoriumMessage.pairRequest(
        deviceName: "MacBook", publicKey: identity.publicKey, code: "123456"
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(unsigned)) == unsigned,
        "a pairRequest with no proof of possession round-trips unchanged"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(unsigned), as: UTF8.self).contains("signature"),
        "a pairRequest with no proof omits the signature key entirely"
    )
}
