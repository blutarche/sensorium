import Foundation
import SensoriumClient
import SensoriumCore

/// `ClipboardSyncSession` imports no AppKit -- see `SensoriumCore`'s own
/// `ClipboardSyncEngine.swift` -- so this runs on every platform this client
/// builds on, unlike the AppKit-bound tests in `Entry+Darwin.swift`.
@MainActor
func testClipboardSyncSessionTests() {
    let clientPasteboard = FakeClipboardPasteboard()
    let clientClipboardLog = ClientDiagnosticsRecorder()
    let clientClipboard = ClipboardSyncSession(
        engine: ClipboardSyncEngine(pasteboard: clientPasteboard, isEnabled: true),
        log: { clientClipboardLog.record($0) }
    )
    let fromHost = ClipboardContent.text("copied on the Mini")
    clientClipboard.receive(fromHost)
    expect(
        clientPasteboard.writtenContents == [fromHost],
        "a clipboard the host sent is applied to this machine's pasteboard"
    )
    for _ in 0..<5 {
        expect(clientClipboard.poll() == nil, "and applying it never sends it straight back")
    }
    let localCopy = ClipboardContent.image(format: .tiff, data: Data(repeating: 5, count: 64))
    clientPasteboard.stageLocalCopy(ClipboardReadout(content: localCopy, isExcludedByType: false))
    expect(clientClipboard.poll() == .clipboard(localCopy), "a copy made on this machine is offered to the host")
    expect(clientClipboard.poll() == nil, "exactly once")
    expect(
        clientClipboardLog.messages.allSatisfy { !$0.contains("copied on the Mini") },
        "no clipboard log line carries any of the content, at any level"
    )
    expect(
        clientClipboardLog.messages.contains { $0.contains("clipboard applied: text, 18 bytes") },
        "outcomes are logged by kind and size instead"
    )

    print("PASS: ClipboardSyncSession applies a received clipboard, never echoes it back, and logs by kind and size only")
}
