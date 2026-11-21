#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// A BGRx picture whose pixel at (x, y) is `color(x, y)`, with `padding`
/// spare bytes at the end of every row.
private func picture(width: Int, height: Int, padding: Int = 0, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> (Data, Int) {
    let stride = width * 4 + padding
    var data = Data(repeating: 0xEE, count: stride * height)
    for y in 0..<height {
        for x in 0..<width {
            let (b, g, r) = color(x, y)
            data[y * stride + x * 4] = b
            data[y * stride + x * 4 + 1] = g
            data[y * stride + x * 4 + 2] = r
            data[y * stride + x * 4 + 3] = 0
        }
    }
    return (data, stride)
}

private func pixel(_ data: Data, stride: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
    (data[y * stride + x * 4], data[y * stride + x * 4 + 1], data[y * stride + x * 4 + 2])
}

private func testHalvingAveragesEachTwoByTwoBlock() {
    let (source, stride) = picture(width: 4, height: 2, padding: 12) { x, y in
        (UInt8(x * 40 + y * 10), UInt8(200 - x * 20), UInt8(y * 100))
    }
    let scaled = BGRxScaler.scale(pixels: source, width: 4, height: 2, bytesPerRow: stride, toWidth: 2, toHeight: 1)
    expect(scaled.width == 2 && scaled.height == 1, "the picture is the asked size")
    expect(scaled.bytesPerRow == 8, "the output rows are tightly packed")
    // Block (0,0): blue 0, 40, 10, 50 -> 25; green 200, 180, 200, 180 -> 190; red 0, 0, 100, 100 -> 50.
    let left = pixel(scaled.pixels, stride: 8, x: 0, y: 0)
    expect(left == (25, 190, 50), "the left pixel is its block's average, saw \(left)")
    let right = pixel(scaled.pixels, stride: 8, x: 1, y: 0)
    expect(right == (105, 150, 50), "the right pixel is its block's average, saw \(right)")
}

private func testTheSameSizeIsPassedThroughUntouched() {
    let (source, stride) = picture(width: 6, height: 4, padding: 8) { x, y in (UInt8(x), UInt8(y), 7) }
    let scaled = BGRxScaler.scale(pixels: source, width: 6, height: 4, bytesPerRow: stride, toWidth: 6, toHeight: 4)
    expect(scaled.pixels == source && scaled.bytesPerRow == stride, "nothing is copied when no scaling is needed")
}

private func testAFractionalScaleKeepsAFlatPictureFlatAndTheCornersInPlace() {
    let (flat, flatStride) = picture(width: 9, height: 6) { _, _ in (30, 60, 90) }
    let shrunk = BGRxScaler.scale(pixels: flat, width: 9, height: 6, bytesPerRow: flatStride, toWidth: 6, toHeight: 4)
    for y in 0..<4 {
        for x in 0..<6 {
            expect(pixel(shrunk.pixels, stride: shrunk.bytesPerRow, x: x, y: y) == (30, 60, 90), "a flat picture stays flat at (\(x), \(y))")
        }
    }
    let (marked, markedStride) = picture(width: 9, height: 6) { x, y in
        x == 8 && y == 5 ? (255, 255, 255) : (0, 0, 0)
    }
    let corner = BGRxScaler.scale(pixels: marked, width: 9, height: 6, bytesPerRow: markedStride, toWidth: 6, toHeight: 4)
    expect(pixel(corner.pixels, stride: corner.bytesPerRow, x: 5, y: 3).0 > 0, "the bottom-right source pixel lands in the bottom-right output pixel")
    expect(pixel(corner.pixels, stride: corner.bytesPerRow, x: 0, y: 0) == (0, 0, 0), "and nowhere near the top left")
}

func bgrxScalerTests() -> [(String, () throws -> Void)] { [
    ("halving averages each two by two block", testHalvingAveragesEachTwoByTwoBlock),
    ("the same size is passed through untouched", testTheSameSizeIsPassedThroughUntouched),
    ("a fractional scale keeps a flat picture flat and the corners in place", testAFractionalScaleKeepsAFlatPictureFlatAndTheCornersInPlace)
] }
#endif
