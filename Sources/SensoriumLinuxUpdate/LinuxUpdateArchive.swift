import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Unpacks a release archive, as section 11.4 step 2 of
/// `docs/self-update-design.md` describes.
///
/// The system's gzip only decompresses. The tar stream it produces is read
/// here, and the one file it may hold is written here: no tar program ever
/// creates a file, so no entry's name, type, owner or mode can reach the
/// disk. The whole listing is checked before the binary is written.
public enum LinuxUpdateArchive {
    /// The one entry a release archive holds, named alone or as
    /// `./Sensorium`.
    public static let binaryName = "Sensorium"

    /// The largest binary accepted.
    public static let maximumBinarySize: Int64 = 512 * 1024 * 1024

    /// Headers of every kind, extended ones included. A release archive
    /// needs one, or two with a pax header.
    public static let maximumHeaders = 16

    /// The largest pax or GNU long-name header body read.
    static let maximumMetadataSize: Int64 = 64 * 1024

    public static let defaultGzip = URL(fileURLWithPath: "/usr/bin/gzip")

    private static let decompressedName = ".archive.tar"

    /// Writes `directory/Sensorium`, mode 0755, and returns it.
    /// `directory` is a fresh owner-only folder; on any failure it is left
    /// as it was found.
    public static func extract(
        _ archive: URL,
        into directory: URL,
        gzip: URL = defaultGzip,
        maximumBinarySize: Int64 = maximumBinarySize
    ) -> Result<URL, LinuxUpdateFailure> {
        let tar = directory.appendingPathComponent(decompressedName)
        defer { unlink(tar.path) }
        let streamLimit = maximumBinarySize + Int64(maximumHeaders) * (512 + maximumMetadataSize) + 64 * 1024
        switch decompress(archive, to: tar, limit: streamLimit, gzip: gzip) {
        case .done:
            break
        case let .refused(why):
            return .failure(.wrongArchiveContents(why))
        case .failed:
            return .failure(.stagingFailed)
        }

        let descriptor = open(tar.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return .failure(.stagingFailed) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failure(.stagingFailed) }

        let entry: BinaryEntry
        switch listing(TarFile(descriptor: descriptor, length: Int64(info.st_size)), maximumBinarySize: maximumBinarySize) {
        case let .success(found):
            entry = found
        case let .failure(refusal):
            return .failure(.wrongArchiveContents(refusal.why))
        }

        let binary = directory.appendingPathComponent(binaryName)
        guard copy(from: descriptor, entry: entry, to: binary) else {
            unlink(binary.path)
            return .failure(.stagingFailed)
        }
        return .success(binary)
    }

    // MARK: Decompression

    private enum Decompression {
        case done
        case refused(String)
        case failed
    }

    /// Reads gzip's output through a pipe and stops it past `limit`, so an
    /// archive that unpacks to far more than any release cannot fill the
    /// disk.
    private static func decompress(_ archive: URL, to output: URL, limit: Int64, gzip: URL) -> Decompression {
        guard let input = FileHandle(forReadingAtPath: archive.path) else {
            return .failed
        }
        defer { try? input.close() }
        let descriptor = open(output.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return .failed }
        defer { close(descriptor) }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = gzip
        process.arguments = ["-d", "-c"]
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed
        }

