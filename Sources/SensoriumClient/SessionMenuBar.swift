import Foundation

/// Where the session window's painted menu bar puts each menu's title.
public enum SessionMenuBarLayout {
    public struct Item: Equatable, Sendable {
        public let x: Double
        public let width: Double
    }

    private static let barPadding = Double(ViewerChromeMetrics.MenuBar.barPaddingX)
    private static let itemPadding = Double(ViewerChromeMetrics.MenuBar.itemPaddingX)

    /// One item per title, side by side from the bar's left edge, given each
    /// title's measured text width.
    public static func items(titleWidths: [Double]) -> [Item] {
        var x = barPadding
        return titleWidths.map { textWidth in
            let item = Item(x: x, width: textWidth + itemPadding * 2)
            x += item.width
            return item
        }
    }

    public static func item(atX x: Double, in items: [Item]) -> Int? {
        items.firstIndex { x >= $0.x && x < $0.x + $0.width }
    }
}

/// One open menu's rows, as it is painted, in the menu's own logical units.
public struct SessionMenuPopupLayout: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let y: Double
        public let height: Double
        public let isSeparator: Bool
    }

    public let rows: [Row]
    public let width: Double
    public let height: Double

    /// `titleWidths` and `chordWidths` are each row's measured text widths,
    /// zero for a separator or a row without a chord.
    public init(menu: ViewerMenu, titleWidths: [Double], chordWidths: [Double]) {
        typealias Metrics = ViewerChromeMetrics.MenuBar
        let padding = Double(Metrics.popupPaddingY)
        var y = padding
        var rows: [Row] = []
        for item in menu.items {
            let isSeparator = item.command == .separator
            let height = Double(isSeparator ? Metrics.separatorHeight : Metrics.rowHeight)
            rows.append(Row(y: y, height: height, isSeparator: isSeparator))
            y += height
        }
        self.rows = rows
        height = y + padding
        let widestChord = chordWidths.max() ?? 0
        let hasSubmenu = menu.items.contains { $0.submenu != nil }
        let content = Double(Metrics.rowPaddingX) * 2
            + Double(Metrics.checkColumnWidth)
            + (titleWidths.max() ?? 0)
            + (widestChord > 0 ? Double(Metrics.chordGap) + widestChord : 0)
            + (hasSubmenu ? Double(Metrics.submenuArrowWidth) : 0)
        width = max(content, Double(Metrics.minimumPopupWidth))
    }

    /// The item row under `y`; a separator is no row.
    public func row(atY y: Double) -> Int? {
        rows.firstIndex { !$0.isSeparator && y >= $0.y && y < $0.y + $0.height }
    }

    public func rect(ofRow index: Int) -> ViewerChromeRect {
        ViewerChromeRect(x: 0, y: rows[index].y, width: width, height: rows[index].height)
    }
}

public enum SessionMenuKey: Equatable, Sendable {
    case up, down, left, right, activate, escape

    public init?(evdev: UInt32) {
        switch evdev {
        case 103: self = .up
        case 108: self = .down
        case 105: self = .left
        case 106: self = .right
        case 28, 96, 57: self = .activate
        case 1: self = .escape
        default: return nil
        }
    }
}

/// Whether the session window's menu bar is on screen, and how much of the
/// window's top it takes. Outside full screen it is always up and the
/// picture sits below it. In full screen it is hidden, and the pointer
/// touching the top edge brings it up over the picture, the way the macOS
/// menu bar reveals itself over a full screen window.
public struct SessionMenuBarVisibility: Equatable, Sendable {
    /// How close to the top edge the pointer has to come.
    public static let revealBand: Double = 2

    public private(set) var isFullscreen = false
    public private(set) var isRevealed = false

    public init() {}

    public var isVisible: Bool { !isFullscreen || isRevealed }

    public var contentTop: Double { isFullscreen ? 0 : Double(ViewerChromeMetrics.MenuBar.height) }

    public mutating func setFullscreen(_ isFullscreen: Bool) {
        self.isFullscreen = isFullscreen
        isRevealed = false
    }

    public mutating func pointerOnPicture(y: Double, isMenuOpen: Bool) {
        guard isFullscreen else { return }
        if y < Self.revealBand {
            isRevealed = true
        } else if !isMenuOpen {
            isRevealed = false
        }
    }

    public mutating func menuClosed(isPointerOnBar: Bool) {
        guard isFullscreen, !isPointerOnBar else { return }
        isRevealed = false
    }
}

/// Which painted menu is open, and which row of it and of each submenu open
/// from it is highlighted: the whole state the keys and the pointer move.
public struct SessionMenuNavigator: Equatable, Sendable {
    public private(set) var openMenu: Int?
    /// One entry per open popup, the menu first and each submenu after it.
    public private(set) var highlights: [Int?] = []

    public init() {}

    public var isOpen: Bool { openMenu != nil }

    /// A row a person can choose: not a separator, enabled, and not one of
    /// Edit's, which act on a text field and a session window has none.
    public static func isSelectable(_ row: Int, in menu: ViewerMenu) -> Bool {
        guard menu.items.indices.contains(row), !menu.autoenablesItems else { return false }
        let item = menu.items[row]
        return item.command != .separator && item.isEnabled
    }

