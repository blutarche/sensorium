#if os(macOS)
import CoreGraphics
import Foundation
import SensoriumCore

/// The real thing, in public CoreGraphics only:
/// `CGDisplayCopyAllDisplayModes`, `CGDisplayCopyDisplayMode`, and a
/// `CGBeginDisplayConfiguration`/`CGConfigureDisplayWithDisplayMode`/
/// `CGCompleteDisplayConfiguration` transaction completed with
/// `.forSession`, never `.permanently`: the change lasts as long as this
/// login session at the very most, and this type puts it back long before
/// that.
///
/// Nothing in this repository's own verification runs any of it -- changing
/// a real display's mode is exactly what a test must never do -- so every
/// decision that can be made without a display (which modes are offered,
/// how one is named, what the entries say) is kept in
/// `HostScreenModePresentation`, which is verified on its own.
@MainActor
public final class CoreGraphicsHostScreenModeController: HostScreenModeControlling {
    /// The modes this controller has handed out, by display, so a
    /// `modeID` a viewer names can be resolved back to the exact
    /// `CGDisplayMode` object macOS gave -- never re-derived by matching
    /// numbers, which two modes of one display can genuinely share.
    private var offeredModes: [UInt32: [String: CGDisplayMode]] = [:]
    /// What each display was on before this process first changed it.
    private var originalModes: [UInt32: CGDisplayMode] = [:]

    public init() {}

    public func modes(for displayID: UInt32) -> [HostScreenModeEntry] {
        // The "looks like" modes a person actually wants on a 4K display
        // are duplicates of a lower resolution, and macOS omits them
        // unless asked.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let raw = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        var byIdentifier: [String: CGDisplayMode] = [:]
        var entries: [HostScreenModeEntry] = []
        for mode in raw where mode.isUsableForDesktopGUI() {
            let entry = Self.entry(for: mode)
            guard byIdentifier[entry.modeID] == nil else {
                continue
            }
            byIdentifier[entry.modeID] = mode
            entries.append(entry)
        }
        let collapsed = HostScreenModePresentation.collapsed(
            entries,
            currentModeID: currentModeID(for: displayID),
            nativePixelWidth: CGDisplayPixelsWide(displayID),
            nativePixelHeight: CGDisplayPixelsHigh(displayID)
        )
        let keptIDs = Set(collapsed.map(\.modeID))
        offeredModes[displayID] = byIdentifier.filter { keptIDs.contains($0.key) }
        return collapsed
    }

    public func currentModeID(for displayID: UInt32) -> String? {
        CGDisplayCopyDisplayMode(displayID).map { Self.entry(for: $0).modeID }
    }

    public func apply(modeID: String, to displayID: UInt32) -> Bool {
        guard let mode = offeredModes[displayID]?[modeID] else {
            return false
        }
        let previous = CGDisplayCopyDisplayMode(displayID)
        guard Self.set(mode: mode, on: displayID) else {
            return false
        }
        if originalModes[displayID] == nil, let previous {
            originalModes[displayID] = previous
        }
        return true
    }

    /// Dropped only once the display is actually back: a refusal now is
    /// usually a display still reconfiguring.
    @discardableResult
    public func restore(displayID: UInt32) -> Bool {
        guard let original = originalModes[displayID] else {
            return false
        }
        guard Self.set(mode: original, on: displayID) else {
            return false
        }
        originalModes[displayID] = nil
        return true
    }

    public func restoreEverything() {
        for displayID in displaysAwaitingRestore {
            restore(displayID: displayID)
        }
    }

    public var displaysAwaitingRestore: [UInt32] { originalModes.keys.sorted() }

    /// One configuration transaction, cancelled rather than completed if
    /// the mode itself is refused: a half-built configuration left open
    /// would be this process holding a claim on the machine's displays
    /// with nothing to show for it.
    static func set(mode: CGDisplayMode, on displayID: UInt32) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            return false
        }
        guard CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        // `.forSession`, never `.permanently`.
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success
    }

    private static func entry(for mode: CGDisplayMode) -> HostScreenModeEntry {
        HostScreenModePresentation.entry(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate
        )
    }
}
#endif
