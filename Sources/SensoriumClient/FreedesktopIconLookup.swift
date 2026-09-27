#if canImport(CCairo)
import Foundation

/// Finds the image file an icon name stands for, under the icon themes this
/// desktop installs.
///
/// The freedesktop icon naming specification says what an icon is *called*;
/// where the file lives is a matter of which themes are installed and at
/// which sizes. Every theme this viewer has found on a real box ships its
/// icons as SVG only, so this looks for an SVG and answers nothing when
/// there is none -- a button with a readable word on it is better than a
/// button with a blank square. Only a `-symbolic` name is ever looked up
/// here, so the search never has to tell a template glyph apart from an
/// application's own full-colour icon; restricting it to the directories a
/// theme keeps its symbolic glyphs in, rather than every directory the theme
/// has, is a second reason an app's own icon can never answer in its place.
@MainActor
public enum FreedesktopIconLookup {
    /// A KDE-style theme first -- Breeze's own dark variant is what a
    /// freshly installed desktop runs -- then Adwaita, which every one of
    /// these themes' own `index.theme` inherits from, so a glyph only
    /// Adwaita ships is still found.
    private static let themeDirectories = ["breeze-dark", "breeze", "Breeze", "Adwaita", "hicolor"]

    /// Every context a symbolic glyph -- never a full-colour application
    /// icon -- is filed under. Deliberately excludes `apps`: the one
    /// directory a random installed program's own icon lives in, so a
    /// button's own glyph name can never resolve to some other app's icon.
    private static let categoryDirectories = [
        "actions", "status", "emblems", "places", "categories", "devices", "ui", "legacy"
    ]
    /// A theme that keeps its symbolic glyphs at a fixed size per context
    /// directory rather than in one `symbolic` tree -- Breeze's own layout.
    private static let sizeDirectories = ["16", "22", "24", "32", "scalable"]
    private static let roots = ["/usr/share/icons", "/usr/local/share/icons"]

    private static var cache: [String: String?] = [:]

    /// Set by a test only, to answer every lookup as though no installed
    /// theme has the icon -- the state a headless box's own icon set cannot
    /// be relied on to reproduce, but a fallback-text test needs on demand.
    /// Checked before the cache, so flipping it never reads a result cached
    /// under the other setting.
    public static var forceNotFound = false

    /// The path of an SVG for `name`, or `nil` where no installed theme has
    /// a symbolic copy of it. `name` is expected to already end in
    /// `-symbolic`; nothing here appends or strips that suffix, so a caller
    /// asking for anything else is asking outside what this restricts itself
    /// to and simply finds nothing.
    public static func svgPath(named name: String) -> String? {
        if forceNotFound { return nil }
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
                for category in categoryDirectories {
                    // Adwaita's own layout: theme/symbolic/category/name.svg,
                    // one glyph at every size in the same file.
                    let symbolicPath = "\(root)/\(theme)/symbolic/\(category)/\(name).svg"
                    if manager.fileExists(atPath: symbolicPath) {
                        return symbolicPath
                    }
                    // Breeze's own layout: theme/category/size/name.svg.
                    for size in sizeDirectories {
                        let sizedPath = "\(root)/\(theme)/\(category)/\(size)/\(name).svg"
                        if manager.fileExists(atPath: sizedPath) {
                            return sizedPath
                        }
                    }
                }
            }
        }
        return nil
    }
}
#endif