    /// The menu drawn at `depth`: the open menu at 0, and at each depth
    /// after it the submenu the row above has open.
    public func menu(atDepth depth: Int, in menus: [ViewerMenu]) -> ViewerMenu? {
        guard let openMenu, menus.indices.contains(openMenu), depth < highlights.count else { return nil }
        var menu = menus[openMenu]
        for level in 0..<depth {
            guard let row = highlights[level], let submenu = menu.items[row].submenu else { return nil }
            menu = submenu
        }
        return menu
    }

    public mutating func open(_ index: Int, in menus: [ViewerMenu], highlightFirst: Bool) {
        guard menus.indices.contains(index) else { return }
        openMenu = index
        highlights = [highlightFirst ? Self.firstSelectable(in: menus[index]) : nil]
    }

    public mutating func close() {
        openMenu = nil
        highlights = []
    }

    public mutating func hover(depth: Int, row: Int?, in menus: [ViewerMenu]) {
        guard let menu = menu(atDepth: depth, in: menus) else { return }
        highlights = Array(highlights.prefix(depth + 1))
        guard let row, Self.isSelectable(row, in: menu) else {
            highlights[depth] = nil
            return
        }
        highlights[depth] = row
        if menu.items[row].submenu != nil {
            highlights.append(nil)
        }
    }

    /// A press on a row: the command it chooses, which closes the menus, or
    /// `nil` for a row that opens a submenu or cannot be chosen.
    public mutating func click(depth: Int, row: Int, in menus: [ViewerMenu]) -> ViewerMenuCommand? {
        hover(depth: depth, row: row, in: menus)
        guard let menu = menu(atDepth: depth, in: menus), Self.isSelectable(row, in: menu),
              menu.items[row].submenu == nil else { return nil }
        close()
        return menu.items[row].command
    }

    public mutating func key(_ key: SessionMenuKey, in menus: [ViewerMenu]) -> ViewerMenuCommand? {
        guard let openMenu, let depth = highlights.indices.last,
              let menu = menu(atDepth: depth, in: menus) else { return nil }
        let row = highlights[depth]
        switch key {
        case .down, .up:
            highlights[depth] = Self.nextSelectable(in: menu, after: row, forward: key == .down)
        case .right:
            if let row, let submenu = menu.items[row].submenu {
                highlights.append(Self.firstSelectable(in: submenu))
            } else {
                open((openMenu + 1) % menus.count, in: menus, highlightFirst: true)
            }
        case .left:
            if highlights.count > 1 {
                highlights.removeLast()
            } else {
                open((openMenu + menus.count - 1) % menus.count, in: menus, highlightFirst: true)
            }
        case .activate:
            guard let row else { return nil }
            if let submenu = menu.items[row].submenu {
                highlights.append(Self.firstSelectable(in: submenu))
                return nil
            }
            close()
            return menu.items[row].command
        case .escape:
            if highlights.count > 1 {
                highlights.removeLast()
            } else {
                close()
            }
        }
        return nil
    }

    private static func firstSelectable(in menu: ViewerMenu) -> Int? {
        menu.items.indices.first { isSelectable($0, in: menu) }
    }

    private static func nextSelectable(in menu: ViewerMenu, after row: Int?, forward: Bool) -> Int? {
        let count = menu.items.count
        guard count > 0 else { return nil }
        var index = row ?? (forward ? count - 1 : 0)
        for _ in 0..<count {
            index = (index + (forward ? 1 : count - 1)) % count
            if isSelectable(index, in: menu) { return index }
        }
        return row
    }
}

/// One stroked polyline in a square box, drawn the same two ways: stroked
/// with cairo in the painted menus, and as an SVG in the GTK menus, so the
/// two cannot drift apart.
public struct SessionMenuGlyph: Sendable {
    public let box: Double
    public let lineWidth: Double
    public let points: [(x: Double, y: Double)]

    /// The current choice's checkmark.
    public static let checkmark = SessionMenuGlyph(box: 12, lineWidth: 1.75, points: [(2.5, 6.5), (5, 9), (9.5, 3)])
    /// A row that opens a submenu: a chevron pointing right.
    public static let submenuArrow = SessionMenuGlyph(box: 12, lineWidth: 1.5, points: [(4.5, 2), (8, 6), (4.5, 10)])

    /// GTK rasterises an icon at the size its file declares and scales that
    /// bitmap to the device, so the file declares 3x the box to stay sharp at
    /// fractional scales.
    public func svg(color: ViewerColor) -> String {
        let path = points.enumerated().map { "\($0.offset == 0 ? "M" : "L")\($0.element.x) \($0.element.y)" }.joined(separator: " ")
        let size = Int(box) * 3
        return "<svg xmlns='http://www.w3.org/2000/svg' width='\(size)' height='\(size)' viewBox='0 0 \(Int(box)) \(Int(box))'>"
            + "<path d='\(path)' fill='none' stroke='\(color.hexString)' stroke-width='\(lineWidth)'"
            + " stroke-linecap='round' stroke-linejoin='round'/></svg>"
    }
}
