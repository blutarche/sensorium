import AppKit
import Foundation
import SensoriumHost

/// The empty-catalog subtext ("Install an application on `<machine>` and
/// reconnect.") names the host by its own name, which a person chooses
/// and this code does not bound -- a long one must wrap, not run past the
/// panel's own inset. Reached through `CanvasHostTestHooks`, a
/// `package`-access seam that stays visible in a release build, unlike
/// `@testable import`.
@MainActor
func runCanvasLauncherEmptyStateWrapTests() async {
    // A no-match filter is the only headless route to a real empty state:
    // the catalog itself is this machine's own installed applications and
    // cannot be emptied without reading the disk. See
    // `Scripts/render-ui-previews.swift`'s own empty-catalog render for the
    // same seam.
    let placement = CanvasHostTestHooks.placementForTesting(displayID: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200))
    let result = CanvasHostTestHooks.launcherEmptyStateSubtext(
        frame: NSRect(x: 0, y: 0, width: 440, height: 1104),
        canvas: placement,
        hostName: "Alex Kestrel-Whitfield's Sixteen-Inch Laptop Pro (2024, Space Black)"
    )
    let subtext = result.subtext

    let inset = CanvasDesign.Space.md
    expect(
        subtext.maximumNumberOfLines == 0 && subtext.lineBreakMode == .byWordWrapping,
        "a long host name wraps instead of clipping -- got maximumNumberOfLines "
            + "\(subtext.maximumNumberOfLines), lineBreakMode \(subtext.lineBreakMode.rawValue)"
    )
    expect(
        abs(subtext.frame.minX - inset) < 0.5 && abs(subtext.frame.maxX - (result.emptyStateWidth - inset)) < 0.5,
        "the subtext's frame stays within the empty state's own inset on both edges, never edge to edge -- "
            + "got frame \(subtext.frame) in a \(result.emptyStateWidth)pt-wide empty state"
    )

    print("PASS: a long host name in the empty-catalog subtext wraps within the empty state's own inset instead of running edge to edge")

    // An ordinary host name -- short enough that its sentence's own
    // natural width sits only just past this empty state's own width, not
    // far past it -- must still wrap, and the subtext's own frame must
    // stay tall enough to hold the wrapped second line. This is the
    // borderline this empty state actually meets in practice; a long
    // enough overrun wraps regardless of how the wrapped height is
    // measured, so it does not by itself catch a frame left sized for a
    // single line.
    let ordinary = CanvasHostTestHooks.launcherEmptyStateSubtext(
        frame: NSRect(x: 0, y: 0, width: 440, height: 1104),
        canvas: placement,
        hostName: "kestrel-minim4"
    )
    let ordinarySubtext = ordinary.subtext
    let ordinaryUsableWidth = ordinary.emptyStateWidth - inset * 2
    let neededHeight = ordinarySubtext.cell?.cellSize(
        forBounds: NSRect(x: 0, y: 0, width: ordinaryUsableWidth, height: .greatestFiniteMagnitude)
    ).height ?? 0
    expect(
        ordinarySubtext.frame.height >= neededHeight - 0.5,
        "the subtext's own frame grows to hold every wrapped line, not just the first -- "
            + "got height \(ordinarySubtext.frame.height), but its own cell needs \(neededHeight) to draw "
            + "\u{201C}\(ordinarySubtext.stringValue)\u{201D} at \(ordinaryUsableWidth)pt wide"
    )

    print("PASS: an ordinary host name that only just needs a second line still gets a frame tall enough to hold it")

    // An empty status -- the empty-catalog case, whose status line is left
    // blank in favour of the empty state's own subtext -- must not still
    // reserve the vertical slot a real status line needs: rendered, the
    // omitted line doubled the gap before the hint below it.
    let frame = NSRect(x: 0, y: 0, width: 440, height: 1104)
    let withStatus = CanvasHostTestHooks.launcherStatusLayout(
        frame: frame,
        canvas: placement,
        status: CanvasLauncherStatus(text: "3 applications", severity: .neutral)
    )
    let withoutStatus = CanvasHostTestHooks.launcherStatusLayout(
        frame: frame,
        canvas: placement,
        status: CanvasLauncherStatus(text: "", severity: .neutral)
    )
    expect(
        withoutStatus.statusFrame.height == 0,
        "an empty status collapses its own row entirely -- got height \(withoutStatus.statusFrame.height)"
    )
    expect(
        withStatus.statusFrame.height > 0,
        "a real status still reserves the room it needs -- got height \(withStatus.statusFrame.height)"
    )
    // CanvasLauncherView is not flipped: higher y sits visually above lower
    // y, so the status (above the hint) has the larger y, and the gap
    // between them is the status's own minY less the hint's maxY.
    expect(
        abs((withStatus.statusFrame.minY - withStatus.hintFrame.maxY) - CanvasDesign.Space.xs) < 0.5,
        "the hint sits its usual gap below a real status line -- got status \(withStatus.statusFrame), hint \(withStatus.hintFrame)"
    )
    expect(
        abs(withoutStatus.statusFrame.minY - withoutStatus.hintFrame.maxY) < 0.5,
        "with nothing to show, the status row leaves no gap for the hint to sit under -- got status "
            + "\(withoutStatus.statusFrame), hint \(withoutStatus.hintFrame)"
    )

    print("PASS: an empty status collapses its own row instead of doubling the gap before the hint")

    // The footer already says "Type to filter" -- the query field's own
    // placeholder repeating "Type a name" said the same instruction twice.
    let placeholder = CanvasHostTestHooks.launcherQueryPlaceholder(
        frame: NSRect(x: 0, y: 0, width: 440, height: 1104),
        canvas: placement
    )
    expect(
        placeholder == "Filter by name",
        "the query field's own placeholder names what typing does, without repeating the footer's own "
            + "\"Type to filter\" -- got: \(placeholder)"
    )

    print("PASS: the query field's placeholder reads Filter by name, not a second Type instruction")
}
