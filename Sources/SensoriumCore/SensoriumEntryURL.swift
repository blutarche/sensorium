import Foundation

/// The intentionally narrow deep-link contract for opening a paired workstation.
/// It carries only a host selector; pairing, authentication, and the fixed control
/// port remain out of band so a URL can never weaken the transport policy.
public struct SensoriumEntryURL: Equatable, Sendable {
    public static let scheme = "sensorium"
    public static let action = "enter"

    public let host: String

    public init?(string: String) {
        guard let url = URL(string: string) else {
            return nil
        }
        self.init(url: url)
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.action,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }

        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              path.hasPrefix("/"),
              !path.hasSuffix("/") else {
            return nil
        }
        let pathComponents = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard pathComponents.count == 1,
              let rawHost = pathComponents.first,
              !rawHost.isEmpty,
              rawHost.unicodeScalars.allSatisfy(Self.isHostCharacter) else {
            return nil
        }
        host = String(rawHost)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        components.percentEncodedPath = "/\(host)"
        return components.url!
    }

    private static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 46, 48...57, 58, 65...90, 97...122: // - . 0-9 : A-Z a-z
            return true
        default:
            return false
        }
    }
}
