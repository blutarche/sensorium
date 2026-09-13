import Foundation
import SensoriumCore

/// What one row of the launch window is doing. A row is idle until the person
/// clicks it, and goes back to idle the moment the attempt it started is over,
/// whichever way it ended.
public enum YourMachinesRowActivity: Equatable, Sendable {
    case idle
    case connecting
    /// One attempt ended without a session, with the reason already turned
    /// into words by `ViewerSessionFailureCopy` before it got here -- this
    /// type holds no wire vocabulary of its own, the same discipline
    /// `ViewerSessionStateMachine` follows for the overlay's own lines. The
    /// retry policy is still running, so the row keeps its Cancel.
    case failed(attempt: Int, reason: String)
    /// The whole run of attempts is over and none of them connected. Says
    /// exactly what the last failure said -- the moment the waiting stops is
    /// when that reason matters most -- but offers no Cancel, because
    /// clicking the row is now what tries again.
    case stopped(attempt: Int, reason: String)
    /// Cancelled, but not over yet: a handshake already out has to finish
    /// before the row is free. Said rather than left blank, because a row
    /// that went quiet the moment Cancel was pressed and then twitched again
    /// a few seconds later is the confusing part.
    case stopping
}

/// One saved machine, as the launch window draws it: the name, and one line under
/// it that is either where that machine is or what the attempt to reach it is
/// doing.
public struct YourMachinesRow: Equatable, Sendable {
    public let hostPublicKey: Data
    public let name: String
    public let address: String
    /// What `tailscale status` said about this machine, or `nil` where it said
    /// nothing about it at all -- a machine the tailnet does not mention is
    /// unknown, never offline.
    public let isOnline: Bool?
    public let activity: YourMachinesRowActivity
    /// True only while `activity` is a failed or stopped attempt that was
    /// trying a host screen this saved machine's own "Start with"
    /// preference named -- nothing here is automatic beyond that:
    /// the row's own "\u{2026}" menu offers the one explicit way out,
    /// "Connect with a virtual display", the same title and action
    /// `ViewerSessionAction.connectAsVirtualDisplay` already carries for
    /// the live session panel's own button. `false` for every other
    /// failure, and reset to `false` the moment a fresh attempt starts.
    public let offersConnectAsVirtualDisplayFallback: Bool

    /// The one line under the name. A connecting or stopping attempt keeps
    /// the address and appends what it is doing, since knowing which machine
    /// is being dialled matters as much while it is happening as before or
    /// after -- `dot` carries a pulsing marker alongside it rather than
    /// replacing the words a second time. A failed or stopped attempt also
    /// keeps the address and appends a short reason -- the full explanation
    /// belongs to the status panel, not this row. A long reason wraps, and
    /// the row grows with it rather than truncating what went wrong.
    public var detail: String {
        switch activity {
        case .idle:
            switch isOnline {
            case .none:
                return address
            case .some(true):
                return "\(address) \u{2014} online"
            case .some(false):
                return "\(address) \u{2014} offline"
            }
        case .connecting:
            return "\(address) \u{2014} connecting\u{2026}"
        case .stopping:
            return "\(address) \u{2014} stopping\u{2026}"
        case let .failed(_, reason), let .stopped(_, reason):
            return "\(address) \u{2014} \(reason)"
        }
    }

    /// The dot beside the detail line, or none where nothing is worth
    /// marking. Idle reads `isOnline` the same way `detail` does --
    /// unknown reachability draws no dot, the same restraint that keeps an
    /// unmentioned machine from being called offline. A connecting or
    /// stopping attempt draws the one dot that pulses, in place of the
    /// words this line no longer needs to carry alone. A failed or stopped
    /// attempt draws none: its own line already says everything.
    public enum RowDot: Equatable, Sendable {
        case online
        case offline
        case activity
    }

    public var dot: RowDot? {
        switch activity {
        case .idle:
            switch isOnline {
            case .none: return nil
            case .some(true): return .online
            case .some(false): return .offline
            }
        case .connecting, .stopping:
            return .activity
        case .failed, .stopped:
            return nil
        }
    }

    /// Only a row with an attempt still out has anything to stop.
    public var offersCancel: Bool {
        switch activity {
        case .connecting, .failed: return true
        case .idle, .stopped, .stopping: return false
        }
    }
}

/// What clicking a row means, decided before anything is dialled.
public enum YourMachinesClickOutcome: Equatable, Sendable {
    case connect(hostPublicKey: Data)
    /// Another machine was clicked while one was already dialling. Every row
    /// stays live during an attempt, and a second attempt beside the first
    /// would leave two dials out with one window, so the one already out
    /// ends first.
    case cancelThenConnect(cancelling: Data, connecting: Data)
    /// The row already dialling. Its own Cancel is how that attempt stops;
    /// clicking the row again is not a second connect.
    case ignore
}

