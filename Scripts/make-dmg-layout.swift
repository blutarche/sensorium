// Writes the Finder window of a Sensorium disk image, and reads one back.
//
//   swift Scripts/make-dmg-layout.swift write <mount point> <volume name> <app file name> <layout.json>
//   swift Scripts/make-dmg-layout.swift dump <.DS_Store>
//
// Finder takes a folder's window from the .DS_Store file inside it: window
// size and chrome, icon size, background picture and each item's position.
// `write` creates that file at the root of a mounted, writable disk image
// volume. The volume must hold the app, a link named Applications, and the
// background picture at .background/background.tiff. <layout.json> is what
// Scripts/make-dmg-background.swift writes next to the picture: window size,
// icon and text size, the two icon centres and the background colour.
//
// The file is written here rather than by asking Finder to arrange the
// window, because a .DS_Store Finder writes records where the background
// picture lay on the machine that arranged it: the path of the disk image
// file, the name of the startup disk, temporary folder paths and volume
// identifiers, in an alias field and in bookmark records. Every published
// disk image would carry them. This file names the picture only by what is
// inside the volume: its path from the volume root, the volume's name and
// date, and the picture's and its folder's catalog IDs, which survive
// conversion to a compressed image. It writes no bookmark record.
//
// `dump` prints one line per record, `<file name> <record> <value>`: item
// positions as `x,y`, property lists as their keys in order as `key=value`,
// and an alias as the volume path it names followed by the path inside the
// volume. Tests use it.
//
// The format is the one Finder reads: a buddy-allocated file ("Bud1") holding
// one B-tree ("DSDB") of records sorted by file name, ignoring case, then by
// record kind. This writer produces the smallest such file, with every record
// in a single 4096 byte leaf node.
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      make-dmg-layout.swift write <mount point> <volume name> <app file name> <layout.json>
      make-dmg-layout.swift dump <.DS_Store>

    """.utf8))
    exit(2)
}

func read(_ path: String) -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return Array(data)
}

func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
func be32(_ value: UInt32) -> [UInt8] { be16(UInt16(value >> 16)) + be16(UInt16(value & 0xFFFF)) }
func utf16BE(_ text: String) -> [UInt8] { text.utf16.flatMap(be16) }
func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

// MARK: - Layout

struct Layout {
    let windowWidth: UInt32
    let windowHeight: UInt32
    let iconSize: Double
    let textSize: Double
    let app: (x: UInt32, y: UInt32)
    let applications: (x: UInt32, y: UInt32)
    let background: (red: Double, green: Double, blue: Double)
}

func loadLayout(_ path: String) -> Layout {
    guard let object = try? JSONSerialization.jsonObject(with: Data(read(path))) as? [String: Any] else {
        fail("\(path) is not a JSON object")
    }
    func number(_ key: String) -> Double {
        guard let value = object[key] else { fail("\(path) has no \"\(key)\"") }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            fail("\"\(key)\" in \(path) is not a number")
        }
        return number.doubleValue
    }
    func points(_ key: String) -> UInt32 {
        let value = number(key)
        guard value >= 0, value <= 0xFFFF, value.rounded() == value else {
            fail("\"\(key)\" in \(path) must be a whole number of points from 0 to 65535")
        }
        return UInt32(value)
    }
    return Layout(
        windowWidth: points("windowWidth"),
        windowHeight: points("windowHeight"),
        iconSize: number("iconSize"),
        textSize: number("textSize"),
        app: (points("appX"), points("appY")),
        applications: (points("applicationsX"), points("applicationsY")),
        background: (number("backgroundRed"), number("backgroundGreen"), number("backgroundBlue"))
    )
}

// MARK: - Background alias

// Seconds between 1904-01-01, the classic Mac OS epoch, and 1970-01-01.
let macEpochOffset = 2_082_844_800

func fileInfo(_ path: String, directory: Bool) -> stat {
    var info = stat()
    guard lstat(path, &info) == 0 else { fail("\(path) does not exist") }
    let kind = info.st_mode & S_IFMT
    guard kind == (directory ? S_IFDIR : S_IFREG) else {
        fail("\(path) is not a \(directory ? "folder" : "regular file")")
    }
    return info
}

func catalogID(_ info: stat, of path: String) -> UInt32 {
    guard info.st_ino <= UInt64(UInt32.max) else { fail("\(path) has no HFS+ catalog ID") }
    return UInt32(info.st_ino)
}

func macDate(_ info: stat) -> UInt32 {
    let seconds = Int(info.st_birthtimespec.tv_sec) + macEpochOffset
    guard seconds >= 0, seconds <= Int(UInt32.max) else { fail("a creation date is out of range for an alias") }
    return UInt32(seconds)
}

func pascal(_ text: String, width: Int, what: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    guard bytes.count < width else { fail("\(what) \"\(text)\" is longer than the \(width - 1) bytes an alias holds") }
    return [UInt8(bytes.count)] + bytes + zeros(width - 1 - bytes.count)
}

func aliasTag(_ tag: UInt16, _ data: [UInt8]) -> [UInt8] {
    be16(tag) + be16(UInt16(data.count)) + data + (data.count % 2 == 1 ? [0] : [])
}

func unicodeName(_ text: String) -> [UInt8] { be16(UInt16(text.utf16.count)) + utf16BE(text) }

// A version 2 alias record to <folder>/<file> on the volume, holding only
// volume-relative data.
func backgroundAlias(mountPoint: String, volumeName: String, folder: String, file: String) -> [UInt8] {
    let volume = fileInfo(mountPoint, directory: true)
    let parentPath = "\(mountPoint)/\(folder)"
    let filePath = "\(parentPath)/\(file)"
    let parentID = catalogID(fileInfo(parentPath, directory: true), of: parentPath)
    let picture = fileInfo(filePath, directory: false)

    var alias: [UInt8] = zeros(4)                       // creator code: none
    alias += be16(0)                                    // record size, set below
    alias += be16(2)                                    // version
    alias += be16(0)                                    // kind: file
    alias += pascal(volumeName, width: 28, what: "the volume name")
    alias += be32(macDate(volume))
    alias += Array("H+".utf8)                           // file system
    alias += be16(5)                                    // disk type: ejectable
    alias += be32(parentID)
    alias += pascal(file, width: 64, what: "the background file name")
    alias += be32(catalogID(picture, of: filePath))
    alias += be32(macDate(picture))
    alias += zeros(8)                                   // file type and creator: none
    alias += be16(0xFFFF) + be16(0xFFFF)                // levels from and to: none
    alias += be32(0x0000_0D02)                          // volume attributes
    alias += be16(0)                                    // file system ID
    alias += zeros(10)
    alias += aliasTag(0, Array(folder.utf8))            // parent folder name
    alias += aliasTag(1, be32(parentID))                // parent folder ID
    alias += aliasTag(2, Array("\(volumeName):\(folder):".utf8) + [0] + Array(file.utf8))
    alias += aliasTag(14, unicodeName(file))
    alias += aliasTag(15, unicodeName(volumeName))
    alias += aliasTag(18, Array("/\(folder)/\(file)".utf8))  // path from the volume root
    alias += aliasTag(19, Array("/Volumes/\(volumeName)".utf8))
    alias += be16(0xFFFF) + be16(0)                     // end of tags
    alias.replaceSubrange(4..<6, with: be16(UInt16(alias.count)))
    return alias
}

// The full path an alias record names, if it is one: its volume's path
// (tag 19) followed by the path from the volume root (tag 18).
func aliasPath(_ alias: [UInt8]) -> String? {
    guard alias.count >= 150, Int(alias[4]) << 8 | Int(alias[5]) == alias.count, alias[6] == 0, alias[7] == 2 else {
        return nil
    }
    var tags: [Int: String] = [:]
    var at = 150
    while at + 4 <= alias.count {
        let tag = Int(alias[at]) << 8 | Int(alias[at + 1])
        let length = Int(alias[at + 2]) << 8 | Int(alias[at + 3])
        if tag == 0xFFFF { break }
        guard at + 4 + length <= alias.count else { return nil }
        tags[tag] = String(decoding: alias[(at + 4)..<(at + 4 + length)], as: UTF8.self)
        at += 4 + length + length % 2
    }
    guard let path = tags[18] else { return nil }
    let volume = tags[19] ?? ""
    return (volume.hasSuffix("/") ? String(volume.dropLast()) : volume) + path
}

// MARK: - Records

struct Record {
    let name: String
    let kind: String
    let type: String
    let value: [UInt8]

    var bytes: [UInt8] {
        let payload = type == "blob" ? be32(UInt32(value.count)) + value : value
        return be32(UInt32(name.utf16.count)) + utf16BE(name) + Array(kind.utf8) + Array(type.utf8) + payload
    }
}

func binaryPlist(_ object: [String: Any]) -> [UInt8] {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) else {
        fail("cannot encode a property list")
    }
    return Array(data)
}

func iconLocation(_ x: UInt32, _ y: UInt32) -> [UInt8] {
    be32(x) + be32(y) + [UInt8](repeating: 0xFF, count: 6) + zeros(2)
}

// Every dot entry at the volume root but .DS_Store. Finder shows them when it
// is set to show hidden files, and places any that has no position inside
// the window.
func hiddenEntries(_ mountPoint: String) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: mountPoint) else {
        fail("cannot list \(mountPoint)")
    }
    return names.filter { $0.hasPrefix(".") && $0 != ".DS_Store" }
        .sorted { Array($0.lowercased().utf16).lexicographicallyPrecedes(Array($1.lowercased().utf16)) }
}

func layoutRecords(layout: Layout, appName: String, hidden: [String], alias: [UInt8]) -> [Record] {
    // The bounds are the whole window, title bar included, so the content
    // keeps the layout's height. Finder moves a window that would fall off
    // the screen back onto it.
    let bounds = "{{160, 160}, {\(layout.windowWidth), \(layout.windowHeight + 28)}}"
    let window: [String: Any] = [
        "ShowStatusBar": false,
        "ShowToolbar": false,
        "ShowTabView": false,
        "ContainerShowSidebar": false,
        "ShowSidebar": false,
        "WindowBounds": bounds,
    ]
    let iconView: [String: Any] = [
        "backgroundType": 2,                            // picture
        "backgroundImageAlias": Data(alias),
        "backgroundColorRed": layout.background.red,
        "backgroundColorGreen": layout.background.green,
        "backgroundColorBlue": layout.background.blue,
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "textSize": layout.textSize,
        "iconSize": layout.iconSize,
        "arrangeBy": "none",
        "labelOnBottom": true,
        "showIconPreview": true,
        "showItemInfo": false,
        "viewOptionsVersion": 1,
    ]
    // Hidden entries go beyond the window's right edge, one below another.
    let hiddenRecords = hidden.enumerated().map { index, name in
        Record(name: name, kind: "Iloc", type: "blob",
               value: iconLocation(layout.windowWidth + 200, 100 + 150 * UInt32(index)))
    }
    let records = hiddenRecords + [
        Record(name: ".", kind: "bwsp", type: "blob", value: binaryPlist(window)),
        Record(name: ".", kind: "icvp", type: "blob", value: binaryPlist(iconView)),
        Record(name: ".", kind: "vSrn", type: "long", value: be32(1)),
        Record(name: appName, kind: "Iloc", type: "blob", value: iconLocation(layout.app.x, layout.app.y)),
        Record(name: "Applications", kind: "Iloc", type: "blob",
               value: iconLocation(layout.applications.x, layout.applications.y)),
    ]
    return records.sorted { lhs, rhs in
        let left = Array(lhs.name.lowercased().utf16), right = Array(rhs.name.lowercased().utf16)
        return left == right ? lhs.kind < rhs.kind : left.lexicographicallyPrecedes(right)
    }
}

// MARK: - Buddy-allocated file

func storeFile(_ records: [Record]) -> [UInt8] {
    let leaf = be32(0) + be32(UInt32(records.count)) + records.flatMap(\.bytes)
    guard leaf.count <= 0x1000 else {
        fail("the layout records take \(leaf.count) bytes, more than the one 4096 byte node this writer produces")
    }

    // Block addresses are an offset with log2 of the block size in the low
    // five bits: the root block at 0x2000 (2048 bytes), the B-tree header at
    // 0x40 (32 bytes) and its one leaf at 0x1000 (4096 bytes).
    var region = zeros(0x2800)
    func put(_ bytes: [UInt8], at offset: Int) {
        region.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
    put(Array("Bud1".utf8) + be32(0x2000) + be32(0x800) + be32(0x2000) + be32(0x100C) + zeros(12), at: 0)
    // B-tree header: root node is block 2, no internal levels, one node of 4096 bytes.
    put(be32(2) + be32(0) + be32(UInt32(records.count)) + be32(1) + be32(0x1000), at: 0x40)
    put(leaf, at: 0x1000)

    var root = be32(3) + be32(0) + be32(0x200B) + be32(0x45) + be32(0x100C) + zeros(4 * 253)
    root += be32(1) + [4] + Array("DSDB".utf8) + be32(1)
    // Free blocks by size, 2^0 to 2^31 bytes: together with the blocks above
    // and the 32 byte file header they cover the allocator's whole space.
    var free: [Int: [UInt32]] = [
        5: [0x20, 0x60], 7: [0x80], 8: [0x100], 9: [0x200], 10: [0x400], 11: [0x800, 0x2800], 12: [0x3000],
    ]
    for size in 14...30 { free[size] = [UInt32(1) << UInt32(size)] }
    for size in 0..<32 {
        let blocks = free[size] ?? []
        root += be32(UInt32(blocks.count)) + blocks.flatMap(be32)
    }
    put(root, at: 0x2000)
    return [0, 0, 0, 1] + region
}

// MARK: - Dump

struct Reader {
    let bytes: [UInt8]
    let path: String

    func slice(_ at: Int, _ count: Int) -> ArraySlice<UInt8> {
        guard at >= 0, count >= 0, at + count <= bytes.count else { fail("\(path) is truncated or damaged") }
        return bytes[at..<(at + count)]
    }

    func u32(_ at: Int) -> Int { slice(at, 4).reduce(0) { $0 << 8 | Int($1) } }
}

func describe(_ value: Any) -> String {
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return CFNumberIsFloatType(number) ? "\(number.doubleValue)" : "\(number.int64Value)"
    }
    if let data = value as? Data {
        return aliasPath(Array(data)) ?? data.map { String(format: "%02x", $0) }.joined()
    }
    if let dictionary = value as? [String: Any] {
        return dictionary.keys.sorted().map { "\($0)=\(describe(dictionary[$0]!))" }.joined(separator: " ")
    }
    return String(describing: value).replacingOccurrences(of: "\n", with: " ")
}

func describeBlob(kind: String, _ blob: ArraySlice<UInt8>) -> String {
    let bytes = Array(blob)
    if kind == "Iloc", bytes.count >= 8 {
        let reader = Reader(bytes: bytes, path: "an Iloc record")
        return "\(reader.u32(0)),\(reader.u32(4))"
    }
    if bytes.starts(with: Array("bplist".utf8)),
       let plist = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil) {
        return describe(plist)
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func dump(_ path: String) {
    let file = read(path)
    guard file.count > 36, file.starts(with: [0, 0, 0, 1] + Array("Bud1".utf8)) else {
        fail("\(path) is not a .DS_Store file")
    }
    let data = Reader(bytes: Array(file.dropFirst(4)), path: path)
    let rootOffset = data.u32(4)
    let blockCount = data.u32(rootOffset)
    let addresses = (0..<blockCount).map { data.u32(rootOffset + 8 + 4 * $0) }
    var at = rootOffset + 8 + 4 * ((blockCount + 255) / 256 * 256)
    var directory: [String: Int] = [:]
    for _ in 0..<data.u32(at) {
        let length = Int(data.slice(at + 4, 1).first!)
        let name = String(decoding: data.slice(at + 5, length), as: UTF8.self)
        directory[name] = data.u32(at + 5 + length)
        at += 1 + length + 4
    }
    func block(_ number: Int) -> Int {
        guard number < addresses.count else { fail("\(path) names a block it does not have") }
        return addresses[number] & ~0x1F
    }
    guard let tree = directory["DSDB"] else { fail("\(path) has no DSDB tree") }

    func node(_ number: Int, depth: Int) {
        guard depth < 32 else { fail("\(path) has a B-tree that loops") }
        var at = block(number)
        let next = data.u32(at)
        let count = data.u32(at + 4)
        at += 8
        for _ in 0..<count {
            if next != 0 {
                node(data.u32(at), depth: depth + 1)
                at += 4
            }
            let nameLength = data.u32(at)
            let nameBytes = Array(data.slice(at + 4, 2 * nameLength))
            let units = stride(from: 0, to: nameBytes.count, by: 2).map { UInt16(nameBytes[$0]) << 8 | UInt16(nameBytes[$0 + 1]) }
            let name = String(decoding: units, as: UTF16.self)
            at += 4 + 2 * nameLength
            let kind = String(decoding: data.slice(at, 4), as: UTF8.self)
            let type = String(decoding: data.slice(at + 4, 4), as: UTF8.self)
            at += 8
            let value: String
            switch type {
            case "long", "shor":
                value = "\(data.u32(at))"
                at += 4
            case "type":
                value = String(decoding: data.slice(at, 4), as: UTF8.self)
                at += 4
            case "bool":
                value = data.slice(at, 1).first! == 0 ? "false" : "true"
                at += 1
            case "comp", "dutc":
                value = "\(data.u32(at) << 32 | data.u32(at + 4))"
                at += 8
            case "blob":
                let length = data.u32(at)
                value = describeBlob(kind: kind, data.slice(at + 4, length))
                at += 4 + length
            case "ustr":
                let length = data.u32(at)
                let raw = Array(data.slice(at + 4, 2 * length))
                let units = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]) }
                value = String(decoding: units, as: UTF16.self)
                at += 4 + 2 * length
            default:
                fail("\(path) holds a record of unknown type \"\(type)\"")
            }
            print("\(name) \(kind) \(value)")
        }
        if next != 0 { node(next, depth: depth + 1) }
    }
    node(data.u32(block(tree)), depth: 0)
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch (command, args.count) {
case ("write", 5):
    let (mountPoint, volumeName, appName, layoutPath) = (args[1], args[2], args[3], args[4])
    let layout = loadLayout(layoutPath)
    for item in [appName, "Applications"] {
        var info = stat()
        guard lstat("\(mountPoint)/\(item)", &info) == 0 else { fail("\(mountPoint) holds no \(item)") }
    }
    let alias = backgroundAlias(mountPoint: mountPoint, volumeName: volumeName, folder: ".background", file: "background.tiff")
    let records = layoutRecords(layout: layout, appName: appName, hidden: hiddenEntries(mountPoint), alias: alias)
    let file = storeFile(records)
    do { try Data(file).write(to: URL(fileURLWithPath: "\(mountPoint)/.DS_Store")) } catch {
        fail("cannot write \(mountPoint)/.DS_Store")
    }

case ("dump", 2):
    dump(args[1])

default:
    usage()
}
