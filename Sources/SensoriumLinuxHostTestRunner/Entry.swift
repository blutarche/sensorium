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
        if let code = await InteropModes.run(Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
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
            ("the encoder continues the session's shared sequence", testTheEncoderContinuesTheSessionsSharedSequence),
            ("a refused frame keeps the key frame request", testAnEncodeThatCannotProceedFailsWithoutLosingAKeyFrameRequest),
            ("bit rate and configuration follow the macOS rule", testBitRateAndConfigurationFollowTheMacOSRule),
            ("automatic falls back to OpenH264 when the render node cannot open", testAutomaticFallsBackToOpenH264WhenTheRenderNodeCannotOpen),
            ("a second of stream stays near the bit rate budget", testASecondOfStreamStaysNearTheBitRateBudget),
            ("the viewer's decoder opens the stream and the luma matches", testTheViewersDecoderOpensTheStreamAndTheLumaMatches),
            ("a VA-API stream decodes in the viewer as constrained baseline", testVAAPIStreamDecodesInTheViewerWithConstrainedBaseline),
            ("VA-API latency at 2560x1440", testVAAPILatencyAt1440p)
        ] + screenSaverAdapterTests()
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
            + inputInjectorTests() + screenSaverTests() + gvariantBridgeTests() + portalInputFactoryTests()
            + indicatorBadgeTests() + portalCapturePermissionTests()
            + HostWindowStatusTests.all + HostWindowPairingTests.all + HostWindowMachinesTests.all + AskFirstPromptTests.all
        for (name, test) in mainActorTests {
            await test()
            print("PASS: \(name)")
        }
        let transportTests: [(String, () async throws -> Void)] = [
            ("a Linux host identity mints, stores and loads", testIdentityMintsStoresAndLoads),
            ("a client and the server exchange packets both ways", testClientAndServerExchangePacketsBothWays),
            ("large packets cross both ways and a client close ends the channel", testLargePacketsCrossBothWaysAndAClientCloseEndsTheChannel),
            ("a client with the wrong pin is refused", testAClientWithTheWrongPinIsRefused),
            ("a client offering another protocol is refused", testAClientOfferingAnotherProtocolIsRefused),
            ("the server asks for a thirty second idle timeout", testTheServerAsksForAThirtySecondIdleTimeout),
            ("the server channel carries a host session's bytes", testTheServerChannelCarriesAHostSessionsBytes)
        ]
        for (name, test) in transportTests {
            do {
                try await test()
            } catch {
                print("FAIL: \(name): \(error)")
                exit(1)
            }
            print("PASS: \(name)")
        }
        let passed = tests.count - skipped + mainActorTests.count + transportTests.count
        print("PASS: \(passed) tests, \(skipped) skipped")
        #else
        print("SKIP: the Linux host's checks run on Linux only")
        #endif
    }
}
