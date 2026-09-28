import Foundation
import SensoriumClient
import SensoriumCore

private func testMenus() -> [ViewerMenu] {
    let resolution = ViewerMenu(title: "Resolution", items: [
        ViewerMenuItem(title: "1920 \u{00D7} 1080", command: .selectHostScreenMode("a"), isSelected: true),
        ViewerMenuItem(title: "2560 \u{00D7} 1440", command: .selectHostScreenMode("b"))
    ])
    return [
        ViewerMenu(title: "Sensorium", items: [
            ViewerMenuItem(title: "About Sensorium", command: .about),
            .separator,
            ViewerMenuItem(title: "Quit Sensorium", command: .quit, keyEquivalent: "q", modifiers: [.command])
        ]),
        ViewerMenu(title: "Edit", autoenablesItems: true, items: [
            ViewerMenuItem(title: "Copy", command: .copy, keyEquivalent: "c", modifiers: [.command])
        ]),
        ViewerMenu(title: "Screen", items: [
            ViewerMenuItem(title: "Virtual Display", command: .selectRealScreen(nil)),
            ViewerMenuItem(title: "Disabled", command: .selectRealScreen(Data([9])), isEnabled: false),
            ViewerMenuItem(title: "Studio Display", command: .selectRealScreen(Data([1])), isSelected: true),
            .separator,
            ViewerMenuItem(title: "Resolution", command: .submenu, submenu: resolution)
        ])
    ]
}

/// The painted bar's titles sit side by side, each padded the same on both
/// sides, starting one padding in from the window's left edge; a point finds
/// the title it is over.
func testSessionMenuBarLayoutTests() {
    let pad = Double(ViewerChromeMetrics.MenuBar.itemPaddingX)
    let start = Double(ViewerChromeMetrics.MenuBar.barPaddingX)
    let items = SessionMenuBarLayout.items(titleWidths: [70, 30, 45])
    expect(items.map(\.x) == [start, start + 70 + 2 * pad, start + 100 + 4 * pad], "titles sit side by side, got \(items)")
    expect(items.map(\.width) == [70 + 2 * pad, 30 + 2 * pad, 45 + 2 * pad], "each title is padded on both sides")
    expect(SessionMenuBarLayout.item(atX: start + 1, in: items) == 0, "the first title's left edge is the first title")
    expect(SessionMenuBarLayout.item(atX: items[2].x + 1, in: items) == 2, "a point over the third title finds it")
    expect(SessionMenuBarLayout.item(atX: start - 1, in: items) == nil, "the padding before the first title is no title")
    expect(SessionMenuBarLayout.item(atX: 10_000, in: items) == nil, "the bar past the last title is no title")
    print("PASS: the session menu bar lays its titles out side by side and finds the one under a point")
}

/// A menu's rows, laid out the way it is painted: padding above and below,
/// one row height per item, a thinner band per separator, and a width that
/// fits the check column, the longest title and the longest chord.
func testSessionMenuPopupLayoutTests() {
    let metrics = ViewerChromeMetrics.MenuBar.self
    let menu = testMenus()[0]
    let layout = SessionMenuPopupLayout(menu: menu, titleWidths: [100, 0, 90], chordWidths: [0, 0, 40])
    let padding = Double(metrics.popupPaddingY)
    let row = Double(metrics.rowHeight)
    let separator = Double(metrics.separatorHeight)
    expect(layout.rows.map(\.y) == [padding, padding + row, padding + row + separator], "rows stack from the top padding, got \(layout.rows)")
    expect(layout.rows.map(\.isSeparator) == [false, true, false], "the separator is its own band")
    expect(layout.height == padding * 2 + row * 2 + separator, "the menu is as tall as its rows and padding")
    let width = Double(metrics.rowPaddingX) * 2 + Double(metrics.checkColumnWidth) + 100 + Double(metrics.chordGap) + 40
    expect(layout.width == max(width, Double(metrics.minimumPopupWidth)), "the menu fits its widest title and chord, got \(layout.width)")
    expect(layout.row(atY: padding + 1) == 0, "a point in the first row finds it")
    expect(layout.row(atY: padding + row + 1) == nil, "a separator is no row")
    expect(layout.row(atY: padding + row + separator + 1) == 2, "a point in the last row finds it")
    expect(layout.row(atY: 0) == nil, "the top padding is no row")
    print("PASS: a painted menu lays out its rows and finds the one under a point")
}

