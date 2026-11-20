#if os(Linux)

import SensoriumLinuxHost

private func roundTrip(_ value: PortalValue) -> (PortalValue, String) {
    let variant = GVariantBridge.makeVariant(value)
    // Hold a reference so the type can be read after conversion.
    let signature = GVariantBridge.typeString(of: variant)
    return (GVariantBridge.consume(variant), signature)
}

func testScalarsRoundTripThroughGVariant() {
    let cases: [(PortalValue, String)] = [
        (.string("hello"), "s"),
        (.objectPath("/org/example/Path"), "o"),
        (.bool(true), "b"),
        (.bool(false), "b"),
        (.int32(-7), "i"),
        (.uint32(4_000_000_000), "u"),
        (.uint64(9_000_000_000_000), "t"),
        (.double(1.5), "d"),
        (.variant(.uint32(2)), "v")
    ]
    for (value, signature) in cases {
        let (back, produced) = roundTrip(value)
        expect(produced == signature, "\(value) is type \(signature), got \(produced)")
        expect(back == value, "\(value) survives the round trip, got \(back)")
    }
}

func testOptionsDictionaryIsAVardictWithUnwrappedValues() {
    let options = PortalValue.vardict([
        "handle_token": .string("abc"),
        "types": .uint32(3),
        "multiple": .bool(false)
    ])
    let (back, signature) = roundTrip(options)
    expect(signature == "a{sv}", "options are a{sv}, got \(signature)")
    expect(back == options, "options survive the round trip, got \(back)")
    let (empty, emptySignature) = roundTrip(.vardict([:]))
    expect(emptySignature == "a{sv}" && empty == .vardict([:]), "an empty options dictionary keeps its type")
}

func testAStartResultRoundTripsWithItsStreamsArray() {
    let streams = PortalValue.array([
        .tuple([.uint32(57), .vardict([
            "id": .string("monitor-a"),
            "size": .tuple([.int32(1920), .int32(1080)]),
            "pipewire-serial": .uint64(12)
        ])])
    ], elementSignature: "(ua{sv})")
    let results = PortalValue.vardict(["streams": streams, "devices": .uint32(3), "restore_token": .string("t")])
    let (back, signature) = roundTrip(results)
    expect(signature == "a{sv}", "results are a{sv}")
    expect(back == results, "the results survive the round trip, got \(back)")
    let (arrayBack, arraySignature) = roundTrip(streams)
    expect(arraySignature == "a(ua{sv})", "streams are a(ua{sv}), got \(arraySignature)")
    expect(arrayBack == streams, "streams survive")
    let (emptyBack, emptySignature) = roundTrip(.array([], elementSignature: "(ua{sv})"))
    expect(emptySignature == "a(ua{sv})" && emptyBack == .array([], elementSignature: "(ua{sv})"), "an empty array keeps its type")
}

func testAMethodArgumentTupleHasTheShapeOfItsArguments() {
    let variant = GVariantBridge.makeTuple([.objectPath("/s"), .vardict([:]), .uint32(5), .double(1), .double(2)])
    expect(GVariantBridge.typeString(of: variant) == "(oa{sv}udd)", "arguments (o, a{sv}, u, d, d), got \(GVariantBridge.typeString(of: variant))")
    guard case let .tuple(items) = GVariantBridge.consume(variant) else {
        expect(false, "a tuple comes back as a tuple")
        return
    }
    expect(items.count == 5, "five arguments")
}

func gvariantBridgeTests() -> [NamedTest] { [
    ("scalars round-trip through GVariant", testScalarsRoundTripThroughGVariant),
    ("options are an a{sv} with unwrapped values", testOptionsDictionaryIsAVardictWithUnwrappedValues),
    ("a Start result round-trips with its streams array", testAStartResultRoundTripsWithItsStreamsArray),
    ("a method argument tuple has the shape of its arguments", testAMethodArgumentTupleHasTheShapeOfItsArguments)
] }

#endif
