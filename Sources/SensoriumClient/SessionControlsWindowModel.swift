import Foundation
import SensoriumCore

/// What choosing one of the session window's menu items asks for. Each case
/// is exactly one of the calls the viewer's controller already listens on, so
/// the menu decides nothing beyond which item was chosen.
public enum SessionControlsActivation: Equatable, Sendable {
    case selectRealScreen(Data?)
    case selectHostScreenMode(String)
    case selectStartTarget(StartTarget)
    case selectDisplayCount(Int)
    /// `nil` is Automatic: no cap at all. Unlike the others this one is the
    /// viewer's own business rather than the host's, so it lands on the
    /// viewport rather than on the wire.
    case setStreamScale(Double?)
    case setClipboardSharing(Bool)
}

/// The session window's menu choices, as data: the same plans the macOS
/// menu bar reads -- `ScreenMenuPlan`, `DisplayCountMenuPlan`,
/// `DisplayScaleMenuPlan` -- and the state they read from. Holds no widget,
/// so what the menus offer is verified without a toolkit.
public struct SessionControlsWindowModel: Equatable, Sendable {
    public var hostScreens: [HostScreenListEntry] = []
    public var selectedScreenToken: Data?
    /// Whether the host opens a session canvas; `false` hides every
    /// Virtual display row.
    public var canvasAvailable = true
    public var hostScreenModes: [HostScreenModeEntry] = []
    public var currentHostScreenModeID: String?
    public var isHostScreenSession = false
    public var startTargetPreference: StartTarget = .hostScreenWhenOffered
    public var displayCount = 1
    public var clipboardSharingEnabled = ClipboardSyncEngine.sharingEnabledByDefault
    public var streamScalePreference: StreamScalePreference = .automatic
    public var canvasLogicalWidth = Double(SavedHost.remoteCanvasPreset.logicalWidth)
    public var canvasLogicalHeight = Double(SavedHost.remoteCanvasPreset.logicalHeight)
    /// `DisplayScaleMenuPlan.clampNotice`'s line, or `nil` when there is
    /// nothing to explain.
    public var streamScaleClampNotice: String?

    public init() {}

    /// The menus' state, built the way `ClientCanvasWindowController` builds
    /// the state it hands the macOS menu bar.
    public func menuBarState(isPointerCaptured: Bool, isFullscreen: Bool) -> ViewerMenuBarState {
        ViewerMenuBarState(
            streamScale: DisplayScaleMenuState(
                items: DisplayScaleMenuPlan.items(
                    selectedPreference: streamScalePreference,
                    canvasLogicalWidth: canvasLogicalWidth,
                    canvasLogicalHeight: canvasLogicalHeight
                ),
                clampNotice: streamScaleClampNotice
            ),
            displayCount: DisplayCountMenuState(items: DisplayCountMenuPlan.items(
                selectedCount: displayCount,
                isEnabled: !isHostScreenSession
            )),
            screen: ScreenMenuState(
                items: ScreenMenuPlan.items(
                    displays: hostScreens, selectedToken: selectedScreenToken, canvasAvailable: canvasAvailable
                ),
                modes: ScreenMenuPlan.modeMenu(
                    modes: hostScreenModes,
                    currentModeID: currentHostScreenModeID,
                    isHostScreenSessionLive: isHostScreenSession
                ),
                startWith: ScreenMenuPlan.startWithMenu(
                    preference: startTargetPreference,
                    offeredHostScreens: hostScreens,
                    isHostScreenSessionLive: isHostScreenSession,
                    canvasAvailable: canvasAvailable
                )
            ),
            isPointerCaptured: isPointerCaptured,
            isClipboardSharingEnabled: clipboardSharingEnabled,
            isFullscreen: isFullscreen,
            canFullScreen: true
        )
    }
}
