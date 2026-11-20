#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// The tray item's D-Bus surface, checked as values: the properties a tray
/// host reads and the menu it draws, without a bus.
@MainActor
enum TrayTests {
    static let all: [(String, () async -> Void)] = [
        ("the tray item's properties name the device and have the types the specification gives", testTrayPropertiesNameTheDeviceWithSpecifiedTypes),
        ("the tray icon is a whole ARGB pixmap", testTrayIconIsAWholeARGBPixmap),
        ("the tray menu has Stop and only a click on Stop stops", testTrayMenuHasStopAndOnlyAClickOnStopStops),
        ("the tray menu answers the layout calls a tray host makes", testTrayMenuAnswersTheLayoutCallsATrayHostMakes),
        ("a long device name is carried whole in the tray", testALongDeviceNameIsCarriedWholeInTheTray)
    ]

    static let model = StatusNotifierModel(deviceName: "Studio Desktop")

    static func testTrayPropertiesNameTheDeviceWithSpecifiedTypes() async {
        func property(_ name: String) -> DBusValue? { model.property(name) }
        expect(property("Category") == .string("ApplicationStatus"), "the category is ApplicationStatus")
        expect(property("Id") == .string("sensorium-host"), "the id names the application")
        expect(property("Status") == .string("Active"), "the item is Active while a session is live")
        expect(property("Title") == .string("Sharing with Studio Desktop"), "the title names the device")
        expect(property("ItemIsMenu") == .boolean(true), "a click opens the menu")
        expect(property("Menu") == .objectPath("/MenuBar"), "the menu lives at /MenuBar")
        expect(property("WindowId") == .int32(0), "there is no window id")

        let tooltip = property("ToolTip")
        expect(tooltip?.signature == "(sa(iiay)ss)", "the tooltip has the specification's signature")
        if case .tuple(let parts)? = tooltip, parts.count == 4 {
            expect(parts[2] == .string("Sensorium Host"), "the tooltip's title names the application")
            if case .string(let description) = parts[3] {
                expect(description.contains("Studio Desktop"), "the tooltip's text names the device")
            } else {
                expect(false, "the tooltip's text is a string")
            }
        } else {
            expect(false, "the tooltip is a four-part tuple")
        }

        let expectedSignatures = [
            "Category": "s", "Id": "s", "Title": "s", "Status": "s", "WindowId": "i", "IconName": "s",
            "IconPixmap": "a(iiay)", "OverlayIconName": "s", "OverlayIconPixmap": "a(iiay)",
            "AttentionIconName": "s", "AttentionIconPixmap": "a(iiay)", "AttentionMovieName": "s",
            "ToolTip": "(sa(iiay)ss)", "ItemIsMenu": "b", "Menu": "o"
        ]
        for (name, signature) in expectedSignatures {
            expect(property(name)?.signature == signature, "\(name) has type \(signature)")
        }
        expect(property("NoSuchProperty") == nil, "an unknown property is not answered")
        expect(StatusNotifierModel.propertyNames.sorted() == expectedSignatures.keys.sorted(), "every property the interface declares is answered")
    }

    static func testTrayIconIsAWholeARGBPixmap() async {
        guard case .array(_, let pixmaps)? = model.property("IconPixmap"), pixmaps.count == 1,
              case .tuple(let fields) = pixmaps[0], fields.count == 3,
              case .int32(let width) = fields[0], case .int32(let height) = fields[1],
              case .array(_, let bytes) = fields[2] else {
            expect(false, "the icon is one (width, height, bytes) pixmap")
            return
        }
        expect(width > 0 && height > 0, "the icon has a size")
        expect(bytes.count == Int(width * height * 4), "the icon has four bytes for every pixel")
        let alphas = stride(from: 0, to: bytes.count, by: 4).compactMap { index -> UInt8? in
            if case .byte(let alpha) = bytes[index] { return alpha }
            return nil
        }
        expect(alphas.contains(255) && alphas.contains(0), "the icon is a shape with see-through corners")
    }

    static func testTrayMenuHasStopAndOnlyAClickOnStopStops() async {
        expect(model.menuItems.map(\.label) == ["Stop"], "the menu holds Stop")
        let stop = model.menuItems[0]
        expect(stop.id == 1 && stop.enabled, "Stop is enabled")
        expect(model.menuEvent(id: stop.id, kind: "clicked"), "a click on Stop stops")
        expect(!model.menuEvent(id: stop.id, kind: "hovered"), "hovering Stop does not stop")
        expect(!model.menuEvent(id: stop.id, kind: "opened"), "opening the menu does not stop")
        expect(!model.menuEvent(id: 0, kind: "clicked"), "a click on the menu's root does not stop")
        expect(!model.menuEvent(id: 7, kind: "clicked"), "a click on an item that does not exist does not stop")
    }

    static func testTrayMenuAnswersTheLayoutCallsATrayHostMakes() async {
        let layout = model.menuLayout(parentID: 0, recursionDepth: -1)
        expect(layout.signature == "(u(ia{sv}av))", "the layout has the dbusmenu signature")
        if case .tuple(let parts) = layout, case .tuple(let root) = parts[1], case .array(_, let children) = root[2] {
            expect(children.count == 1, "the root has one child")
            if case .variant(.tuple(let item)) = children[0], case .array(_, let entries) = item[1] {
                let labels = entries.compactMap { entry -> String? in
                    if case .dictEntry(.string("label"), .variant(.string(let label))) = entry { return label }
                    return nil
                }
                expect(labels == ["Stop"], "the child is labelled Stop")
            } else {
                expect(false, "the child is a variant holding an item")
            }
        } else {
            expect(false, "the layout is a revision and a root")
        }
        let flat = model.menuLayout(parentID: 0, recursionDepth: 0)
        if case .tuple(let parts) = flat, case .tuple(let root) = parts[1], case .array(_, let children) = root[2] {
            expect(children.isEmpty, "a depth of zero asks for the root alone")
        } else {
            expect(false, "the flat layout is a revision and a root")
        }
        expect(StatusNotifierModel.menuPropertyNames.sorted() == ["Status", "TextDirection", "Version", "IconThemePath"].sorted(), "the menu declares its four properties")
        expect(model.menuProperty("Version") == .uint32(3), "the menu speaks dbusmenu version 3")
    }

    static func testALongDeviceNameIsCarriedWholeInTheTray() async {
        let long = StatusNotifierModel(deviceName: longDeviceName)
        expect(long.property("Title") == .string("Sharing with \(longDeviceName)"), "the tray title carries the whole name, since a tray truncates it itself")
    }
}
#endif
