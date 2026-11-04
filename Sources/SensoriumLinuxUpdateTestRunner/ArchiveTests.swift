import Foundation
import SensoriumLinuxUpdate

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Extracts `archive` into a fresh `output` folder inside `directory`.
private func extract(
    _ archive: URL,
    in directory: URL,
    maximumBinarySize: Int64 = LinuxUpdateArchive.maximumBinarySize
) -> (Result<URL, LinuxUpdateFailure>, URL) {
    let output = directory.appendingPathComponent("output-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    chmod(output.path, 0o700)
    return (LinuxUpdateArchive.extract(archive, into: output, maximumBinarySize: maximumBinarySize), output)
}

private func contents(of directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

private func isRefusedAsWrongContents(_ result: Result<URL, LinuxUpdateFailure>) -> Bool {
    if case .failure(.wrongArchiveContents) = result { return true }
    return false
}

func testArchiveWithOneBinaryExtractsItExecutable() {
    let directory = makeTemporaryDirectory("archive-good")
    defer { removeTemporaryDirectory(directory) }
    let body = "#!/bin/sh\necho 'Sensorium 0.6.0'\n"

    for (label, entries) in [
        ("a plain name", [TarEntry.binary("Sensorium", body)]),
        ("a single leading ./", [TarEntry.binary("./Sensorium", body)]),
        ("GNU tar's header", [TarEntry(name: "Sensorium", data: Data(body.utf8), mode: 0o600, magic: .gnu)]),
        ("a pax header naming it", [.pax([("mtime", "1800000000.5"), ("path", "Sensorium")]), TarEntry.binary("ignored-by-pax", body)])
    ] {
        let archive = writeArchive(entries, in: directory)
        let (result, output) = extract(archive, in: directory)
        guard case let .success(binary) = result else {
            return expect(false, "an archive with one binary under \(label) extracts, got \(result)")
        }
        expect(binary.standardizedFileURL == output.appendingPathComponent("Sensorium").standardizedFileURL, "the binary is \(output.path)/Sensorium (\(label))")
        expect(contents(of: output) == ["Sensorium"], "the folder holds the binary alone, and no leftover of the archive (\(label))")
        expect(fileType(of: binary) == S_IFREG, "the binary is a regular file (\(label))")
        expect(posixMode(of: binary) == 0o755, "the binary's mode is set to 0755 whatever the archive says (\(label))")
        expect((try? Data(contentsOf: binary)) == Data(body.utf8), "the binary holds the archive's bytes (\(label))")
    }
}

func testArchiveRefusesAnythingButOneRegularBinary() {
    let directory = makeTemporaryDirectory("archive-hostile")
    defer { removeTemporaryDirectory(directory) }
    let outside = directory.appendingPathComponent("outside")

    let hostile: [(String, [TarEntry])] = [
        ("a parent path", [.binary("../Sensorium")]),
        ("a parent path inside a ./ path", [.binary("./../Sensorium")]),
        ("an absolute path", [.binary("/tmp/Sensorium")]),
        ("a binary in a subfolder", [.binary("sub/Sensorium")]),
        ("a binary in a ustar prefix folder", [TarEntry(name: "Sensorium", data: Data("x".utf8), prefix: "sub")]),
        ("two leading ./", [.binary("././Sensorium")]),
        ("a trailing slash", [.binary("Sensorium/")]),
        ("another name", [.binary("sensorium")]),
        ("an empty name", [.binary("")]),
        ("a symbolic link", [TarEntry(name: "Sensorium", type: UInt8(ascii: "2"), linkName: outside.path)]),
        ("a hard link", [TarEntry(name: "Sensorium", type: UInt8(ascii: "1"), linkName: outside.path)]),
        ("a character device", [TarEntry(name: "Sensorium", type: UInt8(ascii: "3"))]),
        ("a block device", [TarEntry(name: "Sensorium", type: UInt8(ascii: "4"))]),
        ("a folder", [TarEntry(name: "Sensorium", type: UInt8(ascii: "5"))]),
        ("a folder entry before the binary", [TarEntry(name: "./", type: UInt8(ascii: "5")), .binary("./Sensorium")]),
        ("a FIFO", [TarEntry(name: "Sensorium", type: UInt8(ascii: "6"))]),
        ("a contiguous file", [TarEntry(name: "Sensorium", type: UInt8(ascii: "7"), data: Data("x".utf8))]),
        ("a GNU sparse file", [TarEntry(name: "Sensorium", type: UInt8(ascii: "S"), data: Data("x".utf8))]),
        ("a GNU long link name", [TarEntry(name: "././@LongLink", type: UInt8(ascii: "K"), data: Data((outside.path + "\0").utf8)), .binary()]),
        ("a GNU long name leaving the folder", [TarEntry(name: "././@LongLink", type: UInt8(ascii: "L"), data: Data("../../Sensorium\0".utf8)), .binary()]),
        ("a pax path leaving the folder", [.pax([("path", "../Sensorium")]), .binary()]),
        ("a pax link path", [.pax([("linkpath", outside.path)]), .binary()]),
        ("a pax size that disagrees", [.pax([("size", "1")]), .binary()]),
        ("a malformed pax record", [TarEntry(name: "PaxHeader/Sensorium", type: UInt8(ascii: "x"), data: Data("99 path=Sensorium\n".utf8)), .binary()]),
        ("a pax global header", [TarEntry(name: "pax_global_header", type: UInt8(ascii: "g"), data: paxRecords([("comment", "x")])), .binary()]),
        ("a pax header with nothing after it", [.pax([("mtime", "1")])]),
        ("the binary twice", [.binary(), .binary()]),
        ("the binary under both of its names", [.binary("Sensorium"), .binary("./Sensorium")]),
        ("the binary beside another file", [.binary(), .binary("README")]),
        ("a link beside the binary", [TarEntry(name: "extra", type: UInt8(ascii: "2"), linkName: outside.path), .binary()]),
        ("an empty binary", [TarEntry(name: "Sensorium", data: Data())]),
        ("no binary at all", []),
        ("a corrupt header checksum", [TarEntry(name: "Sensorium", data: Data("x".utf8), corruptChecksum: true)]),
        ("a header with no ustar magic", [TarEntry(name: "Sensorium", data: Data("x".utf8), magic: .none)]),
        ("a size field that is not octal", [TarEntry(name: "Sensorium", data: Data("x".utf8), rawSizeField: Array("00000000x01\0".utf8))]),
        ("a base-256 size field", [TarEntry(name: "Sensorium", data: Data("x".utf8), rawSizeField: [0x80] + [UInt8](repeating: 0, count: 10) + [1])]),
        ("a size larger than the data", [TarEntry(name: "Sensorium", data: Data("x".utf8), declaredSize: 4096)])
    ]
    for (label, entries) in hostile {
        let archive = writeArchive(entries, in: directory)
        let (result, output) = extract(archive, in: directory)
        expect(isRefusedAsWrongContents(result), "an archive with \(label) is refused as wrong contents, got \(result)")
        expect(contents(of: output).isEmpty, "a refused archive with \(label) leaves nothing behind")
        expect(!FileManager.default.fileExists(atPath: outside.path), "a refused archive with \(label) wrote nothing outside its folder")
    }

    let tooMany = Array(repeating: TarEntry.pax([("mtime", "1")]), count: LinuxUpdateArchive.maximumHeaders) + [TarEntry.binary()]
    let (tooManyResult, _) = extract(writeArchive(tooMany, in: directory), in: directory)
    expect(isRefusedAsWrongContents(tooManyResult), "an archive past the header count bound is refused")
    let justEnough = Array(repeating: TarEntry.pax([("mtime", "1")]), count: LinuxUpdateArchive.maximumHeaders - 1) + [TarEntry.binary()]
    let (justEnoughResult, _) = extract(writeArchive(justEnough, in: directory), in: directory)
    guard case .success = justEnoughResult else {
        return expect(false, "an archive at the header count bound extracts, got \(justEnoughResult)")
    }
}

func testArchiveRefusesWhatIsNotACleanTarStream() {
    let directory = makeTemporaryDirectory("archive-stream")
    defer { removeTemporaryDirectory(directory) }

    let notGzip = directory.appendingPathComponent("not-gzip.tar.gz")
    try! Data("this is not gzip".utf8).write(to: notGzip)
    let (notGzipResult, notGzipOutput) = extract(notGzip, in: directory)
    expect(isRefusedAsWrongContents(notGzipResult), "bytes that are not gzip are refused")
    expect(contents(of: notGzipOutput).isEmpty, "a refused stream leaves nothing behind")

    let noEnd = writeArchive([.binary()], in: directory, trailer: Data())
    expect(isRefusedAsWrongContents(extract(noEnd, in: directory).0), "an archive with no end marker is refused")

    let trailing = writeArchive([.binary()], in: directory, trailer: Data(count: 1024) + Data("hidden".utf8) + Data(count: 506))
    expect(isRefusedAsWrongContents(extract(trailing, in: directory).0), "bytes after the end marker are refused")

    let padded = writeArchive([.binary()], in: directory, trailer: Data(count: 10_240))
    guard case .success = extract(padded, in: directory).0 else {
        return expect(false, "zero padding to a tar record size is accepted")
    }

    let oversized = writeArchive([TarEntry(name: "Sensorium", data: Data(repeating: UInt8(ascii: "A"), count: 128 * 1024))], in: directory)
    let (oversizedResult, oversizedOutput) = extract(oversized, in: directory, maximumBinarySize: 64 * 1024)
    expect(isRefusedAsWrongContents(oversizedResult), "a binary past the size bound is refused")
    expect(contents(of: oversizedOutput).isEmpty, "a binary past the size bound leaves nothing behind")

    // Far past the bound plus every header the archive may hold, so the
    // decompression itself is stopped.
    let bombSize = 8 * 1024 * 1024
    let bomb = writeArchive([TarEntry(name: "Sensorium", data: Data(repeating: UInt8(ascii: "A"), count: bombSize))], in: directory)
    let (bombResult, bombOutput) = extract(bomb, in: directory, maximumBinarySize: 64 * 1024)
    expect(isRefusedAsWrongContents(bombResult), "an archive that unpacks far past the size bound is refused")
    expect(contents(of: bombOutput).isEmpty, "an archive that unpacks far past the size bound leaves nothing behind")
    let (fitsResult, _) = extract(bomb, in: directory, maximumBinarySize: Int64(bombSize))
    guard case .success = fitsResult else {
        return expect(false, "a binary exactly at the size bound extracts, got \(fitsResult)")
    }

    let missing = directory.appendingPathComponent("missing.tar.gz")
    let (missingResult, _) = extract(missing, in: directory)
    expect(missingResult == .failure(.stagingFailed), "an archive that is not there is the engine's own failure, not the release's")
}

/// What the release script makes with a real tar: the binary named alone.
/// An archive of the folder itself also holds a `./` folder entry, which is
/// refused.
func testArchiveFromTheSystemTarExtracts() {
    let directory = makeTemporaryDirectory("archive-system-tar")
    defer { removeTemporaryDirectory(directory) }
    let source = directory.appendingPathComponent("source", isDirectory: true)
    writeFile("#!/bin/sh\necho 'Sensorium 0.6.0'\n", to: source.appendingPathComponent("Sensorium"), mode: 0o755)

    let named = directory.appendingPathComponent("named.tar.gz")
    expect(systemTar(["-czf", named.path, "-C", source.path, "Sensorium"]) == 0, "the system tar makes an archive")
    guard case .success = extract(named, in: directory).0 else {
        return expect(false, "an archive the system tar made of the binary alone extracts")
    }

    let dotted = directory.appendingPathComponent("dotted.tar.gz")
    expect(systemTar(["-czf", dotted.path, "-C", source.path, "./Sensorium"]) == 0, "the system tar makes an archive with ./")
    guard case .success = extract(dotted, in: directory).0 else {
        return expect(false, "an archive the system tar made of ./Sensorium extracts")
    }

    let wholeFolder = directory.appendingPathComponent("folder.tar.gz")
    expect(systemTar(["-czf", wholeFolder.path, "-C", source.path, "."]) == 0, "the system tar makes an archive of a folder")
    expect(isRefusedAsWrongContents(extract(wholeFolder, in: directory).0), "an archive of the folder itself holds a folder entry and is refused")
}
