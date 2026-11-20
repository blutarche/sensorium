import Foundation

@main
struct SensoriumLinuxHostTestRunner {
    static func main() async {
        if let code = await InteropModes.run(Array(CommandLine.arguments.dropFirst())) {
            exit(code)
        }
        #if os(Linux)
        let tests: [(String, () async throws -> Void)] = [
            ("a Linux host identity mints, stores and loads", testIdentityMintsStoresAndLoads),
            ("a client and the server exchange packets both ways", testClientAndServerExchangePacketsBothWays),
            ("large packets cross both ways and a client close ends the channel", testLargePacketsCrossBothWaysAndAClientCloseEndsTheChannel),
            ("a client with the wrong pin is refused", testAClientWithTheWrongPinIsRefused),
            ("a client offering another protocol is refused", testAClientOfferingAnotherProtocolIsRefused),
            ("the server asks for a thirty second idle timeout", testTheServerAsksForAThirtySecondIdleTimeout)
        ]
        for (name, test) in tests {
            print("RUN: \(name)")
            do {
                try await test()
                print("PASS: \(name)")
            } catch {
                print("FAIL: \(name): \(error)")
                exit(1)
            }
        }
        print("PASS: \(tests.count) tests")
        #else
        print("SKIP: the Linux host's QUIC server runs on Linux only")
        #endif
    }
}
