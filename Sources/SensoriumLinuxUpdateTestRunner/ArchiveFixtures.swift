import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One header of a tar archive a test builds byte by byte, so an archive can
/// hold anything at all, a hostile one included.
struct TarEntry {
    enum Magic {
        /// POSIX ustar: `ustar\0` then `00`.
        case posix
        /// GNU tar's own: `ustar ` then ` \0`.
        case gnu
        case none
    }

    var name: String
    var type: UInt8 = UInt8(ascii: "0")
    var data = Data()
    var linkName = ""
    var prefix = ""
    var mode = 0o755
    var magic = Magic.posix
    /// Written in place of the real data length.
    var declaredSize: Int?
    /// Written in place of a valid octal size.
    var rawSizeField: [UInt8]?
    var corruptChecksum = false

    static func binary(_ name: String = "Sensorium", _ contents: String = "#!/bin/sh\necho binary\n") -> TarEntry {
        TarEntry(name: name, data: Data(contents.utf8))
    }

    static func pax(_ records: [(String, String)]) -> TarEntry {
        TarEntry(name: "PaxHeader/Sensorium", type: UInt8(ascii: "x"), data: paxRecords(records), mode: 0o644)
    }
}

/// `"<length> <key>=<value>\n"`, where the length counts the whole record,
/// its own digits included.
func paxRecords(_ records: [(String, String)]) -> Data {
    var out = Data()
    for (key, value) in records {
        let body = " \(key)=\(value)\n"
        var length = body.utf8.count + 1
        while String(length).utf8.count + body.utf8.count != length {
            length = String(length).utf8.count + body.utf8.count
        }
        out.append(Data((String(length) + body).utf8))
    }
    return out
}

func tarArchive(_ entries: [TarEntry], trailer: Data = Data(count: 1024)) -> Data {
    var out = Data()
    for entry in entries {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, width: Int) {
            for (index, byte) in text.utf8.prefix(width).enumerated() {
                header[offset + index] = byte
            }
        }
        func octal(_ value: Int, at offset: Int, width: Int) {
            put(String(String(value, radix: 8).suffix(width - 1)).leftPadded(to: width - 1), at: offset, width: width - 1)
        }
        put(entry.name, at: 0, width: 100)
        octal(entry.mode, at: 100, width: 8)
        octal(1000, at: 108, width: 8)
        octal(1000, at: 116, width: 8)
        if let raw = entry.rawSizeField {
            for (index, byte) in raw.prefix(12).enumerated() {
                header[124 + index] = byte
            }
        } else {
            octal(entry.declaredSize ?? entry.data.count, at: 124, width: 12)
        }
        octal(1_800_000_000, at: 136, width: 12)
        header[156] = entry.type
        put(entry.linkName, at: 157, width: 100)
        switch entry.magic {
        case .posix:
            put("ustar", at: 257, width: 6)
            put("00", at: 263, width: 2)
            put(entry.prefix, at: 345, width: 155)
        case .gnu:
            put("ustar  ", at: 257, width: 8)
        case .none:
            break
        }
        for index in 148..<156 {
            header[index] = UInt8(ascii: " ")
        }
        var sum = header.reduce(0) { $0 + Int($1) }
        if entry.corruptChecksum {
            sum += 1
        }
        put(String(String(sum, radix: 8)).leftPadded(to: 6), at: 148, width: 6)
        header[154] = 0
        header[155] = UInt8(ascii: " ")
        out.append(contentsOf: header)
        out.append(entry.data)
        let padding = (512 - entry.data.count % 512) % 512
        out.append(Data(count: padding))
    }
    out.append(trailer)
    return out
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

/// Compresses with the system's gzip, which the engine also decompresses
/// with.
func gzipped(_ data: Data, in directory: URL) -> Data {
    let input = directory.appendingPathComponent("gzip-input-\(UUID().uuidString)")
    let output = directory.appendingPathComponent("gzip-output-\(UUID().uuidString)")
    try! data.write(to: input)
    defer {
        try? FileManager.default.removeItem(at: input)
        try? FileManager.default.removeItem(at: output)
    }
    expect(FileManager.default.createFile(atPath: output.path, contents: nil), "a test can create the gzip output")
    let handle = try! FileHandle(forWritingTo: output)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-n", "-c", input.path]
    process.standardOutput = handle
    try! process.run()
    while process.isRunning {
        usleep(5_000)
    }
    try! handle.close()
    expect(process.terminationStatus == 0, "gzip compresses a test archive")
    return try! Data(contentsOf: output)
}

/// Writes a gzip-compressed tar archive of `entries` into `directory` and
/// returns its location.
func writeArchive(_ entries: [TarEntry], in directory: URL, trailer: Data = Data(count: 1024), name: String = "archive.tar.gz") -> URL {
    let url = directory.appendingPathComponent(name)
    try! gzipped(tarArchive(entries, trailer: trailer), in: directory).write(to: url)
    return url
}

/// Runs the system's tar the way a release script would, so the engine is
/// also held to what a real tool writes.
func systemTar(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    // macOS tar otherwise adds AppleDouble entries for extended attributes.
    environment["COPYFILE_DISABLE"] = "1"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    while process.isRunning {
        usleep(5_000)
    }
    return process.terminationStatus
}
