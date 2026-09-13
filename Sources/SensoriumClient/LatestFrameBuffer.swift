public actor LatestFrameBuffer<Frame: Sendable> {
    private var newest: Frame?

    public init() {}

    public func push(_ frame: Frame) {
        newest = frame
    }

    public func takeNewest() -> Frame? {
        defer { newest = nil }
        return newest
    }
}
