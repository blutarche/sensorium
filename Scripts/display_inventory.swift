import AppKit
import CoreGraphics
import Foundation

struct DisplayRecord: Encodable {
    let id: UInt32
    let width: Int
    let height: Int
    let modeWidth: Int
    let modeHeight: Int
    let modePixelWidth: Int
    let modePixelHeight: Int
    let boundsX: Double
    let boundsY: Double
    let boundsWidth: Double
    let boundsHeight: Double
    let online: Bool
    let builtin: Bool
    let mirroredDisplayID: UInt32
    let name: String?
}

/// `NSScreen` has no `CGDirectDisplayID` of its own; `NSScreenNumber` is the
/// device description key Apple documents for matching one to a screen.
func localizedNamesByDisplayID() -> [CGDirectDisplayID: String] {
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            continue
        }
        names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
    }
    return names
}

let displayNames = localizedNamesByDisplayID()

func displayIDs(online: Bool) -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    let countResult = online
        ? CGGetOnlineDisplayList(0, nil, &count)
        : CGGetActiveDisplayList(0, nil, &count)
    precondition(countResult == .success, "display list count failed: \(countResult.rawValue)")

    var ids = Array(repeating: CGDirectDisplayID(0), count: Int(count))
    let listResult = online
        ? CGGetOnlineDisplayList(count, &ids, &count)
        : CGGetActiveDisplayList(count, &ids, &count)
    precondition(listResult == .success, "display list values failed: \(listResult.rawValue)")
    return ids
}

func record(for id: CGDirectDisplayID) -> DisplayRecord {
    let bounds = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    return DisplayRecord(
        id: id,
        width: CGDisplayPixelsWide(id),
        height: CGDisplayPixelsHigh(id),
        modeWidth: mode.map { $0.width } ?? 0,
        modeHeight: mode.map { $0.height } ?? 0,
        modePixelWidth: mode.map { $0.pixelWidth } ?? 0,
        modePixelHeight: mode.map { $0.pixelHeight } ?? 0,
        boundsX: bounds.origin.x,
        boundsY: bounds.origin.y,
        boundsWidth: bounds.size.width,
        boundsHeight: bounds.size.height,
        online: CGDisplayIsOnline(id) != 0,
        builtin: CGDisplayIsBuiltin(id) != 0,
        mirroredDisplayID: CGDisplayMirrorsDisplay(id),
        name: displayNames[id]
    )
}

let activeIDs = displayIDs(online: false)
let onlineIDs = displayIDs(online: true)
let active = activeIDs.map(record)
let online = onlineIDs.map(record)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try! encoder.encode(["active": active, "online": online])
print(String(decoding: data, as: UTF8.self))
