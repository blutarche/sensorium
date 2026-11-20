import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

typealias NamedTest = (String, () async -> Void)
