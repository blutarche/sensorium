import Foundation
import Network

/// Finds the network interface that owns a given tailnet address, using only
/// `getifaddrs` — no network call, no daemon query.
public enum TailnetInterfaceLocator {
    /// The BSD name (`utunN`) of the interface carrying `address`, or `nil`.
    public static func interfaceName(owningAddress address: String) -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return nil
        }
        defer { freeifaddrs(addresses) }
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
            if String(cString: host) == address {
                return String(cString: entry.pointee.ifa_name)
            }
        }
        return nil
    }

    public static func isAvailable(address: String) -> Bool {
        interfaceName(owningAddress: address) != nil
    }

    /// The `NWInterface` for that name, via a path monitor snapshot. `nil` when
    /// the interface exists but Network.framework has no path over it yet.
    public static func interface(owningAddress address: String) -> NWInterface? {
        guard let name = interfaceName(owningAddress: address) else {
            return nil
        }
        final class Box: @unchecked Sendable { var value: NWInterface? }
        let box = Box()
        let ready = DispatchSemaphore(value: 0)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            box.value = path.availableInterfaces.first { $0.name == name }
            ready.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.sensorium.interface-locator"))
        _ = ready.wait(timeout: .now() + 2)
        monitor.cancel()
        return box.value
    }
}
