#if canImport(AppKit)
import AppKit
import CoreVideo
import Foundation
import Metal
import MetalKit
import SensoriumClient
import SensoriumCore

/// The presenter draws decoded frames as a textured quad. These render one
/// frame of each format the pipeline can be handed, into an offscreen
/// texture, and read the result back: the colours are the evidence that the
/// letterbox is black, that a video range frame is expanded to full range,
/// and that the colour matrix the frame names is the one used.
@MainActor
func testMetalFramePresenterRenderTests() async {
    guard MTLCreateSystemDefaultDevice() != nil else {
        print("PASS: no Metal device available in this environment; frame rendering not exercised")
        return
    }
    await testRendersBGRAFrameWithBlackLetterbox()
    await testRendersVideoRangeBiplanarFrame()
    await testRendersOddSizedBiplanarFrame()
    await testGivesUpAFrameTheGPUCannotRead()
}

@MainActor
private func testRendersBGRAFrameWithBlackLetterbox() async {
    let device = MTLCreateSystemDefaultDevice()!
    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 40))
    guard let presenter = try? MetalFramePresenter(view: view) else {
        print("FAIL: could not construct MetalFramePresenter against a real Metal device")
        Foundation.exit(1)
    }
    // Source is square, target is twice as wide: bars down both sides.
    let buffer = makeFilledBGRAPixelBuffer(width: 32, height: 32, blue: 255, green: 0, red: 0)
    let target = makeReadableTexture(device: device, width: 64, height: 32)
    do {
        try presenter.render(buffer, into: target)
    } catch {
        print("FAIL: rendering a BGRA frame into an offscreen texture threw \(error)")
        Foundation.exit(1)
    }
    let pixels = readBack(texture: target, device: device)
    let center = pixels.pixel(x: 32, y: 16)
    let bar = pixels.pixel(x: 2, y: 16)
    expect(
        closeEnough(center, (red: 0, green: 0, blue: 255), tolerance: 2),
        "the frame itself is drawn in the middle, got r\(center.red) g\(center.green) b\(center.blue)"
    )
    expect(
        closeEnough(bar, (red: 0, green: 0, blue: 0), tolerance: 2),
        "and the side bars are black, got r\(bar.red) g\(bar.green) b\(bar.blue)"
    )
    print("PASS: MetalFramePresenter draws a BGRA frame aspect-fitted onto a black background")
}

@MainActor
private func testRendersVideoRangeBiplanarFrame() async {
    let device = MTLCreateSystemDefaultDevice()!
    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 40))
    guard let presenter = try? MetalFramePresenter(view: view) else {
        print("FAIL: could not construct MetalFramePresenter against a real Metal device")
        Foundation.exit(1)
    }
    // What the decoder hands over: a video range biplanar frame carrying the
    // colour matrix it was coded with.
    let cases: [(name: String, luma: UInt8, cb: UInt8, cr: UInt8, expected: (red: Int, green: Int, blue: Int))] = [
        ("black", 16, 128, 128, (red: 0, green: 0, blue: 0)),
        ("white", 235, 128, 128, (red: 255, green: 255, blue: 255)),
        ("red", 63, 102, 240, (red: 255, green: 0, blue: 0)),
    ]
    for testCase in cases {
        let buffer = makeFilledBiplanarPixelBuffer(
            width: 32,
            height: 32,
            luma: testCase.luma,
            cb: testCase.cb,
            cr: testCase.cr
        )
        let target = makeReadableTexture(device: device, width: 32, height: 32)
        do {
            try presenter.render(buffer, into: target)
        } catch {
            print("FAIL: rendering a video range biplanar frame threw \(error)")
            Foundation.exit(1)
        }
        let center = readBack(texture: target, device: device).pixel(x: 16, y: 16)
        expect(
            closeEnough(center, testCase.expected, tolerance: 10),
            "\(testCase.name) survives the shader's colour conversion, got"
                + " r\(center.red) g\(center.green) b\(center.blue),"
                + " wanted r\(testCase.expected.red) g\(testCase.expected.green) b\(testCase.expected.blue)"
        )
    }
    print("PASS: MetalFramePresenter converts video range biplanar frames with the matrix the frame names")
}

