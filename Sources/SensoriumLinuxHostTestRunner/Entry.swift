import Foundation

/// Checks for the Linux host's own code. The host is Linux only, so on any
/// other platform this runner has nothing to run.
@main
struct SensoriumLinuxHostTestRunner {
    static func main() {
        #if os(Linux)
        let tests: [(String, () -> Void)] = [
            ("BGRx converts to NV12 across padded rows", testBGRxConvertsToNV12WithPaddedRows),
            ("BGRx converts to I420 and odd sizes repeat their edge", testBGRxConvertsToI420AndHandlesOddSizes),
            ("Annex B is reframed length prefixed without parameter sets", testAnnexBIsReframedAsLengthPrefixedWithoutParameterSets),
            ("a non-IDR slice carries no key flag or parameter sets", testAnnexBNonIDRSliceCarriesNoKeyFlagOrParameterSets)
        ]
        for (name, test) in tests {
            test()
            print("PASS: \(name)")
        }
        print("PASS: \(tests.count) tests")
        #else
        print("SKIP: the Linux host's checks run on Linux only")
        #endif
    }
}
