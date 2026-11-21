import Foundation

/// What the badge names: the connected machine and the display. Decided
/// once, AppKit-free, so the words the badge shows are testable without a
/// window server, the same split every other host presentation type in
/// this package already follows.
public struct HostScreenBadgeContent: Equatable, Sendable {
    public let deviceName: String
    public let displayLabel: String

    public init(deviceName: String, displayLabel: String) {
        self.deviceName = deviceName
        self.displayLabel = displayLabel
    }
}

/// Where the badge was last dropped on one display, relative to that
/// display's own full-frame origin -- `NSScreen.frame`, which includes the
/// menu bar and the Dock -- rather than an absolute screen coordinate, so
/// the same drop survives the whole desktop rearranging around it, and a
/// display that moves keeps the badge in the same place relative to itself.
public struct HostScreenBadgePosition: Codable, Equatable, Sendable {
    public var offsetFromFrameOrigin: CGPoint

    public init(offsetFromFrameOrigin: CGPoint) {
        self.offsetFromFrameOrigin = offsetFromFrameOrigin
    }
}

/// One display's placement geometry, as the badge window needs it: the full
/// frame a saved or default origin is read and clamped against, and the
/// visible frame -- menu bar and Dock excluded -- the very first,
/// nothing-remembered placement anchors to instead.
public struct HostScreenBadgeDisplayGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Where the host-screen badge was last dropped on each display, at
/// `~/Library/Application Support/Sensorium/host-screen-badge-position.json`.
/// Keyed by `HostScreenDisplayIdentity.wireStableIdentifier` -- the same
/// identity `HostScreenDeviceArming` already keys on -- so a different
/// monitor, one this machine has never remembered a drop for, gets its own
/// default rather than inheriting another display's spot. `@unchecked
/// Sendable`: every method is a synchronous whole-file read-modify-write
/// over a `let url`.
public final class HostScreenBadgePositionStore: @unchecked Sendable {
    private let url: URL

    /// The one instance production code uses. Tests build their own with a
    /// throwaway `url` instead, so one test's drop never leaks into another's.
    public static let shared = HostScreenBadgePositionStore(url: HostScreenBadgePositionStore.defaultURL)

    public init(url: URL) {
        self.url = url
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sensorium").appendingPathComponent("host-screen-badge-position.json")
    }

    public func position(for display: HostScreenDisplayIdentity) -> HostScreenBadgePosition? {
        load()[display.wireStableIdentifier]
    }

    public func setPosition(_ position: HostScreenBadgePosition, for display: HostScreenDisplayIdentity) {
        var all = load()
        all[display.wireStableIdentifier] = position
        save(all)
    }

