#if os(Linux)
import Foundation

/// A D-Bus value, spelled out so the tray item's answers can be built and
/// checked without a bus. `StatusNotifierTrayPresenter` turns one into the
/// matching `GVariant`.
public indirect enum DBusValue: Equatable, Sendable {
    case string(String)
    case objectPath(String)
    case int32(Int32)
    case uint32(UInt32)
    case boolean(Bool)
    case byte(UInt8)
    /// `elementSignature` is kept apart from the elements so an empty array
    /// still has a type.
    case array(elementSignature: String, [DBusValue])
    case tuple([DBusValue])
    case dictEntry(DBusValue, DBusValue)
    case variant(DBusValue)

    /// The D-Bus type signature of this value.
    public var signature: String {
        switch self {
        case .string: return "s"
        case .objectPath: return "o"
        case .int32: return "i"
        case .uint32: return "u"
        case .boolean: return "b"
        case .byte: return "y"
        case .array(let element, _): return "a" + element
        case .tuple(let parts): return "(" + parts.map(\.signature).joined() + ")"
        case .dictEntry(let key, let value): return "{" + key.signature + value.signature + "}"
        case .variant: return "v"
        }
    }
}

/// One entry of the tray item's menu.
public struct StatusNotifierMenuItem: Equatable, Sendable {
    public let id: Int32
    public let label: String
    public let enabled: Bool
}

/// Everything the tray item says, as values: the `org.kde.StatusNotifierItem`
/// properties a tray host reads, and the `com.canonical.dbusmenu` menu it
/// draws when the item is clicked.
///
/// The menu is the minimal one a tray host accepts: a root with one child,
/// Stop. The item carries the device's name in its title and tooltip, because
/// a tray host shows those where the person at the machine can read them.
public struct StatusNotifierModel: Sendable {
    public static let objectPath = "/StatusNotifierItem"
    public static let menuPath = "/MenuBar"

    public let deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    // MARK: - Item

    /// The properties `org.kde.StatusNotifierItem` declares.
    public static let propertyNames = [
        "Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap", "OverlayIconName",
        "OverlayIconPixmap", "AttentionIconName", "AttentionIconPixmap", "AttentionMovieName", "ToolTip",
        "ItemIsMenu", "Menu"
    ]

    /// The title a tray host shows for the item.
    public var title: String { "Sharing with \(deviceName)" }

    private static let emptyPixmaps = DBusValue.array(elementSignature: "(iiay)", [])

    public func property(_ name: String) -> DBusValue? {
        switch name {
        case "Category": return .string("ApplicationStatus")
        case "Id": return .string("sensorium-host")
        case "Title": return .string(title)
        case "Status": return .string("Active")
        case "WindowId": return .int32(0)
        case "IconName": return .string("")
        case "IconPixmap": return Self.iconPixmaps
        case "OverlayIconName", "AttentionIconName", "AttentionMovieName": return .string("")
        case "OverlayIconPixmap", "AttentionIconPixmap": return Self.emptyPixmaps
        case "ToolTip":
            return .tuple([
                .string(""), Self.emptyPixmaps, .string("Sensorium Host"),
                .string("\(deviceName) sees and controls this machine's screen")
            ])
        case "ItemIsMenu": return .boolean(true)
        case "Menu": return .objectPath(Self.menuPath)
        default: return nil
        }
    }

    // MARK: - Icon

    private static let iconSize = 22