/// Everything the launch window shows, with no window and no socket: which
/// machines are listed, what each row's line says, and what clicking one means.
/// The window holds rows and buttons; every decision is here, so the whole
/// list -- including states a real dial is hard to hold still, like an
/// attempt that has failed but not yet been retried -- is verified without
/// AppKit.
public struct YourMachinesWindowModel: Equatable, Sendable {
    public static let heading = "Your Machines"
    /// An empty state says what is empty; the button beside it says what to
    /// do about it, so this sentence does not have to.
    public static let emptySentence = "No machine is paired with this one yet."
    public static let addTitle = "Add a machine"

    public private(set) var rows: [YourMachinesRow]
    /// The machine currently being dialled, or `nil` when nothing is.
    public private(set) var connectingHostPublicKey: Data?
    /// Attempts since this row started dialling. Reset whenever the wait it
    /// counts is over.
    private var attempt = 0

    public var isEmpty: Bool { rows.isEmpty }
    /// With nothing paired, adding a machine is the only thing on the window that
    /// does anything, so it takes the accent. With machines listed, connecting to
    /// one is the point and this steps back.
    public var addIsPrimary: Bool { isEmpty }

    /// `hosts` in the order the store handed them over -- `SavedHostList.presentationOrder`,
    /// never re-sorted here. `reachability` is what `tailscale status` said,
    /// by pinned key; a machine it does not mention is simply absent from it.
    public init(hosts: [SavedHost], reachability: [Data: Bool] = [:]) {
        rows = hosts.map { host in
            YourMachinesRow(
                hostPublicKey: host.hostPublicKey,
                name: host.displayName,
                address: host.host,
                isOnline: reachability[host.hostPublicKey],
                activity: .idle,
                offersConnectAsVirtualDisplayFallback: false
            )
        }
    }

    /// The saved machines, read again -- after one was forgotten, after a new one
    /// was paired, or after `tailscale status` finally answered. An attempt
    /// already out is not a property of the store and must survive this: the
    /// row that was dialling keeps saying so, with its own attempt count. An
    /// attempt on a machine that is no longer in the list has no row left to be
    /// reported on, so it stops being tracked here.
    public mutating func replaceHosts(_ hosts: [SavedHost], reachability: [Data: Bool]) {
        let previous = Dictionary(
            rows.map { ($0.hostPublicKey, ($0.activity, $0.offersConnectAsVirtualDisplayFallback)) },
            uniquingKeysWith: { first, _ in first }
        )
        rows = hosts.map { host in
            YourMachinesRow(
                hostPublicKey: host.hostPublicKey,
                name: host.displayName,
                address: host.host,
                isOnline: reachability[host.hostPublicKey],
                activity: previous[host.hostPublicKey]?.0 ?? .idle,
                offersConnectAsVirtualDisplayFallback: previous[host.hostPublicKey]?.1 ?? false
            )
        }
        if let connecting = connectingHostPublicKey, !hosts.contains(where: { $0.hostPublicKey == connecting }) {
            connectingHostPublicKey = nil
            attempt = 0
        }
    }

    public func outcome(ofClickOn hostPublicKey: Data) -> YourMachinesClickOutcome {
        guard let connectingHostPublicKey else {
            return .connect(hostPublicKey: hostPublicKey)
        }
        if connectingHostPublicKey == hostPublicKey {
            return .ignore
        }
        return .cancelThenConnect(cancelling: connectingHostPublicKey, connecting: hostPublicKey)
    }

    /// The person clicked this machine. Nothing has been dialled yet -- that is
    /// `connectStarted(hostPublicKey:)`, once per attempt -- but the row says
    /// so from the click, not from whenever a socket gets around to opening.
    public mutating func connectRequested(hostPublicKey: Data) {
        connectingHostPublicKey = hostPublicKey
        attempt = 0
        setActivity(.connecting, on: hostPublicKey)
    }

    /// One attempt is starting. Called for every attempt the retry loop
    /// makes, not once per session, so the count the row shows is the count
    /// that has actually been tried.
    public mutating func connectStarted(hostPublicKey: Data) {
        if connectingHostPublicKey != hostPublicKey {
            attempt = 0
        }
        connectingHostPublicKey = hostPublicKey
        attempt += 1
        setActivity(.connecting, on: hostPublicKey)
    }

