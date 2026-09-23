import Foundation
import SensoriumCore

func testPairingCodeExpiresAndCannotBeReused() {
    let issuedAt = Date(timeIntervalSince1970: 1_000)
    var authority = PairingAuthority()
    let code = authority.issue(now: issuedAt, code: "123456")
    expect(code == "123456", "pairing issues the requested six-digit code")

    let grant = try! authority.approve(code: code, deviceID: "laptop", now: issuedAt.addingTimeInterval(1))
    expect(grant.deviceID == "laptop", "pairing grant binds the approved device")

    do {
        _ = try authority.approve(code: code, deviceID: "laptop", now: issuedAt.addingTimeInterval(2))
        expect(false, "pairing code cannot be reused")
    } catch PairingError.codeAlreadyConsumed {
    } catch {
        expect(false, "pairing reuse reports the expected error")
    }

    let expiredCode = authority.issue(now: issuedAt, code: "654321")
    do {
        _ = try authority.approve(code: expiredCode, deviceID: "laptop", now: issuedAt.addingTimeInterval(301))
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
            _ = try exhausted.approve(code: "999999", deviceID: "laptop", now: attemptedAt)
            expect(false, "wrong pairing code \(attempt) is rejected")
        } catch PairingError.invalidCode {
        } catch {
            expect(false, "wrong pairing code \(attempt) reports the expected error")
        }
    }
    do {
        _ = try exhausted.approve(code: exhaustedCode, deviceID: "laptop", now: attemptedAt)
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
        _ = try? nearMiss.approve(code: "000000", deviceID: "laptop", now: attemptedAt)
    }
    let nearMissGrant = try! nearMiss.approve(code: nearMissCode, deviceID: "laptop", now: attemptedAt)
    expect(nearMissGrant.deviceID == "laptop", "nine wrong codes still leave the tenth, correct one able to pair")
    do {
        _ = try nearMiss.approve(code: nearMissCode, deviceID: "laptop", now: attemptedAt)
        expect(false, "a code that paired cannot pair again")
    } catch PairingError.codeAlreadyConsumed {
    } catch {
        expect(false, "reuse after a near-miss pairing reports the expected error")
    }

    // Re-issuing is the recovery: a fresh code starts with a fresh budget.
    let reissuedCode = nearMiss.issue(now: issuedAt, code: "246810")
    for _ in 1..<PairingAuthority.maximumFailedAttempts {
        _ = try? nearMiss.approve(code: "000000", deviceID: "laptop", now: attemptedAt)
    }
    expect(
        (try? nearMiss.approve(code: reissuedCode, deviceID: "laptop", now: attemptedAt))?.deviceID == "laptop",
        "issuing a new code resets the failure budget"
    )

    // Expiry is refused on its own terms, with budget still to spare.
    var expiring = PairingAuthority()
    let expiringCode = expiring.issue(now: issuedAt, code: "864209")
    _ = try? expiring.approve(code: "000000", deviceID: "laptop", now: attemptedAt)
    do {
        _ = try expiring.approve(code: expiringCode, deviceID: "laptop", now: issuedAt.addingTimeInterval(301))
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
        .pairRequest(
            deviceName: "Laptop",
            publicKey: identity.publicKey,
            code: "123456",
            signature: try! identity.sign(SensoriumFrameCodec.pairRequestTranscript(
                deviceName: "Laptop",
                clientPublicKey: identity.publicKey,
                code: "123456"
            ))
        ),
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
/// `pairIntent` -- the true "shown the moment a new machine asks to pair"
/// moment, before that machine has a code to send at all.
func testPairIntentRoundTripsAndRefusesMalformed() {
    let message = SensoriumMessage.pairIntent(deviceName: "Kestrel Laptop Pro")
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

/// The pairing ceremony is the one path that may replace an already-paired
/// machine's registered name, so the request that carries a new one must
/// prove the machine sending it holds the identity key it names.
/// `signature` is that proof: the machine's own signature over a transcript
/// of everything the request asks the host to write.
func testPairRequestSignatureRoundTripsAndBindsEveryFieldItCovers() {
    let identity = try! DeviceIdentity.generate()
    let transcript = SensoriumFrameCodec.pairRequestTranscript(
        deviceName: "Laptop",
        clientPublicKey: identity.publicKey,
        code: "123456"
    )
    // Exact bytes, and the version that names them: this transcript's field
    // list changed after v1 shipped, so the prefix moved with it and a
    // signature made over either can never be read as the other.
    var expected = Data("sensorium-pair-request-v2|".utf8)
    expected.append(Data("Laptop".utf8))
    expected.append(0)
    expected.append(identity.publicKey.base64EncodedData())
    expected.append(0)
    expected.append(Data("123456".utf8))
    expect(transcript == expected, "the pairing-request transcript is the v2 prefix and three NUL-separated fields")

    let signature = try! identity.sign(transcript)
    let signed = SensoriumMessage.pairRequest(
        deviceName: "Laptop",
        publicKey: identity.publicKey,
        code: "123456",
        signature: signature
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(signed)) == signed,
        "a pairRequest carrying a proof of possession round-trips it unchanged"
    )
    expect(
        DeviceIdentity.verify(signature: signature, message: transcript, publicKey: identity.publicKey),
        "the transcript the sender signs is the one a host rebuilds from the same three values"
    )

    // Every value the host would write from this request is inside the
    // transcript, so a proof made for one request cannot be lifted onto
    // another that asks for something different.
    for (label, other) in [
        ("a different machine name", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "Another Laptop", clientPublicKey: identity.publicKey, code: "123456"
        )),
        ("a different identity key", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "Laptop", clientPublicKey: Data(repeating: 0x55, count: 32), code: "123456"
        )),
        ("a different pairing code", SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "Laptop", clientPublicKey: identity.publicKey, code: "654321"
        ))
    ] {
        expect(other != transcript, "\(label) produces a different transcript, so the proof does not carry over to it")
        expect(
            !DeviceIdentity.verify(signature: signature, message: other, publicKey: identity.publicKey),
            "the proof over one request does not verify \(label)"
        )
    }

    // A request carrying no proof at all never becomes a message: the
    // proof is what the whole ceremony rests on, so a frame without one is
    // refused where every other unreadable frame is, in the decoder.
    let payload = try! JSONSerialization.data(
        withJSONObject: [
            "type": "pairRequest",
            "deviceName": "Laptop",
            "publicKey": identity.publicKey.base64EncodedString(),
            "code": "123456"
        ],
        options: [.sortedKeys]
    )
    var unsignedFrame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { unsignedFrame.append(contentsOf: $0) }
    unsignedFrame.append(payload)
    do {
        _ = try SensoriumFrameCodec.decode(unsignedFrame)
        expect(false, "a pairRequest carrying no proof of possession is refused as malformed")
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "a pairRequest with no proof reports malformedMessage, not \(error)")
    }
}
