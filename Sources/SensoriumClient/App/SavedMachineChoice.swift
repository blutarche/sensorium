import Foundation
import SensoriumCore

/// Why one machine's session ended.
enum ViewerSessionExit {
    /// The person quit.
    case quit
    /// The launch window is taking the screen back: a row's own Cancel,
    /// another machine clicked, "Pair again", or "Your machines" from a session that
    /// had gone live.
    case backToList
}

/// Parks the launch flow until the person clicks a machine. A machine clicked while
/// another was still dialling is held rather than dropped: the window has
/// already asked for that attempt to stop, and this is what the next turn of
/// the loop picks up.
@MainActor
final class SavedMachineChoice {
    private var pending: SavedHost?
    private var waiting: CheckedContinuation<SavedHost?, Never>?
    private var isFinished = false

    func choose(_ host: SavedHost) {
        guard !isFinished else { return }
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: host)
        } else {
            pending = host
        }
    }

    /// Nothing more will be chosen -- the person quit.
    func finish() {
        isFinished = true
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: nil)
        }
    }

    /// The next machine to enter, or `nil` once there will not be one.
    func next() async -> SavedHost? {
        if isFinished { return nil }
        if let pending {
            self.pending = nil
            return pending
        }
        return await withCheckedContinuation { continuation in
            if isFinished {
                continuation.resume(returning: nil)
            } else {
                waiting = continuation
            }
        }
    }
}

