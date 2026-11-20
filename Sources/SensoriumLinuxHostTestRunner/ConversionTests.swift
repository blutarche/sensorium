#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// One solid 2x2 block of a test picture, as the BT.709 limited-range values
/// the viewer's own synthetic frame codes the same colour as.
private struct Swatch {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let luma: Int
    let blueChroma: Int
    let redChroma: Int
}

private let swatches: [Swatch] = [
    Swatch(blue: 0, green: 0, red: 0, luma: 16, blueChroma: 128, redChroma: 128),
    Swatch(blue: 255, green: 255, red: 255, luma: 235, blueChroma: 128, redChroma: 128),
    Swatch(blue: 0, green: 0, red: 255, luma: 63, blueChroma: 102, redChroma: 240),
    Swatch(blue: 0, green: 255, red: 0, luma: 173, blueChroma: 42, redChroma: 26),
    Swatch(blue: 255, green: 0, red: 0, luma: 32, blueChroma: 240, redChroma: 118),
    Swatch(blue: 128, green: 128, red: 128, luma: 126, blueChroma: 128, redChroma: 128)
]

private func near(_ actual: UInt8, _ expected: Int) -> Bool {
    abs(Int(actual) - expected) <= 2
}

func testBGRxConvertsToNV12WithPaddedRows() {
    // 70 wide is not a multiple of 64 or of 16, and each source row carries
    // 24 bytes of padding, so a converter that assumed tight rows reads the
    // wrong pixels from the second row on.
    let width = 70
    let height = 6
    let bytesPerRow = width * 4 + 24
    var pixels = Data(repeating: 0xAB, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let swatch = swatches[((x / 2) + (y / 2)) % swatches.count]
            let offset = y * bytesPerRow + x * 4
            pixels[offset] = swatch.blue
            pixels[offset + 1] = swatch.green
            pixels[offset + 2] = swatch.red
            // The fourth byte is padding or alpha and must not matter.
            pixels[offset + 3] = UInt8((x * 7 + y) & 0xFF)
        }
    }
    let chromaWidth = YUV420Converter.chromaWidth(forWidth: width)
    let chromaHeight = YUV420Converter.chromaHeight(forHeight: height)
    let lumaStride = width + 6
    let chromaStride = chromaWidth * 2 + 6
    var luma = [UInt8](repeating: 0, count: lumaStride * height)
    var chroma = [UInt8](repeating: 0, count: chromaStride * chromaHeight)
    pixels.withUnsafeBytes { source in
        luma.withUnsafeMutableBufferPointer { lumaPlane in
            chroma.withUnsafeMutableBufferPointer { chromaPlane in
                YUV420Converter.convert(
                    source: source.baseAddress!,
                    sourceBytesPerRow: bytesPerRow,
                    width: width,
                    height: height,
                    layout: .nv12,
                    luma: lumaPlane.baseAddress!,
                    lumaBytesPerRow: lumaStride,
                    chroma: chromaPlane.baseAddress!,
                    chromaBytesPerRow: chromaStride,
                    redChroma: nil,
                    redChromaBytesPerRow: 0
                )
            }
        }
    }
    for y in 0..<height {
        for x in 0..<width {
            let swatch = swatches[((x / 2) + (y / 2)) % swatches.count]
            expect(
                near(luma[y * lumaStride + x], swatch.luma),
                "luma at \(x),\(y) is \(luma[y * lumaStride + x]), expected about \(swatch.luma)"
            )
        }
    }
    for cy in 0..<chromaHeight {
        for cx in 0..<chromaWidth {
            let swatch = swatches[(cx + cy) % swatches.count]
            let blue = chroma[cy * chromaStride + cx * 2]
            let red = chroma[cy * chromaStride + cx * 2 + 1]
            expect(near(blue, swatch.blueChroma), "blue chroma at \(cx),\(cy) is \(blue), expected about \(swatch.blueChroma)")
            expect(near(red, swatch.redChroma), "red chroma at \(cx),\(cy) is \(red), expected about \(swatch.redChroma)")
        }
    }
}

func testBGRxConvertsToI420AndHandlesOddSizes() {
    // 5x3: the last column and row have no partner pixel and are repeated.
    let width = 5
    let height = 3
    var pixels = Data(count: width * height * 4)
    let swatch = swatches[2]
    for index in 0..<(width * height) {
        pixels[index * 4] = swatch.blue
        pixels[index * 4 + 1] = swatch.green
        pixels[index * 4 + 2] = swatch.red
    }
    let chromaWidth = YUV420Converter.chromaWidth(forWidth: width)
    let chromaHeight = YUV420Converter.chromaHeight(forHeight: height)
    expect(chromaWidth == 3 && chromaHeight == 2, "odd sizes round the chroma planes up")
    var luma = [UInt8](repeating: 0, count: width * height)
    var blue = [UInt8](repeating: 0, count: chromaWidth * chromaHeight)
    var red = [UInt8](repeating: 0, count: chromaWidth * chromaHeight)
    pixels.withUnsafeBytes { source in
        luma.withUnsafeMutableBufferPointer { lumaPlane in
            blue.withUnsafeMutableBufferPointer { bluePlane in
                red.withUnsafeMutableBufferPointer { redPlane in
                    YUV420Converter.convert(
                        source: source.baseAddress!,
                        sourceBytesPerRow: width * 4,
                        width: width,
                        height: height,
                        layout: .i420,
                        luma: lumaPlane.baseAddress!,
                        lumaBytesPerRow: width,
                        chroma: bluePlane.baseAddress!,
                        chromaBytesPerRow: chromaWidth,
                        redChroma: redPlane.baseAddress!,
                        redChromaBytesPerRow: chromaWidth
                    )
                }
            }
        }
    }
    expect(luma.allSatisfy { near($0, swatch.luma) }, "every luma sample of a solid picture is the same")
    expect(blue.allSatisfy { near($0, swatch.blueChroma) }, "every blue chroma sample, edges included")
    expect(red.allSatisfy { near($0, swatch.redChroma) }, "every red chroma sample, edges included")
}
#endif