/// Chroma planes of a frame with an odd width or height are wider and taller
/// than half the frame, and the host is free to encode such a frame: a scale
/// applied to a width is rounded, never aligned to an even number. Reading the
/// plane's own size is what keeps the last column of colour from being dropped.
@MainActor
private func testRendersOddSizedBiplanarFrame() async {
    let device = MTLCreateSystemDefaultDevice()!
    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 40))
    guard let presenter = try? MetalFramePresenter(view: view) else {
        print("FAIL: could not construct MetalFramePresenter against a real Metal device")
        Foundation.exit(1)
    }
    let size = 33
    // Grey everywhere but the last column of chroma, which is strongly red.
    let buffer = makeFilledBiplanarPixelBuffer(width: size, height: size, luma: 126, cb: 128, cr: 128)
    expect(
        CVPixelBufferGetWidthOfPlane(buffer, 1) == 17 && CVPixelBufferGetHeightOfPlane(buffer, 1) == 17,
        "a 33 by 33 frame carries a 17 by 17 chroma plane, got"
            + " \(CVPixelBufferGetWidthOfPlane(buffer, 1)) by \(CVPixelBufferGetHeightOfPlane(buffer, 1))"
    )
    CVPixelBufferLockBaseAddress(buffer, [])
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let lastColumn = CVPixelBufferGetWidthOfPlane(buffer, 1) - 1
    for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        chroma[y * chromaBytesPerRow + lastColumn * 2 + 1] = 240
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let target = makeReadableTexture(device: device, width: size, height: size)
    do {
        try presenter.render(buffer, into: target)
    } catch {
        print("FAIL: rendering a 33 by 33 biplanar frame threw \(error)")
        Foundation.exit(1)
    }
    let edge = readBack(texture: target, device: device).pixel(x: size - 1, y: size / 2)
    expect(
        edge.red > edge.green + 40 && edge.red > edge.blue + 40,
        "the last column of chroma reaches the last column of the picture, got"
            + " r\(edge.red) g\(edge.green) b\(edge.blue)"
    )
    print("PASS: MetalFramePresenter reads each plane at the size the plane has, odd frame sizes included")
}

/// A frame the GPU cannot read at all is given up like any other frame this
/// viewer skips, rather than being retried on every refresh from then on.
@MainActor
private func testGivesUpAFrameTheGPUCannotRead() async {
    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 40))
    let drops = ViewerFrameDropCounter()
    guard let presenter = try? MetalFramePresenter(view: view, drops: drops) else {
        print("FAIL: could not construct MetalFramePresenter against a real Metal device")
        Foundation.exit(1)
    }
    let recorder = PresentedFrameRecorder()
    presenter.onFramePresented = { timing, presentedAtNanoseconds in
        recorder.record(capturedAt: timing.hostCapturedAtNanoseconds, presentedAt: presentedAtNanoseconds)
    }
    // No IOSurface behind it, so it can never become a texture.
    var unreadable: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &unreadable)
    guard let unreadable else {
        print("FAIL: could not allocate a frame with no IOSurface behind it")
        Foundation.exit(1)
    }
    presenter.present(DecodedFrame(pixelBuffer: unreadable))
    presenter.draw(in: view)
    expect(
        drops.droppedBeforePresent == 1,
        "the frame that could not be drawn is counted as given up, got \(drops.droppedBeforePresent)"
    )
    presenter.draw(in: view)
    presenter.draw(in: view)
    expect(
        drops.droppedBeforePresent == 1,
        "and it is given up once rather than retried on every refresh after it, got \(drops.droppedBeforePresent)"
    )

    let captured = MonotonicClock.nowNanoseconds()
    presenter.present(makePresentableFrame(capturedAtNanoseconds: captured))
    let deadline = MonotonicClock.nowNanoseconds() + 2_000_000_000
    while recorder.presented.isEmpty, MonotonicClock.nowNanoseconds() < deadline {
        presenter.draw(in: view)
        try? await Task.sleep(for: .milliseconds(2))
    }
    expect(
        recorder.presented.map(\.capturedAt) == [captured],
        "and the frame after it still reaches the screen, got \(recorder.presented.map(\.capturedAt))"
    )
    print("PASS: MetalFramePresenter gives up a frame the GPU cannot read and draws the next one")
}