    /// One attempt ended without a session. The reason arrives already in
    /// words; nothing here reads a wire value. `offersConnectAsVirtualDisplayFallback`
    /// is the caller's own say on whether this failure was trying a host
    /// screen a saved preference named, not a fact this type could read back
    /// out of `reason`.
    public mutating func attemptFailed(reason: String, offersConnectAsVirtualDisplayFallback: Bool = false) {
        guard let connectingHostPublicKey else { return }
        setActivity(
            .failed(attempt: attempt, reason: reason), on: connectingHostPublicKey,
            offersConnectAsVirtualDisplayFallback: offersConnectAsVirtualDisplayFallback
        )
    }

    /// The attempt on this machine is over. Ignored once another machine's attempt has
    /// taken the row's place, because that one is still running.
    public mutating func stoppedConnecting(hostPublicKey: Data) {
        guard connectingHostPublicKey == hostPublicKey else { return }
        stoppedConnecting()
    }

    /// The attempt is over -- cancelled, given up on, or replaced by another
    /// machine's -- and the row goes back to saying where that machine is.
    public mutating func stoppedConnecting() {
        guard let connectingHostPublicKey else { return }
        setActivity(.idle, on: connectingHostPublicKey)
        self.connectingHostPublicKey = nil
        attempt = 0
    }

    /// Cancelled. The attempt is still this row's until it has finished
    /// unwinding, and `stoppedConnecting()` is what frees it. The fallback
    /// flag rides along unchanged: a failed attempt's own offer to switch to
    /// a virtual display is not withdrawn just because Cancel was pressed on
    /// top of it.
    public mutating func stopping() {
        guard let connectingHostPublicKey else { return }
        let carried = rows.first { $0.hostPublicKey == connectingHostPublicKey }?
            .offersConnectAsVirtualDisplayFallback ?? false
        setActivity(.stopping, on: connectingHostPublicKey, offersConnectAsVirtualDisplayFallback: carried)
    }

    /// Every attempt is spent, or the person stopped the wait. Whatever the
    /// last attempt reported stays on the row, and the row is clickable
    /// again -- unlike `stoppedConnecting()`, which is for an attempt
    /// abandoned in favour of something else and leaves nothing to read.
    public mutating func stoppedTrying() {
        guard let connectingHostPublicKey else { return }
        if let index = rows.firstIndex(where: { $0.hostPublicKey == connectingHostPublicKey }) {
            switch rows[index].activity {
            case let .failed(attempt, reason):
                setActivity(
                    .stopped(attempt: attempt, reason: reason), on: connectingHostPublicKey,
                    offersConnectAsVirtualDisplayFallback: rows[index].offersConnectAsVirtualDisplayFallback
                )
            case .connecting, .idle, .stopped, .stopping:
                setActivity(.idle, on: connectingHostPublicKey)
            }
        }
        self.connectingHostPublicKey = nil
        attempt = 0
    }

    private mutating func setActivity(
        _ activity: YourMachinesRowActivity, on hostPublicKey: Data,
        offersConnectAsVirtualDisplayFallback: Bool = false
    ) {
        guard let index = rows.firstIndex(where: { $0.hostPublicKey == hostPublicKey }) else { return }
        rows[index] = YourMachinesRow(
            hostPublicKey: rows[index].hostPublicKey,
            name: rows[index].name,
            address: rows[index].address,
            isOnline: rows[index].isOnline,
            activity: activity,
            offersConnectAsVirtualDisplayFallback: offersConnectAsVirtualDisplayFallback
        )
    }
}

/// Which saved machines the tailnet currently answers for. A saved machine holds only
/// the address it was paired at, so it is matched against every name and
/// address a tailnet peer answers to; a machine no peer matches is left out entirely
/// rather than reported offline, since "not in this list" and "asleep" are
/// different facts and only one of them is known here.
public enum SavedMachineReachability {
    public static func byHostKey(hosts: [SavedHost], peers: [TailnetPeer]) -> [Data: Bool] {
        var result: [Data: Bool] = [:]
        for host in hosts {
            guard let peer = peers.first(where: { matches(host: host.host, peer: $0) }) else { continue }
            result[host.hostPublicKey] = peer.isOnline
        }
        return result
    }

    private static func matches(host: String, peer: TailnetPeer) -> Bool {
        let saved = normalized(host)
        guard !saved.isEmpty else { return false }
        return [peer.magicDNSName, peer.tailnetIPv4, peer.tailnetIPv6, peer.displayName]
            .compactMap { $0 }
            .contains { normalized($0) == saved }
    }

    /// Case-insensitive, and without the trailing dot a fully qualified
    /// MagicDNS name may carry -- the same name either way.
    private static func normalized(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
