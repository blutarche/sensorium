public enum CaptureSelectionError: Error, Equatable {
    case noActiveSessionCanvas
    case physicalDisplayCaptureRejected
}

public enum CaptureSelectionGuard {
    public static func validate(
        requestedDisplayID: UInt32,
        ownedHandle: VirtualDisplayHandle?
    ) throws -> VirtualDisplayHandle {
        guard let ownedHandle else {
            throw CaptureSelectionError.noActiveSessionCanvas
        }
        guard requestedDisplayID == ownedHandle.rawValue else {
            throw CaptureSelectionError.physicalDisplayCaptureRejected
        }
        return ownedHandle
    }
}
