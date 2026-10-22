import Foundation

/// The release this build is, and where its own documentation lives.
public enum ViewerRelease {
    /// Kept equal to the repository's `VERSION` file by a runner test; the
    /// Linux binary has no bundle to read a version from at run time.
    public static let version = "0.5.4"

    public static let repositoryURL = "https://github.com/blutarche/sensorium"

    /// The install guide's steps for hardware video decoding on Fedora, at
    /// this release's own tag.
    public static let fasterVideoGuide =
        "\(repositoryURL)/blob/v\(version)/docs/install.md#faster-video-on-fedora"

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
