import Foundation
import SensoriumCore

func testHelloMessageRoundTripsThroughVersionedFrame() {
    let message = SensoriumMessage.hello(protocolVersion: 1, deviceName: "Mini")
    let encoded = try! SensoriumFrameCodec.encode(message)
    let decoded = try! SensoriumFrameCodec.decode(encoded)
    expect(decoded == message, "hello message round-trips through versioned frame")
}

func testCanvasControlMessagesRoundTripThroughVersionedFrame() {
    let messages: [SensoriumMessage] = [
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
        .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil),
        .goodbye(reason: "client-disconnected")
    ]

    for message in messages {
        let encoded = try! SensoriumFrameCodec.encode(message)
        let decoded = try! SensoriumFrameCodec.decode(encoded)
        expect(decoded == message, "\(message) round-trips through versioned frame")
    }
}

/// `surfaceID` exists purely to de-risk the wire format for a future second
/// canvas: `protocolVersion` stays at 1, so an old peer that has never heard
/// of the field must keep working against a new one, and vice versa.
func testCanvasRequestAndReadySurfaceIDRoundTripWhenPresentOrAbsent() {
    let requestWithSurface = SensoriumMessage.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 3)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(requestWithSurface)) == requestWithSurface,
        "a canvas request carrying a surfaceID round-trips it unchanged"
    )

    let requestWithoutSurface = SensoriumMessage.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(requestWithoutSurface)) == requestWithoutSurface,
        "a canvas request without a surfaceID round-trips to nil"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(requestWithoutSurface), as: UTF8.self).contains("surfaceID"),
        "a canvas request without a surfaceID omits the key entirely instead of encoding null"
    )

    let readyWithSurface = SensoriumMessage.canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 3)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(readyWithSurface)) == readyWithSurface,
        "a canvas ready carrying a surfaceID round-trips it unchanged"
    )

    let readyWithoutSurface = SensoriumMessage.canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(readyWithoutSurface)) == readyWithoutSurface,
        "a canvas ready without a surfaceID round-trips to nil"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(readyWithoutSurface), as: UTF8.self).contains("surfaceID"),
        "a canvas ready without a surfaceID omits the key entirely instead of encoding null"
    )
}

/// `hostName` follows `surfaceID`'s own forward-compatibility rule: present,
/// absent, and never encoded as a wire `null`.
func testCanvasReadyHostNameRoundTripsWhenPresentOrAbsent() {
    let readyWithHostName = SensoriumMessage.canvasReady(
        displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil, hostName: "Mac mini"
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(readyWithHostName)) == readyWithHostName,
        "a canvas ready carrying a hostName round-trips it unchanged"
    )

    let readyWithoutHostName = SensoriumMessage.canvasReady(
        displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil
    )
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(readyWithoutHostName)) == readyWithoutHostName,
        "a canvas ready without a hostName round-trips to nil"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(readyWithoutHostName), as: UTF8.self).contains("hostName"),
        "a canvas ready without a hostName omits the key entirely instead of encoding null"
    )
}

/// A legacy peer's decoder, frozen at the wire shape before `surfaceID`
/// existed. `JSONDecoder` ignores unknown keys, so decoding a payload that
/// carries `surfaceID` with this struct proves an old peer survives talking
/// to a new one, instead of merely proving the new codec round-trips itself.
private struct LegacyCanvasWireMessage: Decodable, Equatable {
    let type: String
    let logicalWidth: Int?
    let logicalHeight: Int?
    let scale: Int?
    let displayID: UInt32?
}