private func makePresentableFrame(capturedAtNanoseconds: Int64) -> DecodedFrame {
    DecodedFrame(
        pixelBuffer: makeFilledBGRAPixelBuffer(width: 16, height: 16, blue: 10, green: 20, red: 30),
        timing: FrameTiming(
            hostCapturedAtNanoseconds: capturedAtNanoseconds,
            receivedAtNanoseconds: capturedAtNanoseconds,
            decodedAtNanoseconds: capturedAtNanoseconds
        )
    )
}

private typealias RenderedPixel = (red: Int, green: Int, blue: Int)

private func closeEnough(_ pixel: RenderedPixel, _ expected: RenderedPixel, tolerance: Int) -> Bool {
    abs(pixel.red - expected.red) <= tolerance
        && abs(pixel.green - expected.green) <= tolerance
        && abs(pixel.blue - expected.blue) <= tolerance
}

private struct RenderedImage {
    let bytes: [UInt8]
    let width: Int

    /// The texture is BGRA, so the bytes of one pixel arrive blue first.
    func pixel(x: Int, y: Int) -> RenderedPixel {
        let offset = (y * width + x) * 4
        return (red: Int(bytes[offset + 2]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset]))
    }
}

private func readBack(texture: MTLTexture, device: MTLDevice) -> RenderedImage {
    guard let queue = device.makeCommandQueue(),
          let commandBuffer = queue.makeCommandBuffer(),
          let blit = commandBuffer.makeBlitCommandEncoder() else {
        print("FAIL: could not read the rendered texture back")
        Foundation.exit(1)
    }
    blit.synchronize(resource: texture)
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        texture.getBytes(
            raw.baseAddress!,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
    }
    return RenderedImage(bytes: bytes, width: texture.width)
}

private func makeReadableTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .managed
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        print("FAIL: could not allocate an offscreen render target")
        Foundation.exit(1)
    }
    return texture
}

private func makeFilledBGRAPixelBuffer(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        print("FAIL: could not allocate a BGRA test frame")
        Foundation.exit(1)
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        print("FAIL: could not fill a BGRA test frame")
        Foundation.exit(1)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let rows = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            rows[offset] = blue
            rows[offset + 1] = green
            rows[offset + 2] = red
            rows[offset + 3] = 255
        }
    }
    return buffer
}

private func makeFilledBiplanarPixelBuffer(
    width: Int,
    height: Int,
    luma: UInt8,
    cb: UInt8,
    cr: UInt8
) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        print("FAIL: could not allocate a biplanar test frame")
        Foundation.exit(1)
    }
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
        print("FAIL: could not fill a biplanar test frame")
        Foundation.exit(1)
    }
    let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let lumaRows = lumaPlane.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            lumaRows[y * lumaBytesPerRow + x] = luma
        }
    }
    let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let chromaRows = chromaPlane.assumingMemoryBound(to: UInt8.self)
    for y in 0..<(height / 2) {
        for x in 0..<(width / 2) {
            chromaRows[y * chromaBytesPerRow + x * 2] = cb
            chromaRows[y * chromaBytesPerRow + x * 2 + 1] = cr
        }
    }
    return buffer
}
#endif
