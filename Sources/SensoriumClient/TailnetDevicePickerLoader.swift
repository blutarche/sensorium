import Foundation
import SensoriumCore

/// Turns one `TailnetStatusProviding` fetch into a `TailnetDevicePickerState`.
/// The only place those two meet: the window calls `load()` and draws
/// whatever state comes back, never touching the provider or the parser
/// itself.
///
/// A `TailnetDirectoryError` -- the bytes were read, but were not a status
/// document -- is `.malformedStatus`. `LocalTailscaleStatusProviderError
/// .tailscaleNotFound` -- no candidate path exists at all -- is
/// `.tailscaleNotInstalled`; every other failure to fetch (a binary that
/// exists but will not launch or run) is `.tailscaledUnreachable`. None of
/// them carries the thrown error's own text forward: only
/// `TailnetDevicePickerFetchError.reason`'s words do.
@MainActor
public final class TailnetDevicePickerLoader {
    private let provider: any TailnetStatusProviding

    public init(provider: any TailnetStatusProviding) {
        self.provider = provider
    }

    public func load() async -> TailnetDevicePickerState {
        do {
            let json = try await provider.statusJSON()
            let snapshot = try TailnetDirectory.parse(statusJSON: json)
            return .from(.success(snapshot))
        } catch is TailnetDirectoryError {
            return .from(.failure(.malformedStatus))
        } catch LocalTailscaleStatusProviderError.tailscaleNotFound {
            return .from(.failure(.tailscaleNotInstalled))
        } catch {
            return .from(.failure(.tailscaledUnreachable))
        }
    }
}
