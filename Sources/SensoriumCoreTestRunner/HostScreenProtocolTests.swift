import Foundation
import SensoriumCore

/// The same manual frame construction `testUnrecognizedMessageTypeIsSkippableNotFatal`
/// and `testMalformedControlJSONStillThrows` already use in main.swift, kept
/// local here rather than exported, since only these tests need it.
private func frame(fromJSON json: String) -> Data {
    let payload = Data(json.utf8)
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
}

private func expectMalformed(_ json: String, _ message: String) {
    do {
        _ = try SensoriumFrameCodec.decode(frame(fromJSON: json))
        expect(false, message)
    } catch SensoriumProtocolError.malformedMessage {
    } catch {
        expect(false, "\(message) (wrong error: \(error))")
    }
}

/// The four host-screen message types, decode/encode round-trips, the
/// older-peer forward-compatibility path, and the property that matters
/// most here -- a message can only ever reference an arming, a credential,
/// or a display the host already minted or already registered, never
/// assert one, and a malformed host-screen field refuses rather than
/// silently falling back to something else.
func testHostScreenProtocol() {
    let entry = HostScreenListEntry(
        opaqueToken: Data([0x01, 0x02]),
        label: "Studio Display",
        logicalWidth: 2560,
        logicalHeight: 1440,
        backingScale: 2.0,
        isBuiltin: false,
        displayIdentity: "00000610-00000028"
    )
    let token = Data([0x01, 0x02])
    let resumeTicket = Data([0xCC, 0xDD])
    let geometry = SessionSurfaceGeometry(logicalWidth: 2560, logicalHeight: 1440, backingScale: 2.0)

    // Round-trips: encode, then decode, is the identity
    let messages: [SensoriumMessage] = [
        .hostScreenList(displays: [entry]),
        .hostScreenRequest(token: token, resumeTicket: nil),
        .hostScreenRequest(token: token, resumeTicket: resumeTicket),
        .hostScreenReady(geometry: geometry, resumeTicket: resumeTicket),
        .hostScreenRefused(reason: "host-screen-not-allowed")
    ]
    for message in messages {
        let encoded = try! SensoriumFrameCodec.encode(message)
        let decoded = try! SensoriumFrameCodec.decode(encoded)
        expect(decoded == message, "\(message) round-trips through encode and decode unchanged")
    }

    print("PASS: hostScreenList, hostScreenRequest (fresh and resuming), hostScreenReady, and hostScreenRefused round-trip through encode and decode")

    // The older-peer path: an unknown type is skippable, never fatal
    let futureType = frame(fromJSON: "{\"type\":\"hostScreenSomethingNotInvented\"}")
    expect(
        try! SensoriumFrameCodec.decode(futureType) == .unrecognized(type: "hostScreenSomethingNotInvented"),
        "a host-screen message type this build has never heard of decodes as .unrecognized and is skippable, the same forward-compatibility path every other message type already has"
    )

    print("PASS: a host-screen message type this build does not know decodes as .unrecognized, not as a crash or a guess")

    // Malformed host-screen fields refuse, never fall back
    // Missing required fields on each of the four types.
    expectMalformed(
        "{\"type\":\"hostScreenList\"}",
        "hostScreenList missing its display list is rejected, not treated as an empty offer"
    )
    expectMalformed(
        "{\"type\":\"hostScreenRequest\"}",
        "hostScreenRequest naming no token is rejected, not treated as an empty-but-valid request"
    )
    expectMalformed(
        "{\"type\":\"hostScreenReady\",\"logicalWidth\":2560,\"logicalHeight\":1440,\"resumeTicket\":\"zN0=\"}",
        "hostScreenReady missing its backing scale is rejected, not defaulted to some assumed value"
    )
    expectMalformed(
        "{\"type\":\"hostScreenRefused\"}",
        "hostScreenRefused with no reason is rejected, not shown to the viewer as an unexplained refusal"
    )

    print("PASS: a host-screen message missing a required field refuses to decode rather than falling back to another shape")

    // displayIdentity: the stable identity that lets a viewer say
    // "the same display as last time" across two separate offers.
    let namedEntry = HostScreenListEntry(
        opaqueToken: Data([0x01, 0x02]),
        label: "Studio Display",
        logicalWidth: 2560,
        logicalHeight: 1440,
        backingScale: 2.0,
        isBuiltin: false,
        displayIdentity: "00000610-00000028"
    )
    let namedMessage = SensoriumMessage.hostScreenList(displays: [namedEntry])
    let namedDecoded = try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(namedMessage))
    expect(
        namedDecoded == namedMessage,
        "hostScreenList round-trips a display entry's own displayIdentity unchanged, alongside every other field"
    )
    guard case let .hostScreenList(decodedDisplays, _) = namedDecoded else {
        expect(false, "the round-tripped message is still a hostScreenList")
        return
    }
    expect(
        decodedDisplays.first?.displayIdentity == "00000610-00000028",
        "the specific value survives, not just the field's presence"
    )

    expectMalformed(
        "{\"type\":\"hostScreenList\",\"hostScreenDisplays\":"
            + "[{\"opaqueToken\":\"AQI=\",\"label\":\"Studio Display\",\"logicalWidth\":2560,"
            + "\"logicalHeight\":1440,\"backingScale\":2.0,\"isBuiltin\":false}]}",
        "a hostScreenList display entry missing displayIdentity entirely is rejected, not defaulted to something invented"
    )
    expectMalformed(
        "{\"type\":\"hostScreenList\",\"hostScreenDisplays\":"
            + "[{\"opaqueToken\":\"AQI=\",\"label\":\"Studio Display\",\"logicalWidth\":2560,"
            + "\"logicalHeight\":1440,\"backingScale\":2.0,\"isBuiltin\":false,\"displayIdentity\":\"\"}]}",
        "a hostScreenList display entry with an empty displayIdentity is rejected the same way a missing one is"
    )

    print("PASS: a hostScreenList display entry's own displayIdentity round-trips exactly, and a missing or empty one refuses as malformed")

    // A message can only reference an arming, never assert one
    // `hostScreenRequest` has no field for a credential strength, a tier, or
    // an armed-display description in the first place -- but proving that
    // requires more than reading the type declaration, since JSONDecoder
    // silently drops any JSON key a Codable type never declared. A hostile
    // or buggy peer that rides an arming-shaped claim along in the payload
    // gets exactly the same decoded value as one that did not.
    let cleanRequestJSON = "{\"type\":\"hostScreenRequest\",\"hostScreenToken\":\"AQI=\"}"
    let smuggledRequestJSON = """
    {"type":"hostScreenRequest","hostScreenToken":"AQI=",\
    "armedDisplays":[{"vendorNumber":1552,"modelNumber":40}],"armed":true}
    """
    let cleanDecoded = try! SensoriumFrameCodec.decode(frame(fromJSON: cleanRequestJSON))
    let smuggledDecoded = try! SensoriumFrameCodec.decode(frame(fromJSON: smuggledRequestJSON))
    expect(
        cleanDecoded == smuggledDecoded,
        "a hostScreenRequest with an arming-shaped claim (armedDisplays, armed) riding along in the JSON decodes identically to one without it -- the type has no field for either of those to land in, so the claim is not merely ignored by policy, it is structurally unrepresentable"
    )
    expect(
        cleanDecoded == .hostScreenRequest(token: token, resumeTicket: nil),
        "and what it does decode to is exactly the reference the token names -- nothing this session did not already mint"
    )

    print("PASS: a hostScreenRequest has no field an arming assertion could occupy, so a smuggled claim changes nothing that decodes")
}

