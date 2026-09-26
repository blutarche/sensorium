import Foundation
import SensoriumClient
import SensoriumCore

private func offeredEntry(_ token: UInt8, label: String, identity: String) -> HostScreenListEntry {
    HostScreenListEntry(
        opaqueToken: Data([token]), label: label,
        logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: token == 1,
        displayIdentity: identity
    )
}

private func sentNoCanvasRequest(_ transport: ScriptedClientTransport) async -> Bool {
    await transport.sent.allSatisfy { if case .canvasRequest = $0 { return false } else { return true } }
}

/// The default start: whatever the host offers, the session starts on one of
/// its screens on the same connection, and never on a canvas by itself.
func testOfferedHostScreenStartTests() async {
    let builtin = offeredEntry(1, label: "Built-in Display", identity: "builtin-id")
    let external = offeredEntry(2, label: "LS27A800U", identity: "external-id")
    let geometry = SessionSurfaceGeometry(logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0)
    let ticket = Data([0x07])

    do {
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [builtin, external], canvasAvailable: false),
            .hostScreenReady(geometry: geometry, resumeTicket: ticket)
        ])
        let controller = ClientSessionController(transport: transport)
        let outcome = try! await controller.connect(
            deviceName: "Laptop", target: .offeredHostScreen(preferredDisplayIdentity: "external-id")
        )
        expect(
            outcome == .hostScreen(geometry: geometry, resumeTicket: ticket, hostScreenOffer: [builtin, external]),
            "the offered screen connect reaches hostScreenReady on the same connection"
        )
        expect(
            await transport.sent.contains(.hostScreenRequest(token: external.opaqueToken, resumeTicket: nil)),
            "the remembered screen is the one requested when the fresh offer still has it"
        )
        expect(await controller.hostScreenDisplayIdentity == "external-id", "the chosen screen is readable afterwards")
        expect(await controller.hostOffersCanvas == false, "the host's own canvas availability is recorded")
        expect(await sentNoCanvasRequest(transport), "no canvas is ever asked for")
        print("PASS: the default start requests the remembered screen when the fresh offer still has it")
    }

    do {
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [builtin, external]),
            .hostScreenReady(geometry: geometry, resumeTicket: ticket)
        ])
        let controller = ClientSessionController(transport: transport)
        _ = try! await controller.connect(
            deviceName: "Laptop", target: .offeredHostScreen(preferredDisplayIdentity: "gone-id")
        )
        expect(
            await transport.sent.contains(.hostScreenRequest(token: builtin.opaqueToken, resumeTicket: nil)),
            "a remembered screen missing from the fresh offer starts the first offered one"
        )
        expect(await controller.hostScreenDisplayIdentity == "builtin-id", "and names that one as chosen")
        expect(await controller.hostOffersCanvas, "an offer without the field reads as canvas available")
        expect(await sentNoCanvasRequest(transport), "and never falls back to a canvas")
        print("PASS: a remembered screen missing from the offer starts the first offered screen, never a canvas")
    }

    do {
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [], canvasAvailable: false)
        ])
        let controller = ClientSessionController(transport: transport)
        do {
            _ = try await controller.connect(
                deviceName: "Laptop", target: .offeredHostScreen(preferredDisplayIdentity: nil)
            )
            expect(false, "an empty offer never becomes a session")
        } catch let ClientSessionError.hostScreenRefused(reason) {
            expect(
                reason == HostScreenRefusalCopy.noneAvailableReason,
                "an empty offer ends the connect with its own reason, got \(reason)"
            )
        } catch {
            expect(false, "an empty offer ends the connect as a host-screen refusal, got \(error)")
        }
        expect(await controller.hostOffersCanvas == false, "the host's lack of a canvas is recorded even on failure")
        expect(await sentNoCanvasRequest(transport), "an empty offer never falls back to a canvas")
        expect(
            HostScreenRefusalCopy.line(reason: HostScreenRefusalCopy.noneAvailableReason)
                == "This Mac has no screen available to share right now.",
            "and says so in the words the person reads"
        )
        print("PASS: no host screen and no canvas ends the start with the no-screen message")
    }

    do {
        // A refusal that arrives before any `hostScreenList` offer carries no
        // word on canvas availability at all -- unlike the empty-offer case
        // above, which is itself a `hostScreenList` naming `canvasAvailable`.
        // The viewer must not claim a canvas is offered on no evidence.
        let transport = ScriptedClientTransport(responses: [
            .hostScreenRefused(reason: "host-screen-not-allowed")
        ])
        let controller = ClientSessionController(transport: transport)
        do {
            _ = try await controller.connect(
                deviceName: "Laptop", target: .offeredHostScreen(preferredDisplayIdentity: nil)
            )
            expect(false, "a refusal never becomes a session")
        } catch ClientSessionError.hostScreenRefused {
            // Expected.
        } catch {
            expect(false, "a refusal ends the connect as a host-screen refusal, got \(error)")
        }
        expect(
            await controller.hostOffersCanvas == false,
            "an early refusal, before any offer named a canvas, is never read as one being available"
        )
        print("PASS: a refusal that arrives before any offer leaves canvas availability unclaimed")
    }

    do {
        // An unauthenticated canvas connect reads no offer at all before
        // sending `canvasRequest`, so a refusal on it teaches this attempt
        // nothing about canvas availability -- unlike the refusal cases
        // above, which do read an offer (or its absence) first. A caller
        // redialling on a failed attempt must be able to tell this apart
        // from a proven "no", so it never overwrites an earlier attempt's
        // proven answer with an attempt that learned nothing.
        let transport = ScriptedClientTransport(responses: [
            .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered, surfaceID: nil)
        ])
        let controller = ClientSessionController(transport: transport)
        do {
            _ = try await controller.connect(deviceName: "Laptop", target: .sessionCanvas)
            expect(false, "a refused canvas never becomes a session")
        } catch ClientSessionError.canvasRefused {
            // Expected.
        } catch {
            expect(false, "a refused canvas ends the connect as a canvas refusal, got \(error)")
        }
        expect(
            await controller.hostOffersCanvasIsKnown == false,
            "an unauthenticated connect that never read an offer learned nothing about canvas availability"
        )
        print("PASS: a canvas refusal with no offer read first leaves canvas availability unlearned")
    }

    do {
        let menu = ScreenMenuPlan.items(displays: [builtin], selectedToken: builtin.opaqueToken, canvasAvailable: false)
        expect(
            menu.map(\.title) == ["Built-in Display"],
            "the Screen menu hides Virtual Display when the host offers none, got \(menu.map(\.title))"
        )
        let startWith = ScreenMenuPlan.startWithMenu(
            preference: .hostScreenWhenOffered, offeredHostScreens: [builtin],
            isHostScreenSessionLive: false, canvasAvailable: false
        )
        expect(
            startWith.items.map(\.title) == ["Host Screen When Offered", "Built-in Display"],
            "and so does Start With, got \(startWith.items.map(\.title))"
        )
        print("PASS: the Screen menu hides the virtual display when the host offers none")
    }

    do {
        var machine = ViewerSessionStateMachine(hostName: "Mini")
        let withCanvas = machine.handle(.hostScreenConnectEnded(reasonLine: "x", offersVirtualDisplay: true))
        expect(
            withCanvas.buttons.contains { $0.action == .connectAsVirtualDisplay },
            "the ended panel offers a virtual display when the host has one"
        )
        let withoutCanvas = machine.handle(.hostScreenConnectEnded(reasonLine: "x", offersVirtualDisplay: false))
        expect(
            !withoutCanvas.buttons.contains { $0.action == .connectAsVirtualDisplay },
            "and does not when the host offers none"
        )
        expect(
            ViewerSessionStateMachine.buttonRows.contains(withoutCanvas.buttons.map(\.title)),
            "the new button row is one the panel is sized for"
        )
        print("PASS: the ended panel offers a virtual display only when the host has one")
    }

    do {
        let line = ViewerSessionFailureCopy.line(
            for: .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered), hostLabel: "Mini"
        )
        expect(!line.contains("canvas-not-offered"), "a canvas the host does not offer is said in words, got \(line)")
        let row = ViewerSessionFailureCopy.rowLine(
            for: .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered), hostLabel: "Mini"
        )
        expect(!row.contains("canvas-not-offered"), "on the row too, got \(row)")
        print("PASS: a host that does not offer a virtual display says so in words")
    }
}
