import Foundation
import SensoriumCore

/// The display modes of one host screen, and the two operations a live
/// session may perform on them.
///
/// The only display configuration Sensorium performs on a display it did not
/// create: the mode of the host screen a session is streaming, on the
/// viewer's request, from the modes macOS already reports, always put back.
/// A seam rather than direct CoreGraphics calls so that rule is verified
/// against a fake.
@MainActor
public protocol HostScreenModeControlling: AnyObject {
    /// Every mode this display can be set to, as macOS reports them.
    func modes(for displayID: UInt32) -> [HostScreenModeEntry]
    /// The mode it is on right now, or `nil` if that cannot be read.
    func currentModeID(for displayID: UInt32) -> String?
    /// Sets the display to `modeID`, which must be one `modes(for:)`
    /// returned. `false` means the display is still on whatever it was on.
    /// The mode it was on before the first successful call for this display
    /// is remembered here, so `restore(displayID:)` needs no argument and
    /// cannot be handed the wrong one.
    func apply(modeID: String, to displayID: UInt32) -> Bool
    /// Puts the display back on the mode it was on before the first
    /// successful `apply`. `false` means either that there was nothing to
    /// put back or that putting it back did not work; in the second case
    /// what the display must go back to is still remembered, so a later
    /// attempt can still make it. A record is forgotten only by a restore
    /// that actually took, because forgetting one that did not is how a
    /// display ends up left on a mode a session chose for it.
    @discardableResult
    func restore(displayID: UInt32) -> Bool
    /// The same for every display this controller has changed and not yet
    /// restored -- the host's own last word at shutdown, so a process that
    /// ends without a clean session teardown still leaves the machine's
    /// displays as it found them. One attempt per display;
    /// `restoreEverythingRetrying(policy:)` is what spaces several out.
    func restoreEverything()
    /// Every display this controller changed and has not yet put back:
    /// what a retry has left to do, and what must be empty before the
    /// process may consider the machine's displays left as it found them.
    var displaysAwaitingRestore: [UInt32] { get }
}

/// How hard a restore that did not take is tried again.
///
/// A display refusing a mode change is often a display still settling from
/// the change a moment earlier rather than one that will refuse forever, so
/// a single refusal is not an answer. Bounded on purpose: this runs while a
/// session is ending or a process is quitting, and neither may be held open
/// indefinitely by a display that will never take the mode back.
public struct HostScreenModeRestorePolicy: Sendable {
    /// Attempts in total, the first one included.
    public let attempts: Int
    /// How long to wait between two of them.
    public let delaySeconds: Double

    public init(attempts: Int, delaySeconds: Double) {
        self.attempts = max(attempts, 1)
        self.delaySeconds = max(delaySeconds, 0)
    }

    /// Five attempts about a second apart: long enough to outlast a display
    /// reconfiguring, short enough that nobody waits on it.
    public static let standard = HostScreenModeRestorePolicy(attempts: 5, delaySeconds: 1)
}

public extension HostScreenModeControlling {
    /// Puts every display this controller changed back, trying again for any
    /// that will not take it at once. Used where there is no later attempt
    /// to fall back on: the host quitting.
    func restoreEverythingRetrying(policy: HostScreenModeRestorePolicy = .standard) async {
        for attempt in 1...policy.attempts {
            restoreEverything()
            if displaysAwaitingRestore.isEmpty {
                return
            }
            if attempt < policy.attempts {
                try? await Task.sleep(for: .seconds(policy.delaySeconds))
            }
        }
    }
}

/// How a display mode is named and ordered, with no display involved -- the
/// part of `CoreGraphicsHostScreenModeController` that can be verified
/// without reconfiguring anything.
public enum HostScreenModePresentation {
    /// A mode's own identifier: its real pixels, the points it lays out in,
    /// and its refresh rate. Composed from what the mode already is, so the
    /// same mode is named the same way every time it is listed, and two
    /// genuinely different modes of one display never collide.
    public static func entry(
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double
    ) -> HostScreenModeEntry {
        HostScreenModeEntry(
            modeID: "\(pixelWidth)x\(pixelHeight)@\(width)x\(height)@\(Int(refreshRate.rounded()))",
            width: width,
            height: height,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshRate: refreshRate,
            isHiDPI: pixelWidth > width
        )
    }

    /// Biggest first, by real pixels and then by points, so the sharpest
    /// mode heads the list and a "looks like" mode sits next to the mode it
    /// is drawn at.
    public static func sorted(_ entries: [HostScreenModeEntry]) -> [HostScreenModeEntry] {
        entries.sorted { left, right in
            let leftPixels = left.pixelWidth * left.pixelHeight
            let rightPixels = right.pixelWidth * right.pixelHeight
            if leftPixels != rightPixels {
                return leftPixels > rightPixels
            }
            if left.width != right.width {
                return left.width > right.width
            }
            return left.refreshRate > right.refreshRate
        }
    }

    /// Collapses macOS's one-mode-per-refresh-rate-and-pixel-encoding
    /// duplicates -- what `kCGDisplayShowDuplicateLowResolutionModes`
    /// actually returns for a high-refresh, HiDPI-capable display -- down to
    /// one entry per logical size a person would recognize as one choice:
    /// the same `width`, `height`, and `isHiDPI`.
    ///
    /// Within a group, the entry offered is the one at the display's own
    /// current refresh rate if the group has one, else the group's highest
    /// refresh rate; a further tie at one refresh rate is broken by
    /// preferring the entry whose real pixels equal the display's native
    /// pixel size over one resampled from a different pixel count. The
    /// entry named by `currentModeID` always survives for its own group,
    /// whatever the rules above would otherwise have picked, so a mode list
    /// can never omit the mode the display is already on.
    public static func collapsed(
        _ entries: [HostScreenModeEntry],
        currentModeID: String?,
        nativePixelWidth: Int,
        nativePixelHeight: Int
    ) -> [HostScreenModeEntry] {
        struct Key: Hashable {
            let width: Int
            let height: Int
            let isHiDPI: Bool
        }
        func key(for entry: HostScreenModeEntry) -> Key {
            Key(width: entry.width, height: entry.height, isHiDPI: entry.isHiDPI)
        }
        let current = entries.first { $0.modeID == currentModeID }
        let currentRate = current?.refreshRate

        func isPreferred(_ candidate: HostScreenModeEntry, over existing: HostScreenModeEntry) -> Bool {
            let candidateMatchesRate = currentRate.map { candidate.refreshRate == $0 } ?? false
            let existingMatchesRate = currentRate.map { existing.refreshRate == $0 } ?? false
            if candidateMatchesRate != existingMatchesRate {
                return candidateMatchesRate
            }
            if candidate.refreshRate != existing.refreshRate {
                return candidate.refreshRate > existing.refreshRate
            }
            let candidateIsNative = candidate.pixelWidth == nativePixelWidth && candidate.pixelHeight == nativePixelHeight
            let existingIsNative = existing.pixelWidth == nativePixelWidth && existing.pixelHeight == nativePixelHeight
            return candidateIsNative && !existingIsNative
        }

        var byKey: [Key: HostScreenModeEntry] = [:]
        for entry in entries {
            let entryKey = key(for: entry)
            if let existing = byKey[entryKey], !isPreferred(entry, over: existing) {
                continue
            }
            byKey[entryKey] = entry
        }
        if let current {
            byKey[key(for: current)] = current
        }

        return byKey.values.sorted { left, right in
            if left.isHiDPI != right.isHiDPI {
                return left.isHiDPI && !right.isHiDPI
            }
            if left.width != right.width {
                return left.width > right.width
            }
            return left.height > right.height
        }
    }
}