func testCanvasControlMessagesStayWireCompatibleAcrossSurfaceID() {
    func frame(fromObject object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    // Direction one: an old-shape payload, produced before surfaceID existed
    // (no key at all), still decodes on today's codec with surfaceID nil.
    let oldRequestFrame = frame(fromObject: [
        "type": "canvasRequest",
        "logicalWidth": 1920,
        "logicalHeight": 1200,
        "scale": 2
    ])
    expect(
        (try? SensoriumFrameCodec.decode(oldRequestFrame)) ==
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
        "an old-shape canvasRequest payload with no surfaceID key still decodes, with surfaceID nil"
    )

    let oldReadyFrame = frame(fromObject: [
        "type": "canvasReady",
        "displayID": 42,
        "logicalWidth": 1920,
        "logicalHeight": 1200
    ])
    expect(
        (try? SensoriumFrameCodec.decode(oldReadyFrame)) ==
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil),
        "an old-shape canvasReady payload with no surfaceID key still decodes, with surfaceID nil"
    )

    // Direction two: a new-shape payload that does carry surfaceID still
    // decodes on a struct shaped like an old peer's, which has never heard of
    // the key and simply ignores it.
    let newRequestPayload = try! SensoriumFrameCodec.encode(
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 3)
    ).dropFirst(4)
    let legacyDecodedRequest = try! JSONDecoder().decode(LegacyCanvasWireMessage.self, from: Data(newRequestPayload))
    expect(
        legacyDecodedRequest == LegacyCanvasWireMessage(type: "canvasRequest", logicalWidth: 1920, logicalHeight: 1200, scale: 2, displayID: nil),
        "a canvasRequest payload carrying surfaceID still decodes on an old peer's decoder, which ignores the unknown key"
    )

    let newReadyPayload = try! SensoriumFrameCodec.encode(
        .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 3)
    ).dropFirst(4)
    let legacyDecodedReady = try! JSONDecoder().decode(LegacyCanvasWireMessage.self, from: Data(newReadyPayload))
    expect(
        legacyDecodedReady == LegacyCanvasWireMessage(type: "canvasReady", logicalWidth: 1920, logicalHeight: 1200, scale: nil, displayID: 42),
        "a canvasReady payload carrying surfaceID still decodes on an old peer's decoder, which ignores the unknown key"
    )
}

/// A legacy peer's decoder for `input`/`viewerDrawableSize`, frozen at the wire
/// shape before `surfaceID` reached those two messages.
private struct LegacyEventWireMessage: Decodable, Equatable {
    let type: String
    let drawablePixelWidth: Double?
    let drawablePixelHeight: Double?
}

/// `input` and `viewerDrawableSize` are the messages a routing key actually
/// matters for once a second canvas exists: an input event or a resize aimed
/// at one window must not land on the other. `releaseAllInput` is checked on
/// its own because it carries no other payload at all -- if `surfaceID` had
/// been threaded onto the wrong shape (say, nested inside `WireInput`) an
/// empty-payload kind like this one would be the first thing to expose it.
func testInputAndViewerDrawableSizeSurfaceIDRoundTripWhenPresentOrAbsent() {
    func frame(fromObject object: [String: Any]) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    let events: [(String, SensoriumInputEvent)] = [
        ("pointerMoved", .pointerMoved(x: 12, y: 34)),
        ("releaseAllInput", .releaseAllInput)
    ]
    for (name, event) in events {
        let withSurface = SensoriumMessage.input(event, surfaceID: 1)
        expect(
            try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withSurface)) == withSurface,
            "an \(name) input event carrying a surfaceID round-trips it unchanged"
        )

        let withoutSurface = SensoriumMessage.input(event, surfaceID: nil)
        expect(
            try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withoutSurface)) == withoutSurface,
            "an \(name) input event without a surfaceID round-trips to nil"
        )
        expect(
            !String(decoding: try! SensoriumFrameCodec.encode(withoutSurface), as: UTF8.self).contains("surfaceID"),
            "an \(name) input event without a surfaceID omits the key entirely instead of encoding null"
        )
    }

    // Direction one: an old-shape payload with no surfaceID key still
    // decodes, with surfaceID nil.
    let oldReleaseAllFrame = frame(fromObject: [
        "type": "input",
        "input": ["kind": "releaseAllInput"]
    ])
    expect(
        (try? SensoriumFrameCodec.decode(oldReleaseAllFrame)) == .input(.releaseAllInput, surfaceID: nil),
        "an old-shape releaseAllInput payload with no surfaceID key still decodes, with surfaceID nil"
    )

    // Direction two: a new-shape payload carrying surfaceID still decodes on
    // an old peer's decoder, which ignores the unknown key.
    let newReleaseAllPayload = try! SensoriumFrameCodec.encode(.input(.releaseAllInput, surfaceID: 1)).dropFirst(4)
    let legacyDecodedReleaseAll = try! JSONDecoder().decode(LegacyEventWireMessage.self, from: Data(newReleaseAllPayload))
    expect(
        legacyDecodedReleaseAll == LegacyEventWireMessage(type: "input", drawablePixelWidth: nil, drawablePixelHeight: nil),
        "a releaseAllInput payload carrying surfaceID still decodes on an old peer's decoder"
    )

    let withSurface = SensoriumMessage.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: 1, maximumScale: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withSurface)) == withSurface,
        "a viewer drawable size carrying a surfaceID round-trips it unchanged"
    )

    let withoutSurface = SensoriumMessage.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(withoutSurface)) == withoutSurface,
        "a viewer drawable size without a surfaceID round-trips to nil"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(withoutSurface), as: UTF8.self).contains("surfaceID"),
        "a viewer drawable size without a surfaceID omits the key entirely instead of encoding null"
    )

    let oldViewerFrame = frame(fromObject: [
        "type": "viewerDrawableSize",
        "drawablePixelWidth": 3840,
        "drawablePixelHeight": 2400
    ])
    expect(
        (try? SensoriumFrameCodec.decode(oldViewerFrame)) ==
            .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil),
        "an old-shape viewerDrawableSize payload with no surfaceID key still decodes, with surfaceID nil"
    )

    let newViewerPayload = try! SensoriumFrameCodec.encode(withSurface).dropFirst(4)
    let legacyDecodedViewer = try! JSONDecoder().decode(LegacyEventWireMessage.self, from: Data(newViewerPayload))
    expect(
        legacyDecodedViewer == LegacyEventWireMessage(type: "viewerDrawableSize", drawablePixelWidth: 3840, drawablePixelHeight: 2400),
        "a viewerDrawableSize payload carrying surfaceID still decodes on an old peer's decoder"
    )
}

