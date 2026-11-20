#if os(Linux)
import Foundation

/// Where the chroma samples of a converted picture go.
public enum YUV420Layout: Equatable, Sendable {
    /// One luma plane, then one plane of interleaved blue and red chroma.
    case nv12
    /// Three planes: luma, blue chroma, red chroma.
    case i420
}

/// Converts BGRx or BGRA pictures to 4:2:0 YCbCr, coded as the viewer reads
/// an unlabelled stream: BT.709, limited range (luma 16...235, chroma
/// 16...240).
public enum YUV420Converter {
    public static func chromaWidth(forWidth width: Int) -> Int { (width + 1) / 2 }
    public static func chromaHeight(forHeight height: Int) -> Int { (height + 1) / 2 }

    public static func convert(
        source: UnsafeRawPointer,
        sourceBytesPerRow: Int,
        width: Int,
        height: Int,
        layout: YUV420Layout,
        luma: UnsafeMutablePointer<UInt8>,
        lumaBytesPerRow: Int,
        chroma: UnsafeMutablePointer<UInt8>,
        chromaBytesPerRow: Int,
        redChroma: UnsafeMutablePointer<UInt8>?,
        redChromaBytesPerRow: Int
    ) {
        let rows = source.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let line = rows + y * sourceBytesPerRow
            let out = luma + y * lumaBytesPerRow
            for x in 0..<width {
                let p = line + x * 4
                out[x] = lumaSample(blue: Int(p[0]), green: Int(p[1]), red: Int(p[2]))
            }
        }
        let cw = chromaWidth(forWidth: width)
        let ch = chromaHeight(forHeight: height)
        for cy in 0..<ch {
            // An odd last row or column has no partner, so it is its own.
            let upper = rows + (cy * 2) * sourceBytesPerRow
            let lower = rows + min(cy * 2 + 1, height - 1) * sourceBytesPerRow
            for cx in 0..<cw {
                let left = (cx * 2) * 4
                let right = min(cx * 2 + 1, width - 1) * 4
                let a = upper + left, b = upper + right
                let c = lower + left, d = lower + right
                let blue = Int(a[0]) + Int(b[0]) + Int(c[0]) + Int(d[0])
                let green = Int(a[1]) + Int(b[1]) + Int(c[1]) + Int(d[1])
                let red = Int(a[2]) + Int(b[2]) + Int(c[2]) + Int(d[2])
                let cb = blueChroma(blueSum: blue, greenSum: green, redSum: red)
                let cr = redChromaSample(blueSum: blue, greenSum: green, redSum: red)
                switch layout {
                case .nv12:
                    let o = chroma + cy * chromaBytesPerRow + cx * 2
                    o[0] = cb
                    o[1] = cr
                case .i420:
                    chroma[cy * chromaBytesPerRow + cx] = cb
                    redChroma![cy * redChromaBytesPerRow + cx] = cr
                }
            }
        }
    }

    // BT.709 coefficients scaled by 256 and by the limited-range spans (219
    // luma, 224 chroma). The chroma rows each sum to zero, so any grey lands
    // exactly on 128. The chroma functions take sums of four pixels, hence
    // the shift by 10 rather than 8.
    @inline(__always)
    static func lumaSample(blue: Int, green: Int, red: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: ((47 * red + 157 * green + 16 * blue + 128) >> 8) + 16)
    }

    @inline(__always)
    static func blueChroma(blueSum: Int, greenSum: Int, redSum: Int) -> UInt8 {
        clamp(((-26 * redSum - 87 * greenSum + 113 * blueSum + 512) >> 10) + 128)
    }

    @inline(__always)
    static func redChromaSample(blueSum: Int, greenSum: Int, redSum: Int) -> UInt8 {
        clamp(((112 * redSum - 102 * greenSum - 10 * blueSum + 512) >> 10) + 128)
    }

    @inline(__always)
    private static func clamp(_ value: Int) -> UInt8 {
        UInt8(min(max(value, 16), 240))
    }
}
#endif
