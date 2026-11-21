#if os(Linux)
import Foundation

/// Resizes a 32-bit BGRx picture to the size the encoder takes.
///
/// A host screen is encoded at its logical size, as on macOS, while the
/// portal's buffers carry its pixels: a 2x monitor arrives at twice the
/// encode size on each axis. Each output pixel is the average of the source
/// pixels it covers, which is exact for whole-number ratios and keeps text
/// legible at fractional ones. The fourth byte is written as zero.
public enum BGRxScaler {
    public struct Scaled: Sendable {
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public let pixels: Data
    }

    public static func scale(
        pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        toWidth: Int,
        toHeight: Int
    ) -> Scaled {
        if width == toWidth, height == toHeight {
            return Scaled(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
        }
        let outputStride = toWidth * 4
        guard width > 0, height > 0, toWidth > 0, toHeight > 0,
              pixels.count >= bytesPerRow * (height - 1) + width * 4 else {
            return Scaled(width: toWidth, height: toHeight, bytesPerRow: outputStride, pixels: Data(count: outputStride * max(toHeight, 0)))
        }
        let columns = spans(source: width, output: toWidth)
        let rows = spans(source: height, output: toHeight)
        var output = Data(count: outputStride * toHeight)
        pixels.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                let input = source.bindMemory(to: UInt8.self)
                let out = destination.bindMemory(to: UInt8.self)
                for outputY in 0..<toHeight {
                    let rowSpan = rows[outputY]
                    for outputX in 0..<toWidth {
                        let columnSpan = columns[outputX]
                        var blue = 0
                        var green = 0
                        var red = 0
                        for sourceY in rowSpan.lowerBound..<rowSpan.upperBound {
                            var offset = sourceY * bytesPerRow + columnSpan.lowerBound * 4
                            for _ in columnSpan.lowerBound..<columnSpan.upperBound {
                                blue += Int(input[offset])
                                green += Int(input[offset + 1])
                                red += Int(input[offset + 2])
                                offset += 4
                            }
                        }
                        let count = rowSpan.count * columnSpan.count
                        let half = count / 2
                        let target = outputY * outputStride + outputX * 4
                        out[target] = UInt8((blue + half) / count)
                        out[target + 1] = UInt8((green + half) / count)
                        out[target + 2] = UInt8((red + half) / count)
                        out[target + 3] = 0
                    }
                }
            }
        }
        return Scaled(width: toWidth, height: toHeight, bytesPerRow: outputStride, pixels: output)
    }

    /// The source pixels each output pixel covers along one axis. Never
    /// empty: an output larger than its source repeats source pixels.
    private static func spans(source: Int, output: Int) -> [Range<Int>] {
        (0..<output).map { index in
            let start = min(index * source / output, source - 1)
            let end = max(start + 1, min((index + 1) * source / output, source))
            return start..<end
        }
    }
}
#endif
