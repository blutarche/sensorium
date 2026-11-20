import Foundation
#if os(Linux)
import SensoriumLinuxHost
#endif

/// Fails the run with `message` when `condition` is false.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

/// The Linux host's own checks. Everything it covers is Linux-only, so on any
/// other platform this builds to a runner that reports nothing to run.
@main
struct SensoriumLinuxHostTestRunner {
    @MainActor
    static func main() async {
        #if os(Linux)
        let tests: [(String, () async -> Void)] = IndicatorTests.all + TrayTests.all + ShowTests.all

        for (name, test) in tests {
            await test()
            print("PASS: \(name)")
        }

        print("PASS: \(tests.count) tests")
        #else
        print("SKIP: the Linux host's checks run on Linux only")
        #endif
    }
}
