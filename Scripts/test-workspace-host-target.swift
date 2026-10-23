import Foundation

@main
struct HostTargetChecks {
    static func main() throws {
        let titles = [1: "Sensorium Workspace", 3: "Unrelated Window"]
        let tree = [1: [2], 3: [4]]
        var valuesRead: [Int] = []
        let observed = WorkspaceTextObservation.read(
            windows: [1, 3], title: { titles[$0] }, isEditor: { [2, 4].contains($0) },
            children: { tree[$0] ?? [] }, value: { valuesRead.append($0); return "fixture text" }
        )
        precondition(observed == "fixture text" && valuesRead == [2], "only the exact workspace editor's value may be read")
        precondition(WorkspaceTextObservation.read(windows: [3], title: { titles[$0] }, isEditor: { _ in true },
            children: { _ in [] }, value: { _ in "wrong" }) == nil, "a different window cannot satisfy the observation")
        precondition(WorkspaceTextObservation.read(windows: [1], title: { titles[$0] }, isEditor: { [2, 4].contains($0) },
            children: { $0 == 1 ? [2, 4] : [] }, value: { _ in "ambiguous" }) == nil,
            "ambiguous editors fail closed")
        precondition(!WorkspaceTextObservation.changed(before: "same", after: "same", sentinel: "probe"))
        precondition(WorkspaceTextObservation.changed(before: "before", after: "beforeprobe", sentinel: "probe"))
        precondition(!WorkspaceTextObservation.changed(before: "before", after: "other text", sentinel: "probe"),
                     "an unrelated edit cannot satisfy injected sentinel observation")
        precondition(!WorkspaceTextObservation.changed(before: "probe", after: "probe ", sentinel: "probe"),
                     "a stale preexisting sentinel cannot satisfy delivery")
        print("PASS: workspace text observation reads only the exact window's unique editor and requires a changed value")
        let root = URL(fileURLWithPath: "/private/tmp/sensorium-target-fixture")
        let packaged = root.appendingPathComponent("Artifacts/Sensorium/Sensorium Host.app/Contents/MacOS/SensoriumHost").path
        let raw = root.appendingPathComponent(".build/arm64-apple-macosx/release/sensoriumd").path
        let installed = "/Applications/Sensorium Host.app/Contents/MacOS/SensoriumHost"
        var lookups: [Int32] = []
        func resolve(_ environment: [String: String], actual: String?) throws -> HostWorkspaceActivationTarget {
            try HostWorkspaceActivationTarget.resolve(environment: environment, repositoryRoot: root) { pid in
                lookups.append(pid)
                return actual
            }
        }
        func rejects(_ environment: [String: String], actual: String?) {
            do {
                _ = try resolve(environment, actual: actual)
                print("FAIL: an absent, wrong or installed host target was accepted")
                exit(1)
            } catch {}
        }
        rejects([:], actual: installed)
        rejects(["SENSORIUM_TEST_HOST_PID": "0", "SENSORIUM_TEST_HOST_EXECUTABLE": packaged], actual: packaged)
        rejects(["SENSORIUM_TEST_HOST_PID": "123", "SENSORIUM_TEST_HOST_EXECUTABLE": installed], actual: installed)
        rejects(["SENSORIUM_TEST_HOST_PID": "123", "SENSORIUM_TEST_HOST_EXECUTABLE": packaged], actual: installed)
        rejects(["SENSORIUM_TEST_HOST_PID": "123", "SENSORIUM_TEST_HOST_EXECUTABLE": packaged], actual: nil)
        rejects(["SENSORIUM_TEST_HOST_PID": "123", "SENSORIUM_TEST_HOST_EXECUTABLE": raw], actual: packaged)
        lookups = []
        let target = try resolve(["SENSORIUM_TEST_HOST_PID": "456", "SENSORIUM_TEST_HOST_EXECUTABLE": packaged], actual: packaged)
        precondition(target.processIdentifier == 456 && lookups == [456], "only the explicitly requested test PID may be looked up")
        let rawTarget = try resolve(["SENSORIUM_TEST_HOST_PID": "789", "SENSORIUM_TEST_HOST_EXECUTABLE": raw], actual: raw)
        precondition(rawTarget.processIdentifier == 789 && rawTarget.executableURL.path == raw)
        print("PASS: workspace activation refuses missing, stale, mismatched and installed targets; selects only the exact repository test PID")
    }
}