    private func load() -> [String: HostScreenBadgePosition] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: HostScreenBadgePosition].self, from: data) else {
            return [:]
        }
        return map
    }

    private func save(_ map: [String: HostScreenBadgePosition]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

/// The badge's lifecycle, independent of any `NSWindow`. `stopTapped()`
/// records `hasStopped` on this object as well as calling `onStop`, so
/// stopping is observable state, not only a callback a caller might not
/// wire.
@MainActor
public final class HostScreenBadgeState {
    public let content: HostScreenBadgeContent
    /// `true` until `shrink()` is called. The badge is meant to open
    /// expanded for a few seconds before shrinking, so somebody in the
    /// room sees it begin, but no production caller schedules that call
    /// yet.
    public private(set) var isExpanded: Bool
    /// `true` once the person at this machine has collapsed the badge to its
    /// small corner pill. Independent of `isExpanded`: a collapsed badge has
    /// no expanded/shrunk distinction of its own, since the pill is already
    /// the smallest form the invariant allows.
    public private(set) var isCollapsed: Bool
    /// The badge window's own origin -- its bottom-left point, in AppKit
    /// screen coordinates, the same point `NSWindow.setFrameOrigin` takes.
    /// This is the anchor collapsing and expanding must never move, so the
    /// badge does not jump as its height changes. `nil` until something
    /// sets it: a persisted drop restored at launch, or the default
    /// placement the controller computes the first time it lays a badge
    /// out with nothing remembered for that display.
    public private(set) var origin: CGPoint?
    /// Set exactly once, by `stopTapped()`. The one fact that proves Stop
    /// ran: not that a callback fired, but that this object's own state now
    /// says the session is over.
    public private(set) var hasStopped = false
    public var onStop: (() -> Void)?
    /// Runs after `isExpanded` or `isCollapsed` changes, so whatever draws
    /// this state can re-lay itself out. Set by
    /// `HostScreenBadgeWindowController`.
    public var onExpansionChange: (() -> Void)?

    public init(
        content: HostScreenBadgeContent,
        startsExpanded: Bool = true,
        startsCollapsed: Bool = false,
        origin: CGPoint? = nil
    ) {
        self.content = content
        self.isExpanded = startsExpanded
        self.isCollapsed = startsCollapsed
        self.origin = origin
    }

    public func shrink() {
        isExpanded = false
        onExpansionChange?()
    }

    /// A click anywhere on the badge that is not Stop calls this.
    public func toggleCollapsed() {
        setCollapsed(!isCollapsed)
    }

    public func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        onExpansionChange?()
    }

    /// Whether the collapsed pill's fill should be breathing right now:
    /// exactly when the pill itself is showing. The badge only exists for
    /// the length of a live host-screen session, so this needs no session
    /// check of its own.
    public var collapsedPulses: Bool { isCollapsed }

    /// Records where a drag ended, or where the controller resolved a
    /// restored or default placement. Purely a fact about the badge's own
    /// position; it does not by itself move any window -- that is
    /// `HostScreenBadgeWindowController`'s job.
    public func setOrigin(_ origin: CGPoint) {
        self.origin = origin
    }

    /// `origin` clamped so a window of `windowSize` stays fully inside
    /// `screenFrame`. Generic over whatever rect a caller passes; the badge
    /// itself clamps against a screen's full `frame`, so a drop into the
    /// menu-bar or Dock strip stays exactly there. Pure geometry: no
    /// `NSScreen`, no `NSWindow`.
    public static func clampedOrigin(_ origin: CGPoint, windowSize: CGSize, in screenFrame: CGRect) -> CGPoint {
        let minX = screenFrame.minX
        let maxX = screenFrame.maxX - windowSize.width
        let minY = screenFrame.minY
        let maxY = screenFrame.maxY - windowSize.height
        let x = maxX >= minX ? min(max(origin.x, minX), maxX) : minX
        let y = maxY >= minY ? min(max(origin.y, minY), maxY) : minY
        return CGPoint(x: x, y: y)
    }

    /// Where a badge with nothing remembered for its display starts:
    /// top-right, inset by `margin` on both axes, then clamped exactly as
    /// any other placement would be.
    public static func defaultOrigin(windowSize: CGSize, in screenFrame: CGRect, margin: CGFloat) -> CGPoint {
        clampedOrigin(
            CGPoint(x: screenFrame.maxX - windowSize.width - margin, y: screenFrame.maxY - windowSize.height - margin),
            windowSize: windowSize,
            in: screenFrame
        )
    }

    /// The pure decision behind every mouse-up on the badge's background:
    /// whether a pointer that moved from `start` to `current` travelled far
    /// enough to count as a drag rather than a click. No `NSEvent`, so a
    /// test can drive it with plain points.
    public static func isDrag(from start: CGPoint, to current: CGPoint, threshold: CGFloat) -> Bool {
        hypot(current.x - start.x, current.y - start.y) > threshold
    }

    #if os(macOS)
    /// The two colours the badge's border gradient sweeps between, so a
    /// test can check the tokens feeding it without a window.
    public static let borderGradientColors: [DesignColor] = [CanvasDesign.accent, CanvasDesign.accent2]
    #endif
    /// One full sweep of the border gradient's rotation.
    public static let borderGradientRotationDuration: TimeInterval = 6
    /// One breath of the collapsed pill's fill.
    public static let collapsedPulseDuration: TimeInterval = 1.2
    /// The opacity range the collapsed pill's fill breathes between.
    public static let collapsedPulseOpacityRange: (from: CGFloat, to: CGFloat) = (1.0, 0.6)

    /// `sampleCount + 1` points evenly spaced around a circle of `radius`
    /// centred at (0.5, 0.5) -- the unit square a `CAGradientLayer`'s
    /// `startPoint`/`endPoint` are expressed in -- starting at `phaseOffset`
    /// radians and closing back on the first point, so a looped keyframe
    /// animation built from them has no seam. Pure geometry: no `CALayer`,
    /// no `NSWindow`.
    public static func borderGradientRotationKeyframes(sampleCount: Int, radius: CGFloat, phaseOffset: CGFloat) -> [CGPoint] {
        (0...sampleCount).map { step in
            let angle = phaseOffset + 2 * CGFloat.pi * CGFloat(step) / CGFloat(sampleCount)
            return CGPoint(x: 0.5 + radius * cos(angle), y: 0.5 + radius * sin(angle))
        }
    }

    /// Idempotent: a second tap -- a double click, or one that lands after
    /// the teardown it requested has already begun -- must not run the stop
    /// effect twice.
    public func stopTapped() {
        guard !hasStopped else { return }
        hasStopped = true
        onStop?()
    }
}
