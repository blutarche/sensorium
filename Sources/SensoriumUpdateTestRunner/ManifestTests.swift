#if os(macOS)
import Foundation
import SensoriumUpdate

func testVersionsParseStrictlyAndCompareNumerically() {
    expect(UpdateVersion("0.4.0") != nil, "a three-part numeric version parses")
    expect(UpdateVersion("0.4.0")?.description == "0.4.0", "a version prints back as it was written")
    for bad in ["", "0.4", "0.4.0.1", "v0.4.0", "0.4.x", "-1.0.0", "0.4.0 ", " 0.4.0", "01.2.3", "0..1", "1.2.+3", "0.4.0-beta", "1234567890.0.0", "٣.0.0"] {
        expect(UpdateVersion(bad) == nil, "'\(bad)' is not a version")
    }
    expect(UpdateVersion("0.10.0")! > UpdateVersion("0.9.9")!, "versions compare by number, not by text")
    expect(UpdateVersion("1.0.0")! > UpdateVersion("0.99.99")!, "the major part outranks the others")
    expect(UpdateVersion("0.4.1")! > UpdateVersion("0.4.0")!, "the patch part counts")
    expect(UpdateVersion("0.4.0")! == UpdateVersion("0.4.0")!, "equal versions are equal")
}

func testManifestParsesTheDesignShape() {
    let manifest = try! UpdateManifest.parse(serialized(sampleManifestObject()))
    expect(manifest.version == UpdateVersion("0.4.0")!, "the version is read")
    expect(manifest.minimumMacOS == UpdateSystemVersion(major: 13, minor: 0), "the minimum macOS is read")
    let viewer = manifest.app(.viewer)
    expect(viewer.bundleIdentifier == "com.sensorium.viewer", "the viewer's bundle identifier is read")
    expect(viewer.file == "Sensorium-0.4.0.zip", "the viewer's file is read")
    expect(viewer.size == 4_194_304, "the viewer's size is read")
    expect(viewer.sha256 == sampleDigest, "the viewer's digest is read")
    expect(manifest.app(.host).file == "Sensorium-Host-0.4.0.zip", "the host's file is read")

    let largest = manifestObject(sampleManifestObject(), settingApp: "host", field: "size", to: 512 * 1024 * 1024)
    expect((try? UpdateManifest.parse(serialized(largest))) != nil, "a zip of exactly 512 MB is allowed")

    let threePartMinimum = sampleManifestObject().merging(["minimumMacOS": "13.4.1"]) { $1 }
    expect(
        (try? UpdateManifest.parse(serialized(threePartMinimum)))?.minimumMacOS
            == UpdateSystemVersion(major: 13, minor: 4, patch: 1),
        "a three-part minimum macOS is read"
    )
}

func testManifestRejectsEveryMalformedField() {
    func rejected(_ object: [String: Any], _ why: String) {
        expect((try? UpdateManifest.parse(serialized(object))) == nil, "a manifest is refused when \(why)")
    }
    let base = sampleManifestObject()
    rejected(base.merging(["format": 2]) { $1 }, "its format is 2")
    rejected(base.merging(["format": "1"]) { $1 }, "its format is a string")
    rejected(base.filter { $0.key != "format" }, "it has no format")
    rejected(base.merging(["version": "0.4"]) { $1 }, "its version has two parts")
    rejected(base.merging(["version": "v0.4.0"]) { $1 }, "its version has a prefix")
    rejected(base.filter { $0.key != "minimumMacOS" }, "it has no minimum macOS")
    rejected(base.merging(["minimumMacOS": "thirteen"]) { $1 }, "its minimum macOS is not numeric")
    rejected(base.merging(["minimumMacOS": "13"]) { $1 }, "its minimum macOS has one part")
    rejected(base.merging(["apps": ["viewer": (base["apps"] as! [String: Any])["viewer"]!]]) { $1 }, "it has no host app")

    rejected(manifestObject(base, settingApp: "viewer", field: "file", to: "Sensorium-0.4.1.zip"), "the viewer's file names another version")
    rejected(manifestObject(base, settingApp: "viewer", field: "file", to: "Sensorium-Host-0.4.0.zip"), "the viewer's file is the host's")
    rejected(manifestObject(base, settingApp: "host", field: "file", to: "Sensorium-0.4.0.zip"), "the host's file is the viewer's")
    rejected(manifestObject(base, settingApp: "viewer", field: "file", to: "../Sensorium-0.4.0.zip"), "the file name climbs out of the release")
    rejected(manifestObject(base, settingApp: "viewer", field: "file", to: "Sensorium-0.4.0.zip?x=1"), "the file name carries a query")
    rejected(manifestObject(base, settingApp: "host", field: "size", to: 0), "a size is 0")
    rejected(manifestObject(base, settingApp: "host", field: "size", to: -1), "a size is negative")
    rejected(manifestObject(base, settingApp: "host", field: "size", to: 512 * 1024 * 1024 + 1), "a size is over 512 MB")
    rejected(manifestObject(base, settingApp: "host", field: "size", to: 1.5), "a size is not a whole number")
    rejected(manifestObject(base, settingApp: "viewer", field: "sha256", to: sampleDigest.uppercased()), "a digest is upper case")
    rejected(manifestObject(base, settingApp: "viewer", field: "sha256", to: String(sampleDigest.dropLast())), "a digest has 63 characters")
    rejected(manifestObject(base, settingApp: "viewer", field: "sha256", to: sampleDigest + "a"), "a digest has 65 characters")
    rejected(manifestObject(base, settingApp: "viewer", field: "sha256", to: String(repeating: "g", count: 64)), "a digest is not hex")
    rejected(manifestObject(base, settingApp: "viewer", field: "bundleIdentifier", to: nil), "a bundle identifier is missing")
    rejected(manifestObject(base, settingApp: "viewer", field: "bundleIdentifier", to: ""), "a bundle identifier is empty")
    expect((try? UpdateManifest.parse(Data("not json".utf8))) == nil, "bytes that are not JSON are refused")
}
#endif
