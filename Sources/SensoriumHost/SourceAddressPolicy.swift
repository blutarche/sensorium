import Darwin
import Foundation

/// Application-level half of the Tailscale-only ingress rule. The PF anchor is
/// the other half; neither is trusted alone.
public enum SourceAddressPolicy {
    /// Tailscale's CGNAT range, 100.64.0.0/10.
    private static let ipv4Prefix: (UInt8, ClosedRange<UInt8>) = (100, 64...127)

    /// Tailscale's ULA range, fd7a:115c:a1e0::/48.
    private static let ipv6Prefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]

    public static func isTailnetSource(_ address: String) -> Bool {
        let scopeless = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address

        var v4 = in_addr()
        if inet_pton(AF_INET, scopeless, &v4) == 1 {
            let octets = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return octets[0] == ipv4Prefix.0 && ipv4Prefix.1.contains(octets[1])
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, scopeless, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return Array(bytes.prefix(ipv6Prefix.count)) == ipv6Prefix
        }

        return false
    }
}

extension SourceAddressPolicy {
    /// Whether `address` is on the same subnet as one of `interfaces`. Only
    /// consulted while "Allow connections from this network" is on; a
    /// same-subnet rule rather than a list of private ranges, because a home
    /// network's IPv6 addresses are global ones.
    ///
    /// A link-local scope is dropped before comparing, so a link-local source
    /// matches any interface's link-local subnet, not only the one it arrived on.
    public static func isOnLinkSource(_ address: String, interfaces: [LocalSubnet]) -> Bool {
        guard let source = LocalSubnet.bytes(of: address) else {
            return false
        }
        return interfaces.contains { $0.contains(source) }
    }
}

/// One subnet this machine is directly attached to: an interface address and
/// its netmask, as raw network-order bytes, 4 for IPv4 and 16 for IPv6.
public struct LocalSubnet: Equatable, Sendable {
    public let address: [UInt8]
    public let mask: [UInt8]

    public init?(address: [UInt8], mask: [UInt8]) {
        guard address.count == mask.count, address.count == 4 || address.count == 16 else {
            return nil
        }
        self.address = Self.withoutEmbeddedScope(address)
        self.mask = mask
    }

    public init?(address: String, netmask: String) {
        guard let addressBytes = Self.bytes(of: address), let maskBytes = Self.bytes(of: netmask) else {
            return nil
        }
        self.init(address: addressBytes, mask: maskBytes)
    }

    func contains(_ source: [UInt8]) -> Bool {
        guard source.count == address.count else {
            return false
        }
        return zip(zip(source, address), mask).allSatisfy { pair, mask in
            pair.0 & mask == pair.1 & mask
        }
    }

    static func bytes(of address: String) -> [UInt8]? {
        let scopeless = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, scopeless, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, scopeless, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    /// The kernel reports a link-local address with its interface index
    /// written into bytes 2 and 3 (fe80:4::...). A parsed source never
    /// carries it there, so it is cleared before any comparison.
    private static func withoutEmbeddedScope(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count == 16, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 else {
            return bytes
        }
        var cleared = bytes
        cleared[2] = 0
        cleared[3] = 0
        return cleared
    }
}

/// The subnets of every active interface on this machine, except loopback and
/// any interface carrying a tailnet address, read with `getifaddrs` only.
public enum LocalSubnetEnumerator {
    public static func current() -> [LocalSubnet] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return []
        }
        defer { freeifaddrs(addresses) }

        var entries: [(name: String, flags: UInt32, address: [UInt8], mask: [UInt8])] = []
        var tailnetInterfaces = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let rawAddress = entry.pointee.ifa_addr,
                  let rawMask = entry.pointee.ifa_netmask,
                  let address = rawBytes(rawAddress, family: rawAddress.pointee.sa_family),
                  let mask = rawBytes(rawMask, family: rawAddress.pointee.sa_family) else {
                continue
            }
            let name = String(cString: entry.pointee.ifa_name)
            if isTailnet(address) {
                tailnetInterfaces.insert(name)
            }
            entries.append((name, entry.pointee.ifa_flags, address, mask))
        }

        return entries.compactMap { entry in
            guard entry.flags & UInt32(IFF_UP) != 0,
                  entry.flags & UInt32(IFF_LOOPBACK) == 0,
                  !tailnetInterfaces.contains(entry.name) else {
                return nil
            }
            return LocalSubnet(address: entry.address, mask: entry.mask)
        }
    }

    private static func isTailnet(_ bytes: [UInt8]) -> Bool {
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let printed = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &text, socklen_t(text.count))
        }
        guard printed != nil else { return false }
        return SourceAddressPolicy.isTailnetSource(String(cString: text))
    }

    /// Read from the socket address itself rather than through
    /// `getnameinfo`: a netmask's `sa_len` is often shorter than its family's
    /// structure and is not a valid input there. Missing trailing bytes are
    /// zero.
    private static func rawBytes(_ socketAddress: UnsafePointer<sockaddr>, family: sa_family_t) -> [UInt8]? {
        let offset: Int
        let count: Int
        switch Int32(family) {
        case AF_INET:
            offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!
            count = 4
        case AF_INET6:
            offset = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!
            count = 16
        default:
            return nil
        }
        let available = max(0, Int(socketAddress.pointee.sa_len) - offset)
        let raw = UnsafeRawPointer(socketAddress)
        return (0..<count).map { index in
            index < available ? raw.load(fromByteOffset: offset + index, as: UInt8.self) : 0
        }
    }
}