/// The host screen's own display mode, on the wire: the list the host
/// offers, the viewer's pick, and the two answers to it. Every one of them
/// names a mode this host already offered -- a viewer can choose among the
/// modes macOS reports for that display and nothing else, which is what
/// keeps CLAUDE.md's "choosing among the modes macOS already offers" a
/// property of the message shapes rather than a rule somebody remembers to
/// check.
func testHostScreenModeProtocol() {
    let hiDPI = HostScreenModeEntry(
        modeID: "1920x1080@2",
        width: 1920,
        height: 1080,
        pixelWidth: 3840,
        pixelHeight: 2160,
        refreshRate: 60.0,
        isHiDPI: true
    )
    let native = HostScreenModeEntry(
        modeID: "3008x1692@1",
        width: 3008,
        height: 1692,
        pixelWidth: 3008,
        pixelHeight: 1692,
        refreshRate: 59.94,
        isHiDPI: false
    )
    let geometry = SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2.0)

    let messages: [SensoriumMessage] = [
        .hostScreenModeList(modes: [hiDPI, native], currentModeID: native.modeID),
        .hostScreenModeList(modes: [], currentModeID: ""),
        .hostScreenModeRequest(modeID: hiDPI.modeID),
        .hostScreenModeApplied(geometry: geometry, currentModeID: hiDPI.modeID),
        .hostScreenModeRefused(reason: "host-screen-mode-unknown")
    ]
    for message in messages {
        let encoded = try! SensoriumFrameCodec.encode(message)
        let decoded = try! SensoriumFrameCodec.decode(encoded)
        expect(decoded == message, "\(message) round-trips through encode and decode unchanged")
    }

    print("PASS: hostScreenModeList, hostScreenModeRequest, hostScreenModeApplied, and hostScreenModeRefused round-trip through encode and decode")

    expectMalformed(
        "{\"type\":\"hostScreenModeList\",\"hostScreenModeID\":\"1920x1080@2\"}",
        "hostScreenModeList missing its mode list is rejected, not read as an offer of no modes at all"
    )
    expectMalformed(
        "{\"type\":\"hostScreenModeList\",\"hostScreenModes\":[]}",
        "hostScreenModeList missing the mode the display is on now is rejected, not defaulted to the first one offered"
    )
    expectMalformed(
        "{\"type\":\"hostScreenModeList\",\"hostScreenModeID\":\"1920x1080@2\",\"hostScreenModes\":"
            + "[{\"modeID\":\"\",\"width\":1920,\"height\":1080,\"pixelWidth\":3840,\"pixelHeight\":2160,"
            + "\"refreshRate\":60.0,\"isHiDPI\":true}]}",
        "a mode entry with an empty modeID is rejected -- a viewer could never name it back, and a blank name is not a mode"
    )
    expectMalformed(
        "{\"type\":\"hostScreenModeRequest\"}",
        "hostScreenModeRequest naming no mode is rejected, not read as a request for some default"
    )
    expectMalformed(
        "{\"type\":\"hostScreenModeApplied\",\"logicalWidth\":1920,\"logicalHeight\":1080,\"backingScale\":2.0}",
        "hostScreenModeApplied that does not say which mode is now current is rejected"
    )
    expectMalformed(
        "{\"type\":\"hostScreenModeApplied\",\"hostScreenModeID\":\"1920x1080@2\",\"logicalWidth\":1920,\"logicalHeight\":1080}",
        "hostScreenModeApplied missing its backing scale is rejected, not defaulted -- the same rule hostScreenReady's own geometry already follows"
    )
    expectMalformed(
        "{\"type\":\"hostScreenModeRefused\"}",
        "hostScreenModeRefused with no reason is rejected, not shown to the viewer as an unexplained refusal"
    )

    print("PASS: a host-screen mode message missing a required field refuses to decode rather than falling back to an unnamed mode")

    let futureType = frame(fromJSON: "{\"type\":\"hostScreenModeSomethingNotInvented\"}")
    expect(
        try! SensoriumFrameCodec.decode(futureType) == .unrecognized(type: "hostScreenModeSomethingNotInvented"),
        "a host-screen mode message type this build has never heard of decodes as .unrecognized and is skippable, the same forward-compatibility path every other message type already has"
    )

    print("PASS: an unknown host-screen mode message decodes as .unrecognized, so an older peer skips it rather than dying")
}

