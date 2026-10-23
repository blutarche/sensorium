import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A luma picture that becomes a captured frame: a plain-text-like page of
/// lines of small blocks, edited by rectangle, in the pixel format capture
/// delivers.
struct NV12TestImage {
    let width: Int
    let height: Int
    private(set) var luma: [UInt8]

    /// A uniform picture of `background` luma.
    init(width: Int, height: Int, background: UInt8 = 128) {
        self.width = width
        self.height = height
        luma = [UInt8](repeating: background, count: width * height)
    }

    /// Lines of text-like blocks inside `rect`, `lineHeight` rows each, with
    /// the page scrolled up by `scrolledBy` rows. Which blocks are dark is a
    /// fixed function of the line and the column, so the same page shifted by
    /// a few rows differs from itself almost everywhere.
    mutating func drawText(in rect: CGRect, scrolledBy: Int = 0, lineHeight: Int = 10, blockWidth: Int = 6) {
        let area = clipped(rect)
        guard !area.isEmpty else { return }
        var cachedLine = -1
        var cachedRow: [UInt8] = []
        for row in area.minY..<area.maxY {
            let line = (row - area.minY + scrolledBy) / lineHeight
            if line != cachedLine {
                cachedLine = line
                cachedRow = (area.minX..<area.maxX).map { column in
                    Self.isDark(line: line, block: column / blockWidth) ? 30 : 235
                }
            }
            luma.replaceSubrange(row * width + area.minX..<row * width + area.maxX, with: cachedRow)
        }
    }

    mutating func fill(_ rect: CGRect, with value: UInt8) {
        let area = clipped(rect)
        guard !area.isEmpty else { return }
        for row in area.minY..<area.maxY {
            for column in area.minX..<area.maxX {
                luma[row * width + column] = value
            }
        }
    }

    mutating func offset(_ rect: CGRect, by delta: Int) {
        let area = clipped(rect)
        guard !area.isEmpty else { return }
        for row in area.minY..<area.maxY {
            for column in area.minX..<area.maxX {
                let index = row * width + column
                luma[index] = UInt8(clamping: Int(luma[index]) + delta)
            }
        }
    }

    private func clipped(_ rect: CGRect) -> (minX: Int, maxX: Int, minY: Int, maxY: Int, isEmpty: Bool) {
        let minX = max(0, Int(rect.minX))
        let maxX = min(width, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(height, Int(rect.maxY))
        return (minX, maxX, minY, maxY, minX >= maxX || minY >= maxY)
    }

    private static func isDark(line: Int, block: Int) -> Bool {
        var state = UInt64(truncatingIfNeeded: line) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: block) &* 0xBF58_476D_1CE4_E5B9
        state ^= state >> 31
        state = state &* 0x94D0_49BB_1331_11EB
        state ^= state >> 29
        return state & 1 == 1
    }

    func makePixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        luma.withUnsafeBufferPointer { source in
            for row in 0..<height {
                memcpy(lumaBase + row * lumaStride, source.baseAddress! + row * width, width)
            }
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chromaBase, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// The frame as ScreenCaptureKit delivers it: dirty rects that cover the
    /// whole frame whatever changed, as they do on a real display.
    func makeCapturedFrame(presentationNanoseconds: Int64) -> CMSampleBuffer {
        let pixelBuffer = makePixelBuffer()
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: presentationNanoseconds, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        let frame = sampleBuffer!
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let wholeFrame = CGRect(x: 0, y: 0, width: width, height: height)
            let rects = [wholeFrame.dictionaryRepresentation] as CFArray
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(SCStreamFrameInfo.dirtyRects.rawValue as NSString).toOpaque(),
                Unmanaged.passUnretained(rects).toOpaque()
            )
        }
        return frame
    }
}
