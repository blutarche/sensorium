#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumLinuxHost

/// Collects an encoder's outcomes from whichever thread reports them.
final class OutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LinuxVideoEncodeOutcome] = []

    func append(_ outcome: LinuxVideoEncodeOutcome) {
        lock.lock()
        stored.append(outcome)
        lock.unlock()
    }

    var outcomes: [LinuxVideoEncodeOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var packets: [EncodedVideoFramePacket] {
        outcomes.compactMap {
            if case let .encoded(packet) = $0 { return packet }
            return nil
        }
    }
}

/// A gradient with a bright block that moves a little every frame, so each
/// frame differs from the last and the encoder has real inter prediction to
/// do. `bytesPerRow` is padded past `width * 4`, as a capture buffer is.
func syntheticFrame(
    index: Int,
    width: Int,
    height: Int,
    timeNanoseconds: UInt64? = nil
) -> LinuxVideoFrame {
    let bytesPerRow = width * 4 + 32
    var pixels = Data(count: bytesPerRow * height)
    pixels.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let inBlock = abs(x - (20 + index * 3) % width) < 12 && abs(y - height / 2) < 12
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = inBlock ? 240 : UInt8((x * 255) / max(width - 1, 1))
                bytes[offset + 1] = inBlock ? 240 : UInt8((y * 255) / max(height - 1, 1))
                bytes[offset + 2] = inBlock ? 240 : 90
                bytes[offset + 3] = 0xFF
            }
        }
    }
    return LinuxVideoFrame(
        width: width,
        height: height,
        pixelFormat: .bgrx,
        bytesPerRow: bytesPerRow,
        pixels: pixels,
        presentationTimeNanoseconds: timeNanoseconds ?? UInt64(index) * 16_666_667
    )
}
#endif
