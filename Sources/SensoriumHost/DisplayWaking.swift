import Foundation

/// What a session needs from a platform's way of waking displays and keeping
/// them awake while a session is live. Nothing here changes a display's
/// arrangement, size or content.
@MainActor
public protocol DisplayWaking: AnyObject {
    var sleepingDisplayIDs: Set<UInt32> { get }
    var anyDisplayIsAsleep: Bool { get }

    @discardableResult
    func wakeDisplays(targets: Set<UInt32>) async -> Bool
    func wakeAndSettleDisplays() async
    @discardableResult
    func waitForDisplaysToWake(targets: Set<UInt32>) async -> Bool
    func beginRequestScope()
    func endRequestScope()
    func holdDisplaysAwake()
    func redeclareUserActivityForLiveSession()
    func releaseDisplaysAwake()
}

extension DisplayWaking {
    @discardableResult
    public func wakeDisplays() async -> Bool {
        await wakeDisplays(targets: [])
    }
}
