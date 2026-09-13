import Foundation

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        Foundation.exit(1)
    }
}
