import Foundation
import SensoriumClient
import SensoriumCore

/// A host-screen session's pointer and keys, from the viewer's side. The
/// session controller gates every input send on the connection being live and
/// on the coordinate standing on the target, and both of those questions have
/// a different answer once the target is a real display: no canvas was ever
/// created, and the display is whatever size it already is rather than the
/// session canvas's fixed 1920x1200.
@MainActor
func testHostScreenViewerInputTests() async {
    /// A real display larger than the session canvas in both directions, so a
    /// coordinate can be inside this screen and outside that preset at once.
    let geometry = SessionSurfaceGeometry(logicalWidth: 3008, logicalHeight: 1692, backingScale: 2.0)
    let displayIdentity = "00000610-0000a038"

    func connectedHostScreenSession() async -> (ClientSessionController, ScriptedClientTransport) {
        let entry = HostScreenListEntry(
            opaqueToken: Data([0x09]), label: "Built-in Display",
            logicalWidth: geometry.logicalWidth, logicalHeight: geometry.logicalHeight,
            backingScale: geometry.backingScale, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [entry], challenge: Data("challenge".utf8)),
            .hostScreenReady(geometry: geometry, resumeTicket: Data([0x01]))
        ])
        let controller = ClientSessionController(
            transport: transport,
            credentialProvider: SoftwarePresenceCredential()
        )
        _ = try! await controller.connect(
            deviceName: "Laptop",
            target: .hostScreen(displayIdentity: displayIdentity)
        )
        return (controller, transport)
    }

    do {
        // A live host-screen session can send input at all
        let (controller, transport) = await connectedHostScreenSession()
        try! await controller.sendInput(.pointerMoved(x: 1504, y: 846))
        try! await controller.sendInput(.key(keyCode: 0, isDown: true, modifiers: []))
        try! await controller.sendInput(.key(keyCode: 0, isDown: false, modifiers: []))

        let inputs = await transport.sent.filter { if case .input = $0 { return true } else { return false } }
        expect(
            inputs.count == 3,
            "a host-screen session sends its pointer and keys, though it never created a canvas to gate them on"
        )

        print("PASS: a live host-screen session's input reaches the wire")
    }

    do {
        // The target's own size bounds the coordinates, not the canvas preset
        let (controller, _) = await connectedHostScreenSession()
        try! await controller.sendInput(.pointerMoved(x: 2900, y: 1600))
        try! await controller.sendInput(.pointerButton(button: .left, isDown: true, x: 3008, y: 1692))

        var refusedBeyondTheDisplay = false
        do {
            try await controller.sendInput(.pointerMoved(x: 3008.5, y: 846))
        } catch ClientSessionError.invalidInput {
            refusedBeyondTheDisplay = true
        } catch {
            expect(false, "a coordinate past the display's own edge is refused as invalid input, not \(error)")
        }
        expect(
            refusedBeyondTheDisplay,
            "a coordinate past the far edge of the streamed display is still refused"
        )

        print("PASS: a host-screen session's input is bounded by the display it streams, not by the canvas preset")
    }

    do {
        // The canvas path is unchanged
        let transport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 7, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0)
        ])
        let controller = ClientSessionController(transport: transport)
        _ = try! await controller.connect(deviceName: "Laptop")

        try! await controller.sendInput(SensoriumInputEvent.pointerMoved(x: 1920, y: 1200))
        var refusedOffCanvas = false
        do {
            try await controller.sendInput(SensoriumInputEvent.pointerMoved(x: 2900, y: 1600))
        } catch ClientSessionError.invalidInput {
            refusedOffCanvas = true
        } catch {
            expect(false, "a canvas session refuses an off-canvas coordinate as invalid input, not \(error)")
        }
        expect(refusedOffCanvas, "a canvas session still refuses a coordinate off its own 1920x1200 canvas")

        print("PASS: a canvas session's input bounds are unchanged")
    }

    do {
        // A live mode change moves the bound, not just the mapper
        let (controller, _) = await connectedHostScreenSession()
        let biggerMode = SessionSurfaceGeometry(logicalWidth: 3360, logicalHeight: 1890, backingScale: 2.0)
        await controller.hostScreenModeDidApply(geometry: biggerMode)

        try! await controller.sendInput(.pointerMoved(x: 3300, y: 1800))

        var refusedPastNewBound = false
        do {
            try await controller.sendInput(.pointerMoved(x: 3360.5, y: 900))
        } catch ClientSessionError.invalidInput {
            refusedPastNewBound = true
        } catch {
            expect(false, "a coordinate past the new mode's own edge is refused as invalid input, not \(error)")
        }
        expect(
            refusedPastNewBound,
            "a coordinate past the far edge of the display's new mode is still refused"
        )

        print("PASS: a live host-screen mode change moves the bound sendInput enforces, not only the mapper")
    }

    do {
        // A canvas session ignores a mode change meant for a display it never streams
        let transport = ScriptedClientTransport(responses: [
            .canvasReady(displayID: 7, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: 0)
        ])
        let controller = ClientSessionController(transport: transport)
        _ = try! await controller.connect(deviceName: "Laptop")

        await controller.hostScreenModeDidApply(
            geometry: SessionSurfaceGeometry(logicalWidth: 3360, logicalHeight: 1890, backingScale: 2.0)
        )

        try! await controller.sendInput(SensoriumInputEvent.pointerMoved(x: 1920, y: 1200))
        var stillRefusedOffCanvas = false
        do {
            try await controller.sendInput(SensoriumInputEvent.pointerMoved(x: 2900, y: 1600))
        } catch ClientSessionError.invalidInput {
            stillRefusedOffCanvas = true
        } catch {
            expect(false, "a canvas session still refuses an off-canvas coordinate as invalid input, not \(error)")
        }
        expect(
            stillRefusedOffCanvas,
            "a canvas session's bound never widens for a host-screen mode change, since it streams no display at all"
        )

        print("PASS: a canvas session ignores a host-screen mode change")
    }

    do {
        // A session that ended sends nothing
        let (controller, transport) = await connectedHostScreenSession()
        await controller.disconnect(reason: "test")
        let closing = await transport.sent
        expect(
            closing.contains { if case .input(.releaseAllInput, _, _) = $0 { return true } else { return false } },
            "a host-screen session releases whatever it left held on that machine before it goes"
        )
        expect(
            closing.contains { if case .goodbye = $0 { return true } else { return false } },
            "a host-screen session says goodbye rather than just dropping the socket"
        )
        var refusedAfterEnd = false
        do {
            try await controller.sendInput(.pointerMoved(x: 1504, y: 846))
        } catch ClientSessionError.notConnected {
            refusedAfterEnd = true
        } catch {
            expect(false, "input after a host-screen session ended is refused as not connected, not \(error)")
        }
        expect(refusedAfterEnd, "a host-screen session that has ended sends no further input")

        print("PASS: a host-screen session that has ended sends no further input")
    }
}