/// A host that offers no session canvas says so in its offer, and the field
/// stays optional in both directions: an offer from a host that predates it
/// reads as offering one, and an offer carrying a field this build has
/// never heard of still decodes.
func testHostScreenListCarriesCanvasAvailability() {
    let entry = HostScreenListEntry(
        opaqueToken: Data([0x01, 0x02]),
        label: "Studio Display",
        logicalWidth: 2560,
        logicalHeight: 1440,
        backingScale: 2.0,
        isBuiltin: false,
        displayIdentity: "00000610-00000028"
    )
    for canvasAvailable in [true, false] {
        let message = SensoriumMessage.hostScreenList(displays: [entry], canvasAvailable: canvasAvailable)
        let decoded = try! SensoriumFrameCodec.decode(try! SensoriumFrameCodec.encode(message))
        expect(decoded == message, "hostScreenList with canvasAvailable \(canvasAvailable) round-trips unchanged")
    }

    let olderHost = frame(fromJSON: "{\"type\":\"hostScreenList\",\"hostScreenDisplays\":[]}")
    expect(
        try! SensoriumFrameCodec.decode(olderHost) == .hostScreenList(displays: [], canvasAvailable: true),
        "an offer from a host that predates the field reads as offering a session canvas"
    )

    let newerHost = frame(
        fromJSON: "{\"type\":\"hostScreenList\",\"hostScreenDisplays\":[],\"canvasAvailable\":false,"
            + "\"fieldNotYetInvented\":true}"
    )
    expect(
        try! SensoriumFrameCodec.decode(newerHost) == .hostScreenList(displays: [], canvasAvailable: false),
        "an offer carrying a field this build does not know still decodes, so an older viewer reads a newer host's offer"
    )

    print("PASS: hostScreenList carries canvas availability, defaults to available when absent, and tolerates unknown fields")
}
