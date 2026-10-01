import SensoriumCore

/// Every name a person sees for a machine goes through `DeviceName.sanitized`:
/// the one a device reports on the wire, and one typed on either side.
func testDeviceNameSanitizerNeutralisesHostileNames() {
    expect(DeviceName.maximumLength == 64, "the cap is 64 characters")
    expect(DeviceName.sanitized("Studio Mac") == "Studio Mac", "an ordinary name is kept as it is")
    expect(DeviceName.sanitized("  Studio Mac \n") == "Studio Mac", "surrounding whitespace is trimmed")

    expect(
        DeviceName.sanitized("Studio\u{202E}caM") == "StudiocaM",
        "a right-to-left override is removed, so it cannot reorder what follows it"
    )
    expect(
        DeviceName.sanitized("\u{2066}Studio\u{2069} Mac") == "Studio Mac",
        "bidi isolates are removed"
    )
    expect(
        DeviceName.sanitized("Stu\u{200D}dio\u{200B}Mac\u{FEFF}") == "StudioMac",
        "zero-width joiners, spaces and byte-order marks are removed"
    )
    expect(
        DeviceName.sanitized("Studio\nMac\r\n\tPro") == "Studio Mac Pro",
        "a newline or tab becomes one space, not nothing"
    )
    expect(
        DeviceName.sanitized("Studio \u{200B} \u{00A0}\u{2028} Mac") == "Studio Mac",
        "any run of whitespace, with removed characters inside it, collapses to one space"
    )
    expect(
        DeviceName.sanitized("Studio\u{0007}\u{001B}[31mMac") == "Studio[31mMac",
        "other control characters are removed"
    )

    let long = String(repeating: "a", count: 10_000)
    expect(
        DeviceName.sanitized(long) == String(repeating: "a", count: 64),
        "a 10 000-character name is cut to 64"
    )
    let emoji = String(repeating: "\u{1F5A5}\u{FE0F}", count: 70)
    expect(DeviceName.sanitized(emoji)?.count == 64, "the cap counts characters a person sees, not bytes")
    expect(
        DeviceName.sanitized(String(repeating: "a", count: 63) + " b") == String(repeating: "a", count: 63),
        "a cut that lands on a space leaves no trailing space"
    )

    expect(DeviceName.sanitized("") == nil, "an empty name is no name")
    expect(DeviceName.sanitized(" \n\t ") == nil, "a name of only whitespace is no name")
    expect(
        DeviceName.sanitized("\u{202E}\u{200B}\u{0000}\u{0007}\u{FEFF}") == nil,
        "a name of only control and format characters is no name"
    )
}
