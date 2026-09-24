#if canImport(CCairo)
import Foundation

/// Finds the image file an icon name stands for, under the icon themes this
/// desktop installs.
///
/// The freedesktop icon naming specification says what an icon is *called*;
/// where the file lives is a matter of which themes are installed and at
/// which sizes. This looks in the usual places for a raster copy and answers
/// nothing when there is none. Scalable copies are deliberately not
/// considered: rendering SVG needs a library this viewer does not depend on,
/// and a button with a readable word on it is better than a button with a
/// blank square.
@MainActor
enum FreedesktopIconLookup {
    private static let themeDirectories = ["Breeze", "breeze", "Adwaita", "hicolor", "gnome"]
    /// Biggest first, so a button drawn at any scale has the most pixels the
    /// theme offers rather than the fewest.
    private static let sizeDirectories = ["32x32", "24x24", "22x22", "16x16"]
    private static let categoryDirectories = ["actions", "apps", "places", "status", "categories", "devices"]
    private static let roots = ["/usr/share/icons", "/usr/local/share/icons"]

    private static var cache: [String: String?] = [:]

    /// The path of a PNG for `name`, or `nil` where no installed theme has a
    /// raster copy of it.
    static func pngPath(named name: String) -> String? {
        if let remembered = cache[name] {
            return remembered
        }
        let found = search(name)
        cache[name] = found
        return found
    }

    private static func search(_ name: String) -> String? {
        let manager = FileManager.default
        for root in roots {
            for theme in themeDirectories {
                for size in sizeDirectories {
                    for category in categoryDirectories {
                        let path = "\(root)/\(theme)/\(size)/\(category)/\(name).png"
                        if manager.fileExists(atPath: path) {
                            return path
                        }
                    }
                }
            }
        }
        return nil
    }
}
#endif
