import SensoriumClient

/// The pure decision behind the pinned strip's own band: it claims the top
/// edge only while pinned and actually open, and the video gets back exactly
/// what is left.
func testShortcutStripLayoutPolicyTests() {
    expect(
        ShortcutStripLayoutPolicy.videoTopInset(isPinned: false, isStripOpen: true, stripHeight: 44) == 0,
        "an unpinned strip claims no band, even while it is open over the picture"
    )
    expect(
        ShortcutStripLayoutPolicy.videoTopInset(isPinned: true, isStripOpen: false, stripHeight: 44) == 0,
        "a pinned strip that is not actually open claims no band"
    )
    expect(
        ShortcutStripLayoutPolicy.videoTopInset(isPinned: true, isStripOpen: true, stripHeight: 44) == 44,
        "a pinned, open strip claims exactly its own height"
    )

    expect(
        ShortcutStripLayoutPolicy.videoHeight(fullHeight: 600, topInset: 0) == 600,
        "no inset leaves the video the whole window"
    )
    expect(
        ShortcutStripLayoutPolicy.videoHeight(fullHeight: 600, topInset: 44) == 556,
        "the video gives up exactly the band's own height"
    )
    expect(
        ShortcutStripLayoutPolicy.videoHeight(fullHeight: 40, topInset: 44) == 0,
        "an inset taller than the window never leaves the video a negative height"
    )

    print("PASS: the pinned strip's band claims the top edge only while open, and the video gets back exactly what is left")
}
