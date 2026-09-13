import Darwin
import Foundation

/// What address to host on, decided without ever asking: local interface
/// state only, read with `getifaddrs` — no network call, no `tailscale`
/// CLI, no prompt. `TailnetInterfaceLocator` answers the opposite question,
/// which interface owns a known address; this enumerates every address
/// there is, so the app can choose the one to bind by itself.
public enum TailnetAddressEnumerator {
    /// What auto-detection decided. An empty list is the only case that
    /// does not pick an address, and is a named state for the caller to
    /// display rather than a crash or a guess.
    public enum AutoSelection: Equatable, Sendable {
        case single(String)
        case none
    }

    /// Tailscale not running looks the same as it having no address yet --
    /// both are `.none`.
    ///
    /// Several tailnet addresses is not a failure -- `HostNetworkListener`'s
    /// QUIC listener is scoped to the owning interface, not to this one
    /// address, so it already admits every other address on it. The first
    /// IPv4 candidate is preferred, since that is the address a person
    /// would recognize from Tailscale's own UI; with none, the first
    /// address of any family is named instead.
    public static func autoSelect(from addresses: [String] = localTailnetAddresses()) -> AutoSelection {
        guard !addresses.isEmpty else { return .none }
        if let firstIPv4 = addresses.first(where: isIPv4Address) {
            return .single(firstIPv4)
        }
        return .single(addresses[0])
    }

    private static func isIPv4Address(_ address: String) -> Bool {
        var buffer = in_addr()
        return inet_pton(AF_INET, address, &buffer) == 1
    }

    /// Every numeric address `getifaddrs` reports for an active interface,
    /// in interface order, exactly as `SourceAddressPolicy` would see it.
    public static func rawLocalAddresses() -> [String] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return []
        }
        defer { freeifaddrs(addresses) }

        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let rawAddress = entry.pointee.ifa_addr else { continue }
            let family = rawAddress.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let resolved = getnameinfo(
                rawAddress,
                socklen_t(rawAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard resolved == 0 else { continue }
            let length = host.firstIndex(of: 0) ?? host.count
            found.append(String(decoding: host[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return found
    }

    /// The subset a Sensorium listener may actually bind: `SourceAddressPolicy`'s
    /// own tailnet ranges, in first-seen order with duplicates removed. Empty
    /// when Tailscale is not running — the setup window names that itself
    /// rather than showing nothing with no explanation.
    public static func localTailnetAddresses(rawAddresses: [String] = rawLocalAddresses()) -> [String] {
        var seen = Set<String>()
        return rawAddresses.filter { SourceAddressPolicy.isTailnetSource($0) && seen.insert($0).inserted }
    }
}