/// `surfaceID` decides which window a routed message lands on, so it must be
/// inside the signed transcript like every other field a tampering peer must
/// not move -- otherwise the one field that decides routing would be the one
/// field outside the signature.
func testCanvasReadyTranscriptCoversSurfaceIDAndTamperingFailsVerification() {
    let identity = try! DeviceIdentity.generate()
    let clientKey = try! DeviceIdentity.generate().publicKey

    func transcript(surfaceID: UInt32?) -> Data {
        SensoriumFrameCodec.canvasReadyTranscript(
            displayID: 7,
            logicalWidth: 1920,
            logicalHeight: 1200,
            clientPublicKey: clientKey,
            surfaceID: surfaceID
        )
    }

    let transcriptAbsent = transcript(surfaceID: nil)
    let transcriptZero = transcript(surfaceID: 0)
    let transcriptOne = transcript(surfaceID: 1)
    expect(transcriptAbsent != transcriptZero, "an absent surfaceID produces a different transcript than surfaceID 0")
    expect(transcriptZero != transcriptOne, "surfaceID 0 and surfaceID 1 produce different transcripts")
    expect(transcriptAbsent != transcriptOne, "an absent surfaceID produces a different transcript than surfaceID 1")

    let signatureOverZero = try! identity.sign(transcriptZero)
    expect(
        DeviceIdentity.verify(signature: signatureOverZero, message: transcriptZero, publicKey: identity.publicKey),
        "a signature over surfaceID 0's transcript verifies against that same transcript"
    )
    expect(
        !DeviceIdentity.verify(signature: signatureOverZero, message: transcriptOne, publicKey: identity.publicKey),
        "a canvasReady whose surfaceID was tampered with in transit (0 -> 1) fails signature verification"
    )
    expect(
        !DeviceIdentity.verify(signature: signatureOverZero, message: transcriptAbsent, publicKey: identity.publicKey),
        "a canvasReady whose surfaceID was stripped in transit (0 -> absent) also fails signature verification"
    )
}

func testAuthenticatedHelloRoundTripsAndVerifies() {
    let identity = try! DeviceIdentity.generate()
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1,
        deviceName: "MacBook",
        publicKey: identity.publicKey
    )
    let message = SensoriumMessage.authenticatedHello(
        protocolVersion: 1,
        deviceName: "MacBook",
        publicKey: identity.publicKey,
        signature: try! identity.sign(transcript)
    )
    let decoded = try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message))
    expect(decoded == message, "authenticated hello round-trips through versioned frame")
    if case let .authenticatedHello(version, name, publicKey, signature) = decoded {
        let decodedTranscript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: version,
            deviceName: name,
            publicKey: publicKey
        )
        expect(DeviceIdentity.verify(signature: signature, message: decodedTranscript, publicKey: publicKey), "authenticated hello signature verifies")
    } else {
        expect(false, "authenticated hello decodes to the expected message")
    }
}