        let reader = pipe.fileHandleForReading
        var total: Int64 = 0
        var outcome = Decompression.done
        while true {
            guard let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            total += Int64(chunk.count)
            if total > limit {
                kill(process.processIdentifier, SIGKILL)
                outcome = .refused("the archive unpacks to more than \(limit) bytes")
                break
            }
            if !writeAll(chunk, to: descriptor) {
                kill(process.processIdentifier, SIGKILL)
                outcome = .failed
                break
            }
        }
        try? reader.close()
        let ended = LinuxUpdateChildProcess.wait(for: process, timeout: nil)
        guard case .done = outcome else { return outcome }
        guard ended == .exited(0) else {
            return .refused("the archive is not a whole gzip stream")
        }
        return fsync(descriptor) == 0 ? .done : .failed
    }

    // MARK: Listing

    struct BinaryEntry: Equatable {
        let dataOffset: Int64
        let size: Int64
    }

    struct Refusal: Error, Equatable {
        let why: String
    }

    struct TarFile {
        let descriptor: Int32
        let length: Int64

        func bytes(at offset: Int64, count: Int) -> [UInt8]? {
            guard offset >= 0, count >= 0, offset + Int64(count) <= length else { return nil }
            var buffer = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                let read = buffer.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                }
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { return nil }
                done += read
            }
            return buffer
        }
    }

    /// Walks every header and finds the binary's data, or says why the
    /// archive is refused. Reads no entry's data except extended headers.
    static func listing(_ file: TarFile, maximumBinarySize: Int64) -> Result<BinaryEntry, Refusal> {
        func refuse(_ why: String) -> Result<BinaryEntry, Refusal> { .failure(Refusal(why: why)) }

        var offset: Int64 = 0
        var headers = 0
        var binary: BinaryEntry?
        // An extended header describes the entry that follows it.
        var pendingPath: String?
        var pendingSize: Int64?
        var pendingExtended = false

        while true {
            guard let header = file.bytes(at: offset, count: 512) else {
                return refuse("the archive ends before its end marker")
            }
            if header.allSatisfy({ $0 == 0 }) {
                guard !pendingExtended else {
                    return refuse("an extended header describes no entry")
                }
                guard isZero(file, from: offset) else {
                    return refuse("the archive holds data after its end marker")
                }
                break
            }
            headers += 1
            guard headers <= maximumHeaders else {
                return refuse("the archive holds more than \(maximumHeaders) headers")
            }
            guard hasValidChecksum(header) else {
                return refuse("a header's checksum does not match")
            }
            let isPOSIX = header[257..<263].elementsEqual(Array("ustar\0".utf8)) && header[263..<265].elementsEqual(Array("00".utf8))
            let isGNU = header[257..<265].elementsEqual(Array("ustar  \0".utf8))
            guard isPOSIX || isGNU else {
                return refuse("a header is not a ustar header")
            }
            guard let size = octal(header[124..<136]) else {
                return refuse("a header's size is not an octal number")
            }
            let dataOffset = offset + 512
            let next = dataOffset + (size + 511) / 512 * 512
            guard next <= file.length else {
                return refuse("the archive ends inside an entry")
            }

            switch header[156] {
            case UInt8(ascii: "x"):
                guard size <= maximumMetadataSize, let body = file.bytes(at: dataOffset, count: Int(size)),
                      let records = paxRecords(body) else {
                    return refuse("a pax header is malformed")
                }
                for (key, value) in records {
                    switch key {
                    case "path":
                        pendingPath = value
                    case "linkpath":
                        return refuse("the archive holds a link")
                    case "size":
                        guard let declared = Int64(value), declared >= 0, String(declared) == value else {
                            return refuse("a pax header's size is not a number")
                        }
                        pendingSize = declared
                    default:
                        break
                    }
                }
                pendingExtended = true
            case UInt8(ascii: "L"):
                guard size <= maximumMetadataSize, let body = file.bytes(at: dataOffset, count: Int(size)),
                      let name = text(body[...]) else {
                    return refuse("a long name header is malformed")
                }
                pendingPath = name
                pendingExtended = true
            case UInt8(ascii: "0"), 0:
                guard let headerName = entryName(header, isPOSIX: isPOSIX) else {
                    return refuse("an entry's name is not text")
                }
                let name = pendingPath ?? headerName
                if let pendingSize, pendingSize != size {
                    return refuse("a pax size disagrees with its header")
                }
                pendingPath = nil
                pendingSize = nil
                pendingExtended = false
                if let why = refusal(forName: name) {
                    return refuse(why)
                }
                guard binary == nil else {
                    return refuse("the archive holds \(binaryName) more than once")
                }
                guard size > 0 else {
                    return refuse("\(binaryName) is empty")
                }
                guard size <= maximumBinarySize else {
                    return refuse("\(binaryName) is larger than \(maximumBinarySize) bytes")
                }
                binary = BinaryEntry(dataOffset: dataOffset, size: size)
            case UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "K"):
                return refuse("the archive holds a link")
            case UInt8(ascii: "3"), UInt8(ascii: "4"):
                return refuse("the archive holds a device")
            case UInt8(ascii: "5"):
                return refuse("the archive holds a folder")
            case UInt8(ascii: "6"):
                return refuse("the archive holds a FIFO")
            case UInt8(ascii: "g"):
                return refuse("the archive holds a global extended header")
            case let other:
                return refuse("the archive holds an entry of type '\(Character(Unicode.Scalar(other)))'")
            }
            offset = next
        }
        guard let binary else {
            return refuse("the archive does not hold \(binaryName)")
        }
        return .success(binary)
    }

    /// The name must be `Sensorium`, or `./Sensorium` with one leading `./`.
    static func refusal(forName name: String) -> String? {
        if name.isEmpty {
            return "an entry has no name"
        }
        if name.hasPrefix("/") {
            return "an entry has an absolute path"
        }
        if name.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            return "an entry's path leaves its folder"
        }
        let stripped = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
        guard stripped == binaryName else {
            return "the archive holds an entry other than \(binaryName)"
        }
        return nil
    }

    private static func entryName(_ header: [UInt8], isPOSIX: Bool) -> String? {
        guard let name = text(header[0..<100]) else { return nil }
        guard isPOSIX, let prefix = text(header[345..<500]), !prefix.isEmpty else {
            return name
        }
        return prefix + "/" + name
    }

    /// The bytes before the first NUL, as UTF-8.
    private static func text(_ bytes: ArraySlice<UInt8>) -> String? {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return utf8(bytes[bytes.startIndex..<end])
    }

    /// Nil unless the bytes are valid UTF-8 with no NUL.
    private static func utf8(_ bytes: ArraySlice<UInt8>) -> String? {
        let decoded = String(decoding: bytes, as: UTF8.self)
        guard decoded.utf8.elementsEqual(bytes), !bytes.contains(0) else { return nil }
        return decoded
    }

    /// Octal digits, optionally led by spaces and ended by NULs or spaces.
    /// GNU tar's base-256 form, for sizes past 8 GB, is refused.
    private static func octal(_ field: ArraySlice<UInt8>) -> Int64? {
        var digits = field.drop { $0 == UInt8(ascii: " ") }
        while let last = digits.last, last == 0 || last == UInt8(ascii: " ") {
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.count <= 21 else { return nil }
        var value: Int64 = 0
        for byte in digits {
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) else { return nil }
            value = value * 8 + Int64(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func hasValidChecksum(_ header: [UInt8]) -> Bool {
        guard let stored = octal(header[148..<156]) else { return false }
        var sum: Int64 = 0
        for (index, byte) in header.enumerated() {
            sum += (148..<156).contains(index) ? Int64(UInt8(ascii: " ")) : Int64(byte)
        }
        return sum == stored
    }

    /// `"<length> <key>=<value>\n"` records filling the body exactly, the
    /// length counting the whole record.
    private static func paxRecords(_ body: [UInt8]) -> [(String, String)]? {
        var records: [(String, String)] = []
        var index = 0
        while index < body.count {
            guard let space = body[index...].firstIndex(of: UInt8(ascii: " ")),
                  space > index, space - index <= 6,
                  let lengthText = utf8(body[index..<space]),
                  lengthText.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  let length = Int(lengthText),
                  length > space - index + 1, index + length <= body.count,
                  body[index + length - 1] == UInt8(ascii: "\n") else {
                return nil
            }
            let record = body[(space + 1)..<(index + length - 1)]
            guard let equals = record.firstIndex(of: UInt8(ascii: "=")), equals > record.startIndex,
                  let key = utf8(record[record.startIndex..<equals]),
                  let value = utf8(record[(equals + 1)...]) else {
                return nil
            }
            records.append((key, value))
            index += length
        }
        return records
    }

    private static func isZero(_ file: TarFile, from offset: Int64) -> Bool {
        var position = offset
        while position < file.length {
            let count = Int(min(64 * 1024, file.length - position))
            guard let chunk = file.bytes(at: position, count: count), chunk.allSatisfy({ $0 == 0 }) else {
                return false
            }
            position += Int64(count)
        }
        return true
    }

    // MARK: Writing the binary

    private static func copy(from source: Int32, entry: BinaryEntry, to binary: URL) -> Bool {
        let descriptor = open(binary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let file = TarFile(descriptor: source, length: entry.dataOffset + entry.size)
        var position = entry.dataOffset
        while position < entry.dataOffset + entry.size {
            let count = Int(min(1 << 20, entry.dataOffset + entry.size - position))
            guard let chunk = file.bytes(at: position, count: count), writeAll(Data(chunk), to: descriptor) else {
                return false
            }
            position += Int64(count)
        }
        return fsync(descriptor) == 0 && fchmod(descriptor, 0o755) == 0
    }

    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                #if canImport(Darwin)
                Darwin.write(descriptor, buffer.baseAddress! + offset, data.count - offset)
                #else
                Glibc.write(descriptor, buffer.baseAddress! + offset, data.count - offset)
                #endif
            }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}