/// The keys and the pointer move through the menus the way they do in a GTK
/// menu bar: separators, disabled rows and Edit's rows in a window with no
/// text field are skipped, Right opens a submenu or the next menu, Left
/// closes it or goes back, Return chooses, Escape backs out one level.
func testSessionMenuNavigatorTests() {
    let menus = testMenus()
    var navigator = SessionMenuNavigator()
    expect(!navigator.isOpen, "nothing is open at first")

    navigator.open(0, in: menus, highlightFirst: true)
    expect(navigator.openMenu == 0 && navigator.highlights == [0], "the keyboard opens a menu on its first row, got \(navigator)")
    _ = navigator.key(.down, in: menus)
    expect(navigator.highlights == [2], "Down skips the separator, got \(navigator.highlights)")
    _ = navigator.key(.down, in: menus)
    expect(navigator.highlights == [0], "Down wraps round to the top")
    _ = navigator.key(.up, in: menus)
    expect(navigator.highlights == [2], "Up wraps round to the bottom")
    expect(navigator.key(.activate, in: menus) == .quit && !navigator.isOpen, "Return chooses the row and closes the menus")

    navigator.open(0, in: menus, highlightFirst: true)
    _ = navigator.key(.right, in: menus)
    expect(navigator.openMenu == 1 && navigator.highlights == [nil], "Right moves to Edit, whose rows are all disabled here, got \(navigator)")
    expect(navigator.key(.activate, in: menus) == nil && navigator.isOpen, "Return on no row chooses nothing")
    _ = navigator.key(.right, in: menus)
    expect(navigator.openMenu == 2 && navigator.highlights == [0], "Right moves on to Screen")
    _ = navigator.key(.down, in: menus)
    expect(navigator.highlights == [2], "Down skips the disabled row")
    _ = navigator.key(.down, in: menus)
    expect(navigator.highlights == [4], "and the separator, onto the submenu")
    _ = navigator.key(.right, in: menus)
    expect(navigator.highlights == [4, 0], "Right on a submenu opens it on its first row, got \(navigator.highlights)")
    _ = navigator.key(.left, in: menus)
    expect(navigator.highlights == [4] && navigator.openMenu == 2, "Left closes the submenu")
    _ = navigator.key(.left, in: menus)
    expect(navigator.openMenu == 1, "Left at the top level goes back one menu")
    _ = navigator.key(.left, in: menus)
    _ = navigator.key(.left, in: menus)
    expect(navigator.openMenu == 2, "and wraps round from the first menu to the last")
    _ = navigator.key(.escape, in: menus)
    expect(!navigator.isOpen, "Escape at the top level closes the menus")

    navigator.open(2, in: menus, highlightFirst: false)
    expect(navigator.highlights == [nil], "a click opens a menu with nothing highlighted")
    navigator.hover(depth: 0, row: 4, in: menus)
    expect(navigator.highlights == [4, nil], "hovering a submenu row opens the submenu, got \(navigator.highlights)")
    navigator.hover(depth: 1, row: 1, in: menus)
    expect(navigator.highlights == [4, 1], "hovering in the submenu highlights there")
    navigator.hover(depth: 0, row: 1, in: menus)
    expect(navigator.highlights == [nil], "hovering a disabled row highlights nothing and closes the submenu")
    expect(navigator.click(depth: 0, row: 1, in: menus) == nil && navigator.isOpen, "a click on a disabled row does nothing")
    navigator.hover(depth: 0, row: 4, in: menus)
    expect(
        navigator.click(depth: 1, row: 1, in: menus) == .selectHostScreenMode("b") && !navigator.isOpen,
        "a click on a submenu row chooses it and closes the menus"
    )
    navigator.open(2, in: menus, highlightFirst: false)
    expect(navigator.click(depth: 0, row: 4, in: menus) == nil && navigator.highlights == [4, nil], "a click on a submenu row opens it")
    print("PASS: the painted menus move with the keys and the pointer the way a GTK menu bar does")
}

