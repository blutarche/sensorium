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
    private let installHint: String

    /// `installHint` is the sentence the not-installed state ends on, which
    /// only the platform can write -- see `TailnetDevicePickerFetchError`.
    public init(
        provider: any TailnetStatusProviding,
        installHint: String = TailnetDevicePickerFetchError.defaultInstallHint
    ) {
        self.provider = provider
        self.installHint = installHint
    }

    public func load() async -> TailnetDevicePickerState {
        do {
            let json = try await provider.statusJSON()
            let snapshot = try TailnetDirectory.parse(statusJSON: json)
            return .from(.success(snapshot), installHint: installHint)
        } catch is TailnetDirectoryError {
            return .from(.failure(.malformedStatus), installHint: installHint)
        } catch LocalTailscaleStatusProviderError.tailscaleNotFound {
            return .from(.failure(.tailscaleNotInstalled), installHint: installHint)
        } catch {
            return .from(.failure(.tailscaledUnreachable), installHint: installHint)
        }
    }
}
