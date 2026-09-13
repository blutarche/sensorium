import Foundation
import SensoriumCore

/// A number that only appears when it is bad is more useful than a permanent
/// dashboard, but a frozen good-looking number is a lie. This is the pure
/// logic that decides both: whether the last host-measured reading is still
/// current, and whether it (or its absence) is worth the user's attention.
/// AppKit presentation is thin glue behind this seam -- nothing here opens a
/// window, so it is verifiable without one.
public enum SurfaceTelemetryAvailability: Equatable, Sendable {
    /// No telemetry has ever arrived for this surface this session -- an old
    /// host, a session that has not streamed yet, or a surface this host
    /// never opened.
    case unavailable
    /// A reading exists and arrived within `TelemetryPolicy.staleAfterSeconds`.
    case fresh(SurfaceTelemetrySample)
    /// A reading exists but stopped arriving. Carries the last known sample
    /// so a caller can show what it was, labelled as stale, rather than
    /// nothing at all.
    case stale(SurfaceTelemetrySample)
}

public enum TelemetryAttentionThreshold {
    /// Two 60 Hz frame periods. The project's own measured baseline is
    /// single-digit milliseconds end-to-end; this is roughly 5x that, chosen
    /// to sit comfortably above ordinary jitter so the indicator does not
    /// light up on a healthy session, while still being well inside where a
    /// user would notice the session feels slow.
    public static let endToEndP50NanosecondsThreshold: Int64 = 33_000_000

    /// Whether this surface's current picture is worth drawing the user's
    /// eye to: a stale reading, any dropped frame since the last tick, or an
    /// end-to-end p50 over the threshold above.
    public static func isAttentionWorthy(
        availability: SurfaceTelemetryAvailability,
        clientEndToEndP50Nanoseconds: Int64?
    ) -> Bool {
        switch availability {
        case .unavailable:
            return false
        case .stale:
            return true
        case let .fresh(sample):
            let hasDrops = sample.encoderInputDropped > 0
                || sample.globalAdmissionDropped > 0
                || sample.sendQueueDropped > 0
            let hostBad = hostEndToEndFloorNanoseconds(sample).map { $0 > endToEndP50NanosecondsThreshold } ?? false
            let clientBad = clientEndToEndP50Nanoseconds.map { $0 > endToEndP50NanosecondsThreshold } ?? false
            return hasDrops || hostBad || clientBad
        }
    }

    /// The host never measures true end-to-end (it has no viewer clock), so
    /// its own capture+encode+send p50s summed is the closest lower bound it
    /// can offer toward the threshold above, used only when the viewer has
    /// not yet synchronised its clock and produced a real end-to-end sample.
    private static func hostEndToEndFloorNanoseconds(_ sample: SurfaceTelemetrySample) -> Int64? {
        let stages = [sample.capture, sample.encode, sample.send].compactMap { $0?.p50Nanoseconds }
        guard !stages.isEmpty else { return nil }
        return stages.reduce(0, +)
    }
}

/// Tracks the most recently received telemetry sample per surface and
/// decides freshness against the clock a caller supplies -- never `Date()`
/// or a wall clock read internally, so a test can drive time exactly like
/// every other seam in this codebase.
public struct SessionTelemetryTracker: Sendable {
    private struct Entry {
        let sample: SurfaceTelemetrySample
        let receivedAtNanoseconds: Int64
    }

    /// Fixed two slots, matching the `{0, 1}` surfaceID cap.
    private var entries: [Entry?] = [nil, nil]

    public init() {}

    /// Records one tick's samples. A surface absent from `surfaces` is left
    /// exactly as it was -- the host omits a surface with nothing to report,
    /// which must not be read as that surface going stale.
    public mutating func receive(surfaces: [SurfaceTelemetrySample], atNanoseconds now: Int64) {
        for sample in surfaces {
            guard let index = Self.index(for: sample.surfaceID) else { continue }
            entries[index] = Entry(sample: sample, receivedAtNanoseconds: now)
        }
    }

    public func availability(
        surfaceID: UInt32,
        nowNanoseconds: Int64,
        staleAfterSeconds: Double = TelemetryPolicy.staleAfterSeconds
    ) -> SurfaceTelemetryAvailability {
        guard let index = Self.index(for: surfaceID), let entry = entries[index] else {
            return .unavailable
        }
        let staleAfterNanoseconds = Int64(staleAfterSeconds * 1_000_000_000)
        guard nowNanoseconds - entry.receivedAtNanoseconds <= staleAfterNanoseconds else {
            return .stale(entry.sample)
        }
        return .fresh(entry.sample)
    }

    private static func index(for surfaceID: UInt32) -> Int? {
        surfaceID < 2 ? Int(surfaceID) : nil
    }
}
