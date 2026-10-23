import CoreMedia
import CoreVideo
import Foundation

/// How much of each captured frame really changed, read from its pixels.
///
/// ScreenCaptureKit's dirty rects cannot answer this on a real display: they
/// can cover nearly the whole frame on every frame while nothing on the
/// screen moves. The frame is cut into tiles, and a sparse lattice of luma
/// samples in each is compared with the same samples of the previous frame. A
/// tile that differs at any sample counts as changed, so a caret or a small
/// animation changes a few tiles, and a scrolled page changes almost all of
/// the ones it covers.
///
/// Sampling is sparse, so a change narrower than the lattice spacing can be
/// missed. That only ever reads as less change, which is the safe side for the
/// one caller, `StreamMotionDetector`: a missed sliver does not blur a screen.
///
/// Safe to call from any thread, one frame at a time; the stream's capture
/// queue is the only caller.
package final class FrameChangeSampler: @unchecked Sendable {
    /// Side of a tile, in frame pixels.
    package static let tileSize = 32
    /// Samples along each side of a tile.
    package static let samplesPerTileSide = 4
    /// The most a sample's luma may move between frames and still count as
    /// the same, so encoder or display noise is not a change.
    package static let lumaTolerance = 2

    private let lock = NSLock()
    private var frameWidth = 0
    private var frameHeight = 0
    private var tilesAcross = 0
    private var tilesDown = 0
    private var columnOffsets: [Int] = []
    private var rowOffsets: [Int] = []
    private var previous: [UInt8] = []
    private var tileChanged: [UInt8] = []

    package init() {}

    /// The share of tiles that changed since the last frame, or
    /// `dirtyRectFraction()` when this frame has nothing to be compared with:
    /// the first one, one of another size, or one in a format whose luma this
    /// cannot read. `nil` there is capture's own "extent unknown".
    package func changedFraction(
        of pixelBuffer: CVPixelBuffer,
        dirtyRectFraction: @autoclosure () -> Double?
    ) -> Double? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == ScreenCaptureSession.capturePixelFormat,
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else {
            return dirtyRectFraction()
        }
        lock.lock()
        defer { lock.unlock() }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return dirtyRectFraction()
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let isComparable = width == frameWidth && height == frameHeight
        if !isComparable {
            resize(width: width, height: height)
        }
        let side = Self.samplesPerTileSide
        let samplesAcross = tilesAcross * side
        let tolerance = Self.lumaTolerance
        let tilesAcross = tilesAcross
        var changedTiles = 0
        columnOffsets.withUnsafeBufferPointer { columns in
            rowOffsets.withUnsafeBufferPointer { rows in
                previous.withUnsafeMutableBufferPointer { previous in
                    tileChanged.withUnsafeMutableBufferPointer { tileChanged in
                        tileChanged.update(repeating: 0)
                        for sampleRow in 0..<rows.count {
                            let row = luma + rows[sampleRow] * stride
                            let stored = previous.baseAddress! + sampleRow * samplesAcross
                            let flags = tileChanged.baseAddress! + (sampleRow / side) * tilesAcross
                            for tile in 0..<tilesAcross {
                                // Branch-free: a changing screen would make
                                // every compare a coin toss for the predictor.
                                var differs = 0
                                for offset in 0..<side {
                                    let column = tile * side + offset
                                    let value = row[columns[column]]
                                    differs |= abs(Int(value) - Int(stored[column])) > tolerance ? 1 : 0
                                    stored[column] = value
                                }
                                flags[tile] |= UInt8(truncatingIfNeeded: differs)
                            }
                        }
                        for flag in tileChanged {
                            changedTiles += Int(flag)
                        }
                    }
                }
            }
        }
        guard isComparable else {
            return dirtyRectFraction()
        }
        return Double(changedTiles) / Double(tilesAcross * tilesDown)
    }

    /// The same for a captured frame. One with no pixel buffer has no extent
    /// to report: `nil`.
    package func changedFraction(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        return changedFraction(
            of: imageBuffer,
            dirtyRectFraction: StreamMotionEncoder.changedFraction(of: sampleBuffer)
        )
    }

    /// Samples sit in the middle of each cell of the tile's lattice. A tile
    /// cut by the frame's edge reads its samples at the nearest pixel inside.
    private func resize(width: Int, height: Int) {
        let tile = Self.tileSize
        let side = Self.samplesPerTileSide
        let cell = tile / side
        frameWidth = width
        frameHeight = height
        tilesAcross = (width + tile - 1) / tile
        tilesDown = (height + tile - 1) / tile
        columnOffsets = (0..<(tilesAcross * side)).map { min(width - 1, ($0 / side) * tile + ($0 % side) * cell + cell / 2) }
        rowOffsets = (0..<(tilesDown * side)).map { min(height - 1, ($0 / side) * tile + ($0 % side) * cell + cell / 2) }
        previous = [UInt8](repeating: 0, count: tilesAcross * side * tilesDown * side)
        tileChanged = [UInt8](repeating: 0, count: tilesAcross * tilesDown)
    }
}
