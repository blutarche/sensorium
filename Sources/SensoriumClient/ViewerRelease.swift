import Foundation
#if os(Linux)
import CWaylandGlue
#endif

/// The release this build is, and where its own documentation lives.
public enum ViewerRelease {
    public static let version: String = {
        #if os(Linux)
        String(cString: sensorium_build_version())
        #else
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        #endif
    }()

    public static let repositoryURL = "https://github.com/blutarche/sensorium"

    /// The install guide's steps for hardware video decoding on Fedora, at
    /// this release's own tag.
    public static let fasterVideoGuide =
        "\(repositoryURL)/blob/\(version == "development" ? "main" : "v" + version)/docs/install.md#faster-video-on-fedora"

    /// The guide the diagnostics panel links to when this machine decodes
    /// video on the CPU. `nil` on macOS, where VideoToolbox decodes in
    /// hardware and there is nothing for the person to install.
    public static var platformSoftwareDecodeGuide: String? {
        #if os(Linux)
        fasterVideoGuide
        #else
        nil
        #endif
    }
}
