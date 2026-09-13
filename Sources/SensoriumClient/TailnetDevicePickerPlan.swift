import Foundation
import SensoriumCore

/// One row the picker can show: a tailnet peer, and the title/subtitle a
/// person reads to tell it apart from the others. Pure formatting only --
/// which peers appear and in what order is `TailnetDirectory.presentationOrder`'s
/// decision, never reimplemented here.
public struct TailnetDevicePickerRow: Equatable, Sendable {
    public let peer: TailnetPeer
    public let title: String
    public let subtitle: String

    public init(peer: TailnetPeer) {
        self.peer = peer
        self.title = peer.displayName
        // The address a person would otherwise have had to type by hand --
        // named here so a device they do not recognise by name is still
        // identifiable, and reachable devices tell offline ones apart at a
        // glance without a second line of copy.
        let address = peer.magicDNSName ?? peer.tailnetIPv4 ?? peer.tailnetIPv6 ?? ""
        self.subtitle = peer.isOnline ? address : "\(address) \u{2014} offline"
    }
}

/// Everything the device-picker window can be showing, decided from a single
/// fetch attempt against `TailnetStatusProviding`. AppKit-free, so every
/// state -- including the ones a live tailnet is hard to coax into, like
/// "tailscaled is not running" -- is reachable and verified without a window
/// or a real socket.
public enum TailnetDevicePickerState: Equatable, Sendable {
    /// The fetch is in flight. Named rather than represented by an empty
    /// `rows`, so the view never has to guess whether nothing has loaded yet
    /// or the tailnet genuinely has nothing else on it.
    case loading
    /// `tailscaled` could not be asked, or its answer could not be read as a
    /// status document at all -- not "read fine and says nothing," which is
    /// `.noOtherDevices`. `reason` is already words a person can read; no
    /// system error text crosses this boundary unedited.
    case unreachable(reason: String)
    /// A real status document, parsed, with nothing left to show after this
    /// machine is excluded: an empty tailnet, or one where every tailnet peer
    /// is this machine.
    case noOtherDevices
    /// At least one other device, in `TailnetDirectory.presentationOrder`.
    case devices([TailnetDevicePickerRow])

    /// Whether the loading line's dot should pulse -- true only while the
    /// fetch is actually in flight, so a settled state (an answer, an empty
    /// tailnet, a failure) never keeps animating beside words that are no
    /// longer waiting on anything.
    public var showsActivityDot: Bool { self == .loading }

    public static func from(_ result: Result<TailnetDirectorySnapshot, TailnetDevicePickerFetchError>) -> TailnetDevicePickerState {
        switch result {
        case let .failure(error):
            return .unreachable(reason: error.reason)
        case let .success(snapshot):
            let ordered = TailnetDirectory.presentationOrder(snapshot.peers)
            return ordered.isEmpty ? .noOtherDevices : .devices(ordered.map(TailnetDevicePickerRow.init))
        }
    }
}

/// Every way asking `tailscaled` for its status can fail, in words the
/// picker can show directly -- never a system error's own text, which reads
/// like "POSIXErrorCode(rawValue: 2)" to a person choosing a machine to work on.
public enum TailnetDevicePickerFetchError: Error, Equatable, Sendable {
    /// `tailscaled`'s control surface answered, or could at least be asked,
    /// but did not give a usable status -- most commonly, Tailscale is
    /// installed but not running.
    case tailscaledUnreachable
    /// No path this machine was told to look for the `tailscale` command-line
    /// tool at exists (`LocalTailscaleStatusProviderError.tailscaleNotFound`)
    /// -- Tailscale is very likely not installed at all, not merely stopped.
    case tailscaleNotInstalled
    /// Something answered, but not with a status document this parser could
    /// read at all (`TailnetDirectoryError`), or the read itself failed.
    case malformedStatus

    public var reason: String {
        switch self {
        case .tailscaledUnreachable:
            return "Tailscale doesn\u{2019}t seem to be running on this machine. "
                + "Make sure Tailscale says Connected, then choose Look again."
        case .tailscaleNotInstalled:
            return "Tailscale doesn\u{2019}t seem to be installed on this machine. "
                + "Install Tailscale and sign in, then choose Look again."
        case .malformedStatus:
            return "Tailscale answered with something this app could not read. "
                + "Try again, or enter the other machine\u{2019}s address by hand."
        }
    }
}
