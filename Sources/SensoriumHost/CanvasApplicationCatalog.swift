import Foundation

/// One application a remote user can start on the session canvas.
///
/// Named from the bundle rather than from `NSWorkspace`, so building a catalog
/// costs one directory listing and no per-bundle Launch Services round trip:
/// the list is rebuilt on a canvas the user is watching over a video link.
public struct LaunchableApplication: Equatable, Hashable, Sendable {
    public let name: String
    public let bundleURL: URL

    public init(name: String, bundleURL: URL) {
        self.name = name
        self.bundleURL = bundleURL
    }

    public init(bundleURL: URL) {
        self.init(name: bundleURL.deletingPathExtension().lastPathComponent, bundleURL: bundleURL)
    }
}

/// Every decision here is pure, driven through the `list` seam, so discovery
/// is assertable without reading a real disk.
public enum CanvasApplicationCatalog {
    /// One nested level below each root, and never inside a bundle. Deep enough
    /// for the `/Applications/<vendor>/<app>.app` layout installers use, shallow
    /// enough that a launcher opening on a canvas cannot walk the whole disk.
    private static let nestedDepth = 1

    /// The directories macOS installs applications into. `homeDirectory` is a
    /// parameter rather than a constant so this is the same function in a test
    /// as it is in the product.
    public static func defaultSearchRoots(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    /// Lists one directory. The only part of discovery that touches the disk.
    ///
    /// `.skipsHiddenFiles` is not used here: it honours the BSD hidden flag,
    /// not just a dot-prefixed name, and on current macOS an installed
    /// application can be a symlink carrying that flag rather than a
    /// dot-prefixed name -- `/Applications/Safari.app` is exactly this, a
    /// symlink into the Safari cryptex. Filtering by name instead keeps a
    /// dotfile out without also hiding a flagged application symlink.
    public static func systemListing(_ directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        )) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    public static func discover(
        roots: [URL],
        list: (URL) -> [URL],
        isBackgroundOnly: (URL) -> Bool = isBackgroundOnlyBundle
    ) -> [LaunchableApplication] {
        var applications: [String: LaunchableApplication] = [:]
        var visited: Set<String> = []

        func walk(_ directory: URL, depth: Int) {
            guard visited.insert(directory.path).inserted else {
                return
            }
            for entry in list(directory) {
                if entry.pathExtension == "app" {
                    // Bundled helper applications are an implementation detail
                    // of the app that ships them, not something a remote user
                    // picked from a list, so the walk stops at the bundle.
                    // A bundle that declares itself LSUIElement or
                    // LSBackgroundOnly is the same kind of implementation
                    // detail one level up -- a helper with no Dock presence
                    // of its own -- so it is skipped the same way.
                    guard !isBackgroundOnly(entry) else {
                        continue
                    }
                    applications[entry.path] = LaunchableApplication(bundleURL: entry)
                } else if depth < nestedDepth {
                    walk(entry, depth: depth + 1)
                }
            }
        }

        for root in roots {
            walk(root, depth: 0)
        }
        return applications.values.sorted(by: precedes)
    }

    /// Reads the bundle's own `Info.plist` and reports whether it declares
    /// `LSUIElement` or `LSBackgroundOnly` true -- Apple's own markers for an
    /// application with no Dock icon and no place in an app switcher, never
    /// something a remote user picked off a list of real applications. A
    /// bundle this cannot read is assumed to be an ordinary application: a
    /// missing or unreadable `Info.plist` is never grounds to hide a real one.
    public static func isBackgroundOnlyBundle(_ bundleURL: URL) -> Bool {
        guard let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) else {
            return false
        }
        return (plist["LSUIElement"] as? Bool) == true || (plist["LSBackgroundOnly"] as? Bool) == true
    }

    /// Ranks a typed query. A prefix match comes first because that is what a
    /// remote user typing three letters and pressing Return means; a substring
    /// match still appears, because the name they remember is often in the
    /// middle ("monitor").
    public static func filter(_ applications: [LaunchableApplication], query: String) -> [LaunchableApplication] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return applications
        }
        var prefixed: [LaunchableApplication] = []
        var contained: [LaunchableApplication] = []
        for application in applications {
            if application.name.range(of: trimmed, options: [.caseInsensitive, .anchored]) != nil {
                prefixed.append(application)
            } else if application.name.range(of: trimmed, options: .caseInsensitive) != nil {
                contained.append(application)
            }
        }
        return prefixed.sorted(by: precedes) + contained.sorted(by: precedes)
    }

    /// Name first, then path: two applications of the same name in different
    /// directories are both real and both offered, in a stable order.
    private static func precedes(_ lhs: LaunchableApplication, _ rhs: LaunchableApplication) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.bundleURL.path < rhs.bundleURL.path
    }
}

/// Where the arrow keys move in the launcher list.
public enum CanvasApplicationSelection {
    /// Clamped rather than wrapped. A remote user cannot see the list respond
    /// until a frame arrives, so a held arrow key that wraps around lands them
    /// somewhere they did not intend; a clamped one lands at an end they can
    /// predict from what they last saw.
    public static func move(from current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        return min(max(current + delta, 0), count - 1)
    }
}
