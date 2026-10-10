import Foundation
import SensoriumCore
import SensoriumHost

/// `--update-self-test`: the new version reads, without changing, the files
/// the host needs to serve. It fails only on a file that is there and
/// cannot be read, and leaves the folder exactly as it found it.
func runHostUpdateSelfTestTests() {
    func scratchDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-update-self-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func files(in directory: URL) -> HostUpdateSelfTest.Files {
        HostUpdateSelfTest.Files(
            deviceIdentity: directory.appendingPathComponent("device-identity.json"),
            tlsIdentity: directory.appendingPathComponent("host-tls-identity.json"),
            approvedDevices: directory.appendingPathComponent("approved-devices.json")
        )
    }

    /// Every name, size, mode and modification time, so a write or a removal
    /// anywhere in the folder shows.
    func snapshot(_ directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().map { (name: String) -> String in
            let path = directory.appendingPathComponent(name).path
            let attributes: [FileAttributeKey: Any] = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = String(describing: attributes[.size] ?? "-")
            let mode = String(describing: attributes[.posixPermissions] ?? "-")
            let modified = String(describing: attributes[.modificationDate] ?? "-")
            return [name, size, mode, modified].joined(separator: " ")
        }
    }

    do {
        let directory = scratchDirectory()
        let missing = directory.appendingPathComponent("never-created", isDirectory: true)
        let status = HostUpdateSelfTest.run(files(in: missing))
        expect(status == 0, "no files at all is a host that has not been set up yet, not a failure, got \(status)")
        expect(
            !FileManager.default.fileExists(atPath: missing.path),
            "the self-test creates nothing, not even the folder it reads from"
        )
        print("PASS: the self-test passes with no files and creates nothing")
    }

    do {
        let directory = scratchDirectory()
        let files = files(in: directory)
        try! FileDeviceIdentityStore(url: files.deviceIdentity).store(try! DeviceIdentity.generate())
        try! FileHostTLSIdentityStore(url: files.tlsIdentity, commonName: "Sensorium Host")
            .store(try! HostTLSIdentity.generate(commonName: "Sensorium Host"))
        let approved = FileApprovedDeviceStore(url: files.approvedDevices)
        approved.save([try! DeviceIdentity.generate().publicKey])
        // The leftover of a write cut short, which the stores themselves
        // delete when they load; the self-test must leave it.
        let partial = directory.appendingPathComponent(".device-identity.json.partial-leftover")
        try! Data("x".utf8).write(to: partial)
        let before = snapshot(directory)

        let status = HostUpdateSelfTest.run(files)
        expect(status == 0, "files the host's own stores wrote read back cleanly, got \(status)")
        expect(snapshot(directory) == before, "the self-test changes nothing in the folder it reads")
        print("PASS: the self-test reads the host's own files and leaves the folder exactly as it was")
    }

    do {
        let directory = scratchDirectory()
        let files = files(in: directory)
        try! Data(#"["\#(Data([1, 2, 3]).base64EncodedString())"]"#.utf8).write(to: files.approvedDevices)
        expect(
            HostUpdateSelfTest.run(files) == 0,
            "the approved-devices file as an older build wrote it, a plain list of keys, still reads"
        )
        print("PASS: the self-test accepts the older approved-devices shape the store still reads")
    }

    let corruptions: [(String, (HostUpdateSelfTest.Files) -> URL, Data)] = [
        ("an identity that is not JSON", \.deviceIdentity, Data("not json".utf8)),
        ("an identity whose key is not a key", \.deviceIdentity, Data(#"{"privateKey":"AAEC"}"#.utf8)),
        ("a TLS identity that is not JSON", \.tlsIdentity, Data("{".utf8)),
        (
            "a TLS identity whose certificate is not a certificate",
            \.tlsIdentity,
            Data(#"{"certificateDER":"AAEC","privateKey":"AAEC"}"#.utf8)
        ),
        ("an approved-devices file that is not JSON", \.approvedDevices, Data("[{".utf8)),
        ("an approved-devices file holding a key that is not base64", \.approvedDevices, Data(#"[{"publicKey":"%%%"}]"#.utf8)),
        ("an empty approved-devices file", \.approvedDevices, Data())
    ]
    for (description, file, contents) in corruptions {
        let directory = scratchDirectory()
        let files = files(in: directory)
        try! contents.write(to: file(files))
        let before = snapshot(directory)
        let status = HostUpdateSelfTest.run(files, report: { _ in })
        expect(status != 0, "\(description) fails the self-test")
        expect(snapshot(directory) == before, "\(description) is left in place, not repaired or replaced")
    }
    print("PASS: the self-test fails on a file that is there and cannot be read, and leaves it in place")

    do {
        let directory = scratchDirectory()
        let files = files(in: directory)
        try! FileManager.default.createDirectory(at: files.tlsIdentity, withIntermediateDirectories: true)
        expect(HostUpdateSelfTest.run(files, report: { _ in }) != 0, "a TLS identity path that is a folder cannot be read")
        print("PASS: the self-test fails on a file it cannot read at all")
    }
}
