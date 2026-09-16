import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import VideoToolbox

@MainActor
func testTailnetDevicePickerTests() async {
    // The row's own formatting: never reimplements presentationOrder (that
    // is TailnetDirectory's own, already tested), only what a chosen peer
    // reads like on screen.
    do {
        let online = TailnetPeer(
            id: "1", displayName: "Studio", magicDNSName: "mini.tail1234.ts.net",
            tailnetIPv4: "100.64.1.2", tailnetIPv6: nil, isOnline: true, isThisMachine: false
        )
        let onlineRow = TailnetDevicePickerRow(peer: online)
        expect(
            onlineRow.title == "Studio" && onlineRow.subtitle == "mini.tail1234.ts.net",
            "an online device shows its name and MagicDNS name with no extra note"
        )

        let offline = TailnetPeer(
            id: "2", displayName: "iPhone", magicDNSName: nil,
            tailnetIPv4: "100.64.1.3", tailnetIPv6: nil, isOnline: false, isThisMachine: false
        )
        let offlineRow = TailnetDevicePickerRow(peer: offline)
        expect(
            offlineRow.subtitle == "100.64.1.3 \u{2014} offline",
            "an offline device falls back to its IPv4 address and says so, got: \(offlineRow.subtitle)"
        )

        print("PASS: a device-picker row shows a peer's name and address, and names an offline device as such")
    }

    // TailnetDevicePickerState.from(_:): the fetch outcome decides the
    // state, never a window -- verified without one.
    do {
        let onePeer = TailnetPeer(
            id: "1", displayName: "Studio", magicDNSName: nil,
            tailnetIPv4: "100.64.1.2", tailnetIPv6: nil, isOnline: true, isThisMachine: false
        )
        let onlySelf = TailnetPeer(
            id: "self", displayName: "This Laptop", magicDNSName: nil,
            tailnetIPv4: "100.64.1.1", tailnetIPv6: nil, isOnline: true, isThisMachine: true
        )

        let withPeer = TailnetDevicePickerState.from(
            .success(TailnetDirectorySnapshot(peers: [onlySelf, onePeer], droppedPeerCount: 0))
        )
        guard case let .devices(rows) = withPeer, rows.map(\.peer.id) == ["1"] else {
            print("FAIL: a snapshot with one other peer becomes .devices, excluding this machine, got: \(withPeer)")
            Foundation.exit(1)
        }

        let onlySelfState = TailnetDevicePickerState.from(
            .success(TailnetDirectorySnapshot(peers: [onlySelf], droppedPeerCount: 0))
        )
        expect(
            onlySelfState == .noOtherDevices,
            "a tailnet with only this machine on it is .noOtherDevices, not an empty device list"
        )

        let emptyState = TailnetDevicePickerState.from(
            .success(TailnetDirectorySnapshot(peers: [], droppedPeerCount: 0))
        )
        expect(emptyState == .noOtherDevices, "a genuinely empty tailnet is .noOtherDevices too")

        let unreachable = TailnetDevicePickerState.from(.failure(.tailscaledUnreachable))
        guard case let .unreachable(reason) = unreachable else {
            print("FAIL: a fetch failure becomes .unreachable, got: \(unreachable)")
            Foundation.exit(1)
        }
        expect(
            reason.contains("Tailscale") && reason.hasSuffix(".") && !reason.contains("tailscaledUnreachable"),
            "the reason is a sentence for the person choosing a machine, not the case name, got: \(reason)"
        )
        expect(
            reason.hasSuffix("then choose Look again."),
            "the one button this screen shows reads \u{201C}Look again\u{201D}, not \u{201C}Try again\u{201D}, "
                + "and the sentence names it as a button -- got: \(reason)"
        )
        expect(
            TailnetDevicePickerFetchError.tailscaledUnreachable.reason
                == "Tailscale doesn\u{2019}t seem to be running on this machine. Make sure Tailscale says "
                    + "Connected, then choose Look again.",
            "this reason draws regardless of whether the Tailscale app was found -- it must not name an "
                + "action (\u{201C}Open the Tailscale app\u{201D}) that only one of those two draws a button "
                + "for -- got: \(TailnetDevicePickerFetchError.tailscaledUnreachable.reason)"
        )

        expect(
            TailnetDevicePickerFetchError.tailscaleNotInstalled.reason
                == "Tailscale doesn\u{2019}t seem to be installed on this machine. Install Tailscale and sign in, "
                    + "then choose Look again.",
            "the not-installed reason says install, never \u{201C}open the Tailscale app,\u{201D} since there is "
                + "no app on this machine to open -- got: \(TailnetDevicePickerFetchError.tailscaleNotInstalled.reason)"
        )

        expect(
            TailnetDevicePickerState.loading.showsActivityDot,
            "the loading line's dot pulses while the fetch is in flight"
        )
        expect(
            !unreachable.showsActivityDot && !onlySelfState.showsActivityDot && !withPeer.showsActivityDot,
            "every settled state -- unreachable, no other devices, or a device list -- holds the dot still"
        )

        print("PASS: the device-picker state is decided from one fetch result -- loading, unreachable, empty, or a device list -- without a window")
    }

    // TailnetDevicePickerLoader: the seam between a provider and the state
    // above. Every case here runs against FixtureTailnetStatusProvider --
    // nothing here ever calls the real tailscaled or its CLI.
    do {
        let goodJSON = Data("""
        {"Self":{"ID":"self","HostName":"This Laptop","TailscaleIPs":["100.64.1.1"],"Online":true},
         "Peer":{"a":{"ID":"1","HostName":"Studio","TailscaleIPs":["100.64.1.2"],"Online":true}}}
        """.utf8)
        let goodLoader = TailnetDevicePickerLoader(provider: FixtureTailnetStatusProvider(json: goodJSON))
        guard case let .devices(rows) = await goodLoader.load(), rows.map(\.title) == ["Studio"] else {
            print("FAIL: a good fixture status loads to the one non-self device")
            Foundation.exit(1)
        }

        let malformedLoader = TailnetDevicePickerLoader(
            provider: FixtureTailnetStatusProvider(json: Data("not json".utf8))
        )
        guard case let .unreachable(reason) = await malformedLoader.load(), reason.contains("could not read") else {
            print("FAIL: bytes that are not a status document at all read as unreachable with the malformed-status reason")
            Foundation.exit(1)
        }

        struct NotInstalledProvider: TailnetStatusProviding {
            func statusJSON() async throws -> Data { throw LocalTailscaleStatusProviderError.tailscaleNotFound }
        }
        guard case let .unreachable(reason) = await TailnetDevicePickerLoader(provider: NotInstalledProvider()).load(),
              reason.contains("Tailscale doesn\u{2019}t seem to be installed") else {
            print("FAIL: no candidate path existing reads as unreachable with the not-installed reason, "
                + "distinct from tailscaled simply not running")
            Foundation.exit(1)
        }

        struct NotRunningProvider: TailnetStatusProviding {
            func statusJSON() async throws -> Data { throw LocalTailscaleStatusProviderError.processFailed(exitCode: 1) }
        }
        guard case let .unreachable(reason) = await TailnetDevicePickerLoader(provider: NotRunningProvider()).load(),
              reason.contains("Tailscale doesn\u{2019}t seem to be running") else {
            print("FAIL: a binary that exists but fails to answer reads as unreachable with the tailscaled reason")
            Foundation.exit(1)
        }

        print("PASS: the device-picker loader turns a fixture provider's fetch into every state the window can show, never touching a real socket")
    }

    // LocalTailscaleStatusProvider itself is never run here (it would call
    // the real tailscale binary); only its candidate-path list is checked,
    // since that list is what determines whether this machine's install is even
    // considered.
    do {
        expect(
            LocalTailscaleStatusProvider.candidateExecutablePaths.contains("/opt/homebrew/bin/tailscale")
                && LocalTailscaleStatusProvider.candidateExecutablePaths.contains("/usr/local/bin/tailscale"),
            "both common Homebrew install prefixes are tried, since which one is on this machine isn't known in advance"
        )
        let provider = LocalTailscaleStatusProvider(executablePaths: ["/definitely/not/a/real/path/tailscale"])
        do {
            _ = try await provider.statusJSON()
            print("FAIL: a provider given only a nonexistent path should refuse rather than run something")
            Foundation.exit(1)
        } catch LocalTailscaleStatusProviderError.tailscaleNotFound {
        } catch {
            print("FAIL: wrong error for a nonexistent executable path: \(error)")
            Foundation.exit(1)
        }

        print("PASS: the live provider refuses cleanly when none of its candidate paths exist, without ever launching a process")
    }
}
