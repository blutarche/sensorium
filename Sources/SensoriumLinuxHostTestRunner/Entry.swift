#if os(Linux)

@main
struct SensoriumLinuxHostTestRunner {
    static func main() async {
        let tests: [NamedTest] = keyMapTests() + restoreTokenStoreTests() + portalSessionTests() + geometryTests() + inputInjectorTests() + screenSaverTests()

        for (name, test) in tests {
            await test()
            print("PASS: \(name)")
        }

        print("PASS: \(tests.count) tests")
    }
}

#else

/// The host's portal, capture and input code exists only on Linux. This keeps
/// a whole-package build on other platforms linking.
@main
struct SensoriumLinuxHostTestRunner {
    static func main() {
        print("SensoriumLinuxHostTestRunner runs only on Linux")
    }
}

#endif
