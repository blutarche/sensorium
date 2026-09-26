import Foundation
import SensoriumCore

/// What activating one row of the session controls window asks for. Each case
/// is exactly one of the calls the viewer's controller already listens on, so
/// the window decides nothing beyond which row was pressed.
public enum SessionControlsActivation: Equatable, Sendable {
    case selectRealScreen(Data?)
    case selectHostScreenMode(String)
    case selectStartTarget(StartTarget)
    case selectDisplayCount(Int)
    /// `nil` is Automatic: no cap at all. Unlike the others this one is the
    /// window's own business rather than the host's, so it lands on the
    /// viewport rather than on the wire.
    case setStreamScale(Double?)
    case setClipboardSharing(Bool)
}

/// One row: what it says, whether it is the current choice, whether it can be
/// picked, and what picking it asks for.
public struct SessionControlsRow: Equatable, Sendable {
    public let title: String
    public let isSelected: Bool
    public let isEnabled: Bool
    public let activation: SessionControlsActivation

    public init(
        title: String,
        isSelected: Bool,
        isEnabled: Bool,
        activation: SessionControlsActivation
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.activation = activation
    }
}

/// A titled group of rows. `note` is the one line explaining a state the rows
/// themselves cannot -- a picture held below the scale that was asked for --
/// and is never something a person can press.
public struct SessionControlsSection: Equatable, Sendable {
    public let title: String
    public let isEnabled: Bool
    public let rows: [SessionControlsRow]
    public let note: String?

    public init(title: String, isEnabled: Bool, rows: [SessionControlsRow], note: String? = nil) {
        self.title = title
        self.isEnabled = isEnabled
        self.rows = rows
        self.note = note
    }
}

/// Everything the session controls window shows, as data.
///
/// On macOS these choices are menu-bar menus; a Wayland client has no menu
/// bar, so the same choices are one window. Either way the words, the
/// checkmarks and the disabled states are decided by the plans the viewer
/// already has -- `ScreenMenuPlan`, `DisplayCountMenuPlan`,
/// `DisplayScaleMenuPlan`, `ClipboardSharingToggle` -- and this only puts
/// them in one list. Holds no widget, so what the window offers is verified
/// without a toolkit, the same split `YourMachinesWindowModel` already keeps.
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

    public var sections: [SessionControlsSection] {
        let modes = ScreenMenuPlan.modeMenu(
            modes: hostScreenModes,
            currentModeID: currentHostScreenModeID,
            isHostScreenSessionLive: isHostScreenSession
        )
        let startWith = ScreenMenuPlan.startWithMenu(
            preference: startTargetPreference,
            offeredHostScreens: hostScreens,
            isHostScreenSessionLive: isHostScreenSession,
            canvasAvailable: canvasAvailable
        )
        return [
            SessionControlsSection(
                title: "Screen",
                isEnabled: true,
                rows: ScreenMenuPlan.items(
                    displays: hostScreens, selectedToken: selectedScreenToken, canvasAvailable: canvasAvailable
                ).map {
                    SessionControlsRow(
                        title: $0.title,
                        isSelected: $0.isSelected,
                        isEnabled: true,
                        activation: .selectRealScreen($0.token)
                    )
                }
            ),
            SessionControlsSection(
                title: modes.title,
                isEnabled: modes.isEnabled,
                rows: modes.items.map {
                    SessionControlsRow(
                        title: $0.title,
                        isSelected: $0.isSelected,
                        isEnabled: modes.isEnabled,
                        activation: .selectHostScreenMode($0.modeID)
                    )
                }
            ),
            SessionControlsSection(
                title: startWith.title,
                isEnabled: true,
                rows: startWith.items.map {
                    SessionControlsRow(
                        title: $0.title,
                        isSelected: $0.isSelected,
                        isEnabled: $0.isEnabled,
                        activation: .selectStartTarget($0.target)
                    )
                }
            ),
            SessionControlsSection(
                title: "Displays",
                isEnabled: true,
                rows: DisplayCountMenuPlan.items(
                    selectedCount: displayCount,
                    isEnabled: !isHostScreenSession
                ).map {
                    SessionControlsRow(
                        title: $0.title,
                        isSelected: $0.isSelected,
                        isEnabled: $0.isEnabled,
                        activation: .selectDisplayCount($0.count)
                    )
                }
            ),
            SessionControlsSection(
                title: "Scale",
                isEnabled: true,
                rows: DisplayScaleMenuPlan.items(
                    selectedPreference: streamScalePreference,
                    canvasLogicalWidth: canvasLogicalWidth,
                    canvasLogicalHeight: canvasLogicalHeight
                ).map {
                    SessionControlsRow(
                        title: $0.title,
                        isSelected: $0.isSelected,
                        isEnabled: true,
                        activation: .setStreamScale($0.scale)
                    )
                },
                note: streamScaleClampNotice
            ),
            SessionControlsSection(
                title: "Clipboard",
                isEnabled: true,
                rows: [
                    SessionControlsRow(
                        title: SessionControlsWindowModel.clipboardRowTitle,
                        isSelected: clipboardSharingEnabled,
                        isEnabled: true,
                        activation: .setClipboardSharing(
                            ClipboardSharingToggle.nextValue(currentlyEnabled: clipboardSharingEnabled)
                        )
                    )
                ]
            )
        ]
    }

    /// The same words the macOS View menu's own checkbox item carries.
    public static let clipboardRowTitle = "Share Clipboard"
}
