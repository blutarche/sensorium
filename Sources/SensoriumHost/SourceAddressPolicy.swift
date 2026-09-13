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
