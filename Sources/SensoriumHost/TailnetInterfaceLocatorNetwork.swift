#if os(macOS)
import Foundation
import Network

extension TailnetInterfaceLocator {
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
#endif