/// Subsurfaces stack in creation order, which is `allCases` order. The HUD
/// sits under the scrim and the status panel, so it is dimmed while they are
/// up and never covers their buttons; the menu bar is above everything.
@MainActor
func testWaylandOverlayStackingTests() {
    let order = WaylandOverlayKind.allCases
    func index(_ kind: WaylandOverlayKind) -> Int { order.firstIndex(of: kind) ?? -1 }
    expect(index(.diagnostics) < index(.canvasScrim), "the HUD is created before the scrim, so the scrim dims it")
    expect(index(.canvasScrim) < index(.statusPanel), "the status panel draws above its scrim")
    expect(order.last == .menuBar, "the menu bar draws above every other overlay")
    print("PASS: the HUD stacks under the scrim and the status panel, and the menu bar above all")
}

/// The bar takes its height from the top of the window outside full screen.
/// In full screen it is hidden, shows over the picture when the pointer
/// reaches the top edge, and goes again once the pointer leaves it with no
/// menu open.
@MainActor
func testSessionMenuBarVisibilityTests() {
    let height = Double(ViewerChromeMetrics.MenuBar.height)
    var bar = SessionMenuBarVisibility()
    expect(bar.isVisible && bar.contentTop == height, "a windowed bar shows and takes its height")
    expect(
        WaylandOverlayLayout.menuBar(windowWidth: 800) == ViewerChromeRect(x: 0, y: 0, width: 800, height: height),
        "the bar spans the window's top edge"
    )
    bar.setFullscreen(true)
    expect(!bar.isVisible && bar.contentTop == 0, "a full screen bar hides and takes nothing")
    bar.pointerOnPicture(y: 40, isMenuOpen: false)
    expect(!bar.isVisible, "the pointer away from the top edge leaves it hidden")
    bar.pointerOnPicture(y: 0, isMenuOpen: false)
    expect(bar.isVisible && bar.contentTop == 0, "the top edge reveals it over the picture")
    bar.pointerOnPicture(y: 60, isMenuOpen: true)
    expect(bar.isVisible, "an open menu keeps it up")
    bar.menuClosed(isPointerOnBar: false)
    expect(!bar.isVisible, "closing the menu away from the bar hides it")
    bar.pointerOnPicture(y: 0, isMenuOpen: false)
    bar.pointerOnPicture(y: 60, isMenuOpen: false)
    expect(!bar.isVisible, "leaving the revealed bar hides it")
    bar.pointerOnPicture(y: 0, isMenuOpen: false)
    bar.setFullscreen(false)
    bar.setFullscreen(true)
    expect(!bar.isVisible, "entering full screen again starts hidden")
    expect(
        WaylandOverlayLayout.canvasScrim(windowWidth: 800, windowHeight: 600, top: height)
            == ViewerChromeRect(x: 0, y: height, width: 800, height: 600 - height),
        "the scrim covers the picture, not the bar"
    )
    print("PASS: the menu bar takes its height outside full screen and reveals at the top edge in it")
}

/// While a painted menu is open every key goes to it; these are the ones it
/// acts on, by evdev code.
@MainActor
func testSessionMenuKeysTests() {
    let expected: [(UInt32, SessionMenuKey?)] = [
        (103, .up), (108, .down), (105, .left), (106, .right),
        (28, .activate), (96, .activate), (57, .activate), (1, .escape), (30, nil), (125, nil)
    ]
    for (code, key) in expected {
        expect(SessionMenuKey(evdev: code) == key, "evdev \(code) is \(String(describing: key))")
    }
    print("PASS: an open painted menu reads the arrows, Return, Enter, Space and Escape")
}

/// A 12px file would be smeared across 18 device pixels at 1.5x.
func testSessionMenuGlyphSVGTests() {
    for glyph in [SessionMenuGlyph.checkmark, .submenuArrow] {
        let svg = glyph.svg(color: ViewerPalette.ink)
        let size = Int(glyph.box) * 3
        expect(
            svg.contains("width='\(size)' height='\(size)'") && svg.contains("viewBox='0 0 \(Int(glyph.box)) \(Int(glyph.box))'"),
            "the glyph's SVG declares 3x its box over a box-sized view: \(svg)"
        )
    }
    print("PASS: the GTK menu glyphs are rasterised sharp at fractional scales")
}
