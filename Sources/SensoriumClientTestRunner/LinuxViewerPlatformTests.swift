import Foundation
import SensoriumClient
import SensoriumCore

/// One pasteboard a fake source can hand out, so the proxy is verified with no
/// compositor and no window.
private final class RecordingPasteboard: ClipboardPasteboard {
    var changeCount = 7
    var written: [ClipboardContent] = []

    func read() -> ClipboardReadout {
        ClipboardReadout(content: .text("from the window"), isExcludedByType: false)
    }

    @discardableResult
    func write(_ content: ClipboardContent) -> Int {
        written.append(content)
        changeCount += 1
        return changeCount
    }
}

/// The clipboard the session asks the platform for exists before the window
/// that owns the compositor's own clipboard does, so what it forwards to is
/// filled in later -- and everything it answers before that has to be the
/// truth about a machine with no clipboard yet.
func testWaylandPasteboardProxyTests() {
    let box = ClipboardPasteboardBox()
    let proxy = WaylandPasteboardProxy(source: box)

    expect(proxy.changeCount == 0, "a proxy with no window behind it counts no changes, got \(proxy.changeCount)")
    expect(!proxy.read().hasItems, "a proxy with no window behind it reads nothing, not an unsupported copy")
    expect(proxy.read().text == nil, "and no text")
    expect(!proxy.read().isExcludedByType, "a proxy with no window behind it excludes nothing by type")
    expect(proxy.write(.text("nowhere")) == 0, "a write with no window behind it reports no change count")

    let pasteboard = RecordingPasteboard()
    box.set(pasteboard)
    expect(proxy.changeCount == 7, "once a window is open the proxy reports its change count, got \(proxy.changeCount)")
    expect(
        proxy.read().text == "from the window",
        "once a window is open the proxy reads through it"
    )
    expect(proxy.write(.text("onward")) == 8, "a write through the proxy returns the window's own new change count")
    expect(pasteboard.written == [.text("onward")], "the write reached the window's pasteboard exactly once")

    box.set(nil)
    expect(proxy.changeCount == 0, "a closed window leaves the proxy answering as it did before one was open")
    expect(proxy.write(.text("gone")) == 0, "a write after the window closed reports no change count")
    expect(pasteboard.written == [.text("onward")], "no write reaches a pasteboard the proxy no longer holds")

    print("PASS: the Linux clipboard proxy answers empty until a window owns the compositor's clipboard, forwards while one does, and stops when it closes")
}

/// Where the Linux viewer's four files live and what it calls this machine.
func testLinuxViewerLocationsTests() {
    let home = URL(fileURLWithPath: "/home/ada", isDirectory: true)

    expect(
        LinuxViewerLocations.applicationSupportDirectory(
            environment: ["XDG_DATA_HOME": "/home/ada/data"], homeDirectory: home
        ).path == "/home/ada/data/sensorium",
        "XDG_DATA_HOME names the directory the viewer's files live in"
    )
    expect(
        LinuxViewerLocations.applicationSupportDirectory(environment: [:], homeDirectory: home).path
            == "/home/ada/.local/share/sensorium",
        "without XDG_DATA_HOME the viewer's files live under the XDG default"
    )
    expect(
        LinuxViewerLocations.applicationSupportDirectory(
            environment: ["XDG_DATA_HOME": ""], homeDirectory: home
        ).path == "/home/ada/.local/share/sensorium",
        "an empty XDG_DATA_HOME is not a directory, so the XDG default answers instead"
    )

    expect(
        LinuxViewerLocations.deviceName(hostname: "studio", etcHostname: "written-down") == "studio",
        "the name the kernel reports is what this machine is called"
    )
    expect(
        LinuxViewerLocations.deviceName(hostname: nil, etcHostname: "written-down\n") == "written-down",
        "a kernel that reports no name falls back to the one written down, without its newline"
    )
    expect(
        LinuxViewerLocations.deviceName(hostname: "", etcHostname: "  ") == "This machine",
        "a machine that answers with no name at all is still named the same way macOS names one"
    )

    print("PASS: the Linux viewer resolves its file directory from XDG_DATA_HOME or the XDG default, and its device name from the kernel or /etc/hostname")
}