    /// A filled circle in the alert colour, as the one `(width, height, ARGB)`
    /// pixmap the item offers. A pixmap rather than a theme icon name keeps the
    /// item visible whatever icon theme the desktop uses.
    private static let iconPixmaps: DBusValue = {
        let size = iconSize
        let radius = Double(size) / 2 - 1.5
        let centre = Double(size) / 2
        var bytes: [DBusValue] = []
        for row in 0..<size {
            for column in 0..<size {
                let dx = Double(column) + 0.5 - centre
                let dy = Double(row) + 0.5 - centre
                // One pixel of anti-aliasing across the circle's edge.
                let coverage = min(max(radius + 0.5 - (dx * dx + dy * dy).squareRoot(), 0), 1)
                // Bytes are alpha, red, green, blue, straight alpha.
                bytes.append(contentsOf: [
                    .byte(UInt8((coverage * 255).rounded())), .byte(0xE2), .byte(0x6F), .byte(0x5C)
                ])
            }
        }
        return .array(
            elementSignature: "(iiay)",
            [.tuple([.int32(Int32(size)), .int32(Int32(size)), .array(elementSignature: "y", bytes)])]
        )
    }()

    // MARK: - Menu

    public static let menuPropertyNames = ["Version", "TextDirection", "Status", "IconThemePath"]

    public var menuItems: [StatusNotifierMenuItem] {
        [StatusNotifierMenuItem(id: 1, label: IndicatorPillRenderer.stopLabel, enabled: true)]
    }

    public func menuProperty(_ name: String) -> DBusValue? {
        switch name {
        case "Version": return .uint32(3)
        case "TextDirection": return .string("ltr")
        case "Status": return .string("normal")
        case "IconThemePath": return .array(elementSignature: "s", [])
        default: return nil
        }
    }

    /// Whether an `Event` call on the menu means Stop was chosen.
    public func menuEvent(id: Int32, kind: String) -> Bool {
        kind == "clicked" && menuItems.contains { $0.id == id && $0.enabled }
    }

    /// The `(ia{sv}av)` node for the root (`0`) or for one item.
    private func menuNode(id: Int32, depth: Int32) -> DBusValue? {
        if id == 0 {
            let children: [DBusValue] = depth == 0 ? [] : menuItems.compactMap { item in
                menuNode(id: item.id, depth: 0).map { .variant($0) }
            }
            return .tuple([
                .int32(0),
                Self.properties(["children-display": .string("submenu")]),
                .array(elementSignature: "v", children)
            ])
        }
        guard let item = menuItems.first(where: { $0.id == id }) else { return nil }
        return .tuple([
            .int32(item.id),
            Self.properties([
                "label": .string(item.label), "enabled": .boolean(item.enabled), "visible": .boolean(true)
            ]),
            .array(elementSignature: "v", [])
        ])
    }

    /// The reply to `GetLayout`: `(u(ia{sv}av))`, a revision and the subtree
    /// below `parentID`. `recursionDepth` is `-1` for everything, `0` for the
    /// node alone.
    public func menuLayout(parentID: Int32, recursionDepth: Int32) -> DBusValue {
        let node = menuNode(id: parentID, depth: recursionDepth)
            ?? .tuple([.int32(parentID), Self.properties([:]), .array(elementSignature: "v", [])])
        return .tuple([.uint32(1), node])
    }

    /// One property of one menu node, as `GetProperty` returns it.
    public func menuItemProperty(id: Int32, name: String) -> DBusValue? {
        guard case .tuple(let parts)? = menuNode(id: id, depth: 0), case .array(_, let entries) = parts[1] else {
            return nil
        }
        for case .dictEntry(.string(let key), .variant(let value)) in entries where key == name {
            return value
        }
        return nil
    }

    /// The reply to `GetGroupProperties`: `a(ia{sv})`.
    public func menuGroupProperties(ids: [Int32]) -> DBusValue {
        let wanted = ids.isEmpty ? [0] + menuItems.map(\.id) : ids
        let entries: [DBusValue] = wanted.compactMap { id in
            guard case .tuple(let parts)? = menuNode(id: id, depth: 0) else { return nil }
            return .tuple([parts[0], parts[1]])
        }
        return .array(elementSignature: "(ia{sv})", entries)
    }

    private static func properties(_ values: [String: DBusValue]) -> DBusValue {
        .array(
            elementSignature: "{sv}",
            values.sorted { $0.key < $1.key }.map { .dictEntry(.string($0.key), .variant($0.value)) }
        )
    }
}
#endif
