import Foundation
import FoundationNetworking
import Glibc
import Dispatch

enum LinuxUpdateReleaseLocation {
    static let timeout: TimeInterval = 5
    static let smallFileDeadline: TimeInterval = 1
    static let archiveDeadline: TimeInterval = 3
    static let userAgent = "Sensorium-Update/1"
}
enum LinuxUpdateTransportError: Error { case failed(String), badStatus(Int), tooLarge }
protocol LinuxUpdateTransport: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data
    func download(_ url: URL, to: URL, maximumBytes: Int64) async throws
}

// The test driver appends the production transport here, then the test body.
