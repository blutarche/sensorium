import Foundation
import SensoriumCore

/// Whether this host accepts a viewer on its own local network, not only one
/// reaching it over the tailnet. Off unless the person at this machine turned
/// it on. Pairing, signatures and arming apply the same either way.
public struct HostLocalNetworkSetting: Codable, Equatable, Sendable {
    public var allowsLocalNetwork: Bool
    public init(allowsLocalNetwork: Bool = false) {
        self.allowsLocalNetwork = allowsLocalNetwork
    }
}

/// Where the setting is read and written, in this machine's own files only.
/// A missing file is a machine that never turned it on, and an unreadable one
/// reads as off too: off keeps the port on the tailnet alone, so it is the
/// safe way to be wrong.
public final class HostLocalNetworkSettingStore {
    private let url: URL
    private let log: (String) -> Void
    private var reportedUnreadableFile = false

    public init(url: URL, log: @escaping (String) -> Void = { print("Sensorium host: \($0)") }) {
        self.url = url
        self.log = log
    }

    public func load() -> HostLocalNetworkSetting {
        guard let data = try? Data(contentsOf: url) else {
            return HostLocalNetworkSetting()
        }
        guard let setting = try? JSONDecoder().decode(HostLocalNetworkSetting.self, from: data) else {
            if !reportedUnreadableFile {
                reportedUnreadableFile = true
                log("the local network setting at \(url.path) could not be read. Treating it as off.")
            }
            return HostLocalNetworkSetting()
        }
        return setting
    }

    public func save(_ setting: HostLocalNetworkSetting) throws {
        let data = try JSONEncoder().encode(setting)
        try OwnerOnlyFileWrite.write(data, to: url)
    }
}

public struct HostLocalNetworkConnectionClaim: Equatable, Sendable {
    fileprivate let token: UInt64
}

/// Every live connection that did not come over the tailnet, so turning
/// "Allow connections from this network" off can end them. A connection the
/// listener accepted just before the setting went off may only register here
/// after; it is stopped at once instead of kept.
@MainActor
public final class HostLocalNetworkConnectionRegistry {
    public private(set) var allowsLocalNetwork: Bool
    private var stops: [UInt64: () -> Void] = [:]
    private var nextToken: UInt64 = 0

    public init(allowsLocalNetwork: Bool) {
        self.allowsLocalNetwork = allowsLocalNetwork
    }

    /// `nil` when the setting is off, after `stop` has already run.
    public func admit(stop: @escaping () -> Void) -> HostLocalNetworkConnectionClaim? {
        guard allowsLocalNetwork else {
            stop()
            return nil
        }
        nextToken += 1
        stops[nextToken] = stop
        return HostLocalNetworkConnectionClaim(token: nextToken)
    }

    public func release(_ claim: HostLocalNetworkConnectionClaim) {
        stops[claim.token] = nil
    }

    public func setAllowsLocalNetwork(_ allows: Bool) {
        allowsLocalNetwork = allows
        guard !allows else { return }
        let ending = stops
        stops = [:]
        for stop in ending.values {
            stop()
        }
    }
}
