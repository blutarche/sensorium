import Foundation
#if os(Linux)
import SensoriumLinuxHost
#endif

/// Checks for the Linux host's own code. The host is Linux only, so on any
/// other platform this runner has nothing to run.
@main
struct SensoriumLinuxHostTestRunner {
    @MainActor
    static func main() async {
        #if os(Linux)
        let tests: [(String, () throws -> Void)] = [
            ("BGRx converts to NV12 across padded rows", testBGRxConvertsToNV12WithPaddedRows),
            ("BGRx converts to I420 and odd sizes repeat their edge", testBGRxConvertsToI420AndHandlesOddSizes),
            ("Annex B is reframed length prefixed without parameter sets", testAnnexBIsReframedAsLengthPrefixedWithoutParameterSets),
            ("a non-IDR slice carries no key flag or parameter sets", testAnnexBNonIDRSliceCarriesNoKeyFlagOrParameterSets),
            ("every frame gets one outcome and the first is a key frame with parameter sets", testEveryFrameGetsOneOutcomeAndTheFirstIsAKeyFrameWithParameterSets),
            ("the profile follows the viewer preference", testProfileFollowsTheViewerPreference),
            ("a requested key frame lands on the next frame only", testARequestedKeyFrameLandsOnTheNextFrameOnly),
            ("a key frame follows when the interval passes in presentation time", testAKeyFrameFollowsWhenTheIntervalPassesInPresentationTime),
            ("there are no B-frames, so presentation order is output order", testThereAreNoBFramesSoPresentationOrderIsOutputOrder),
            ("a refused frame keeps the key frame request", testAnEncodeThatCannotProceedFailsWithoutLosingAKeyFrameRequest),
            ("bit rate and configuration follow the macOS rule", testBitRateAndConfigurationFollowTheMacOSRule),
            ("automatic falls back to OpenH264 when the render node cannot open", testAutomaticFallsBackToOpenH264WhenTheRenderNodeCannotOpen),
            ("a second of stream stays near the bit rate budget", testASecondOfStreamStaysNearTheBitRateBudget),
            ("the viewer's decoder opens the stream and the luma matches", testTheViewersDecoderOpensTheStreamAndTheLumaMatches),
            ("a VA-API stream decodes in the viewer as constrained baseline", testVAAPIStreamDecodesInTheViewerWithConstrainedBaseline),
            ("VA-API latency at 2560x1440", testVAAPILatencyAt1440p)
        ]
        var skipped = 0
        for (name, test) in tests {
            do {
                try test()
            } catch let skip as TestSkipped {
                skipped += 1
                print("SKIP: \(name) (\(skip.reason))")
                continue
            } catch {
                print("FAIL: \(name) threw \(error)")
                exit(1)
            }
            print("PASS: \(name)")
        }
        // Checks that drive the indicator's main-actor state run after the
        // synchronous ones; each fails the run itself through `expect`.
        let mainActorTests: [(String, () async -> Void)] = IndicatorTests.all + TrayTests.all + ShowTests.all
            + keyMapTests() + restoreTokenStoreTests() + portalSessionTests() + geometryTests()
            + inputInjectorTests() + screenSaverTests() + gvariantBridgeTests()
        for (name, test) in mainActorTests {
            await test()
            print("PASS: \(name)")
        }
        let passed = tests.count - skipped + mainActorTests.count
        print("PASS: \(passed) tests, \(skipped) skipped")
        #else
        print("SKIP: the Linux host's checks run on Linux only")
        #endif
    }
}