func testInputEventsRoundTripThroughVersionedFrame() {
    let events: [SensoriumInputEvent] = [
        .pointerMoved(x: 12, y: 34),
        .pointerMovedRelative(deltaX: -4.5, deltaY: 9),
        .pointerButton(button: .left, isDown: true, x: 100, y: 200),
        .pointerButton(button: .right, isDown: false, x: 0, y: 1200),
        .scrolled(deltaX: -3.5, deltaY: 7.25, x: 640, y: 480, phase: nil, momentumPhase: nil),
        .scrolled(deltaX: 0.4, deltaY: 0.4, x: 640, y: 480, phase: .began, momentumPhase: nil),
        .scrolled(deltaX: 0, deltaY: 12, x: 640, y: 480, phase: nil, momentumPhase: .continue),
        .key(keyCode: 53, isDown: true, modifiers: [.command, .shift]),
        .key(keyCode: 53, isDown: false, modifiers: []),
        .releaseAllInput,
        .pointerCaptureChanged(isCaptured: true),
        .pointerCaptureChanged(isCaptured: false)
    ]
    for event in events {
        let encoded = try! SensoriumFrameCodec.encode(.input(event, surfaceID: nil))
        expect(
            try! SensoriumFrameCodec.decode(encoded) == .input(event, surfaceID: nil),
            "input event \(event) round-trips through the versioned frame"
        )
    }
}

/// `SessionMetricStage.inputRoundTrip`'s own wire shapes: `input`'s optional
/// `sequence` tag, and `inputApplied`, the host's small acknowledgement of
/// it -- see the doc comments on both cases in ProtocolMessages.swift.
func testInputSequenceAndInputAppliedRoundTripAndUnrecognizedDecodesSafely() {
    let tagged = SensoriumMessage.input(.pointerMoved(x: 12, y: 34), surfaceID: nil, sequence: 7)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(tagged)) == tagged,
        "an input event carrying a sequence round-trips it unchanged"
    )

    let untagged = SensoriumMessage.input(.pointerMoved(x: 12, y: 34), surfaceID: nil)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(untagged)) == untagged,
        "an input event without a sequence round-trips to nil"
    )
    expect(
        !String(decoding: try! SensoriumFrameCodec.encode(untagged), as: UTF8.self).contains("inputSequence"),
        "an input event without a sequence omits the key entirely instead of encoding null, exactly as an old peer's bytes already look"
    )

    let applied = SensoriumMessage.inputApplied(sequence: 42)
    expect(
        try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(applied)) == applied,
        "inputApplied round-trips its sequence unchanged"
    )
    expect(
        (try? SensoriumFrameCodec.encode(.inputApplied(sequence: 0))) != nil,
        "a sequence of zero, the very first input a session sends, is not mistaken for an absent one"
    )
    do {
        let payload = try! JSONSerialization.data(withJSONObject: ["type": "inputApplied"], options: [.sortedKeys])
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        do {
            _ = try SensoriumFrameCodec.decode(frame)
            expect(false, "an inputApplied payload with no sequence at all is malformed, not a valid zero-carrying message")
        } catch SensoriumProtocolError.malformedMessage {
        } catch {
            expect(false, "an inputApplied payload with no sequence throws the expected malformed error, got \(error)")
        }
    }

    // A peer running a build that predates inputApplied decodes it as
    // .unrecognized rather than failing outright -- the same
    // forward-compatibility path viewerFocus and telemetry already take,
    // exercised here with a message name this build itself does not know.
    let futurePayload = Data("{\"type\":\"futureInputAcknowledgement\"}".utf8)
    var futureFrame = Data()
    var futureLength = UInt32(futurePayload.count).bigEndian
    withUnsafeBytes(of: &futureLength) { futureFrame.append(contentsOf: $0) }
    futureFrame.append(futurePayload)
    expect(
        (try? SensoriumFrameCodec.decode(futureFrame)) == .unrecognized(type: "futureInputAcknowledgement"),
        "a message type this build does not know -- exactly what an older build sees for inputApplied before it existed -- decodes to .unrecognized rather than throwing"
    )
}

