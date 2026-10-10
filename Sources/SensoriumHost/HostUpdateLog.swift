import Foundation
import os
import SensoriumUpdate

/// Where each update step is recorded. A host opened by LaunchServices has
/// nowhere for standard output to go, so every line also goes to the unified
/// log, under subsystem `com.sensorium.host`, category `update`.
///
/// Lines name versions, steps and local files, never a network address or a
/// key, which is what lets them be logged as public.
public enum HostUpdateLog {
    private static let logger = Logger(subsystem: "com.sensorium.host", category: "update")

    public static func record(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        print("Sensorium host update: \(line)")
    }

    public static func describe(_ result: UpdateCheckResult) -> String {
        switch result {
        case .upToDate:
            "update check: up to date"
        case .unreachable:
            "update check: the release page could not be reached"
        case let .failed(failure):
            "update check failed: \(describe(failure))"
        case let .available(offer):
            "update check: Sensorium Host \(offer.version) is available"
        case let .givenUp(offer, reason):
            "update check: Sensorium Host \(offer.version) was given up on: \(reason)"
        }
    }

    public static func describeStage(_ result: Result<StagedUpdate, UpdateFailure>, version: UpdateVersion) -> String {
        switch result {
        case .success:
            "staged Sensorium Host \(version)"
        case let .failure(failure):
            "could not stage Sensorium Host \(version): \(describe(failure))"
        }
    }

    public static func describe(_ outcome: UpdateHandoffOutcome) -> String {
        switch outcome {
        case let .notUpdatable(reason):
            "not installing: this copy of the app cannot be replaced (\(reason))"
        case .handedOff:
            "the new version reported ready; quitting"
        case let .failed(failure):
            "the install failed before the new version started: \(describe(failure))"
        case let .rolledBack(failure):
            "the new version was refused (\(describe(failure))); rolled back to this version, which reported ready; quitting"
        case let .rollbackRelaunchFailed(failure):
            "UPDATE FAILED: the new version was refused (\(describe(failure))) and the restored copy of this version "
                + "did not report ready; this process is not listening"
        case let .swapBackFailed(failure):
            "UPDATE FAILED: the new version was refused (\(describe(failure))) and the previous version could not be "
                + "put back; the refused version is installed and this process is not listening"
        }
    }

    /// The failure's case and the plain reason the window shows for it.
    public static func describe(_ failure: UpdateFailure) -> String {
        "\(failure), \(failure.kind.rawValue): \(failure.reason)"
    }
}
