import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SensoriumCore
import SensoriumHost

enum SyntheticFrameSourceError: Error {
    case pixelBufferPoolUnavailable(CVReturn)
    case drawingContextUnavailable
}

/// A repeatable stand-in for a desktop full of small text: dense,
/// high-contrast rectangles in rows, under a colour gradient band. Drawn once
/// per resolution into an image that is then shifted for each frame.
private enum SyntheticDesktopPattern {
    private struct Generator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func next(below bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw SyntheticFrameSourceError.drawingContextUnavailable
        }
        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let bandHeight = max(height / 24, 16)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.18, green: 0.38, blue: 0.92, alpha: 1),
                CGColor(red: 0.94, green: 0.32, blue: 0.62, alpha: 1)
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: height - bandHeight, width: width, height: bandHeight))
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: width, y: 0),
                options: []
            )
            context.restoreGState()
        }

        var random = Generator()
        let lineHeight = 20
        let margin = 28
        var rowTop = bandHeight + 16
        while rowTop + lineHeight < height - 16 {
            var x = margin
            while x < width - margin {
                let glyphCount = 2 + random.next(below: 8)
                let tint = random.next(below: 9)
                if tint == 0 {
                    context.setFillColor(CGColor(red: 0.75, green: 0.1, blue: 0.1, alpha: 1))
                } else if tint == 1 {
                    context.setFillColor(CGColor(red: 0.1, green: 0.25, blue: 0.75, alpha: 1))
                } else {
                    context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1))
                }
                for _ in 0..<glyphCount where x < width - margin {
                    let glyphWidth = 4 + random.next(below: 4)
                    let glyphHeight = 8 + random.next(below: 6)
                    context.fill(CGRect(
                        x: x,
                        y: height - rowTop - glyphHeight,
                        width: glyphWidth,
                        height: glyphHeight
                    ))
                    x += glyphWidth + 1
                }
                x += 8
            }
            rowTop += lineHeight
        }
        guard let image = context.makeImage() else {
            throw SyntheticFrameSourceError.drawingContextUnavailable
        }
        return image
    }
}

/// Delivers synthetic desktop frames into the pipeline the way
/// ScreenCaptureKit would: a frame only when the picture changed, nothing
/// while it is still. The picture changes when the pointer position the
/// viewer sent changes, as if the pointer were dragging the whole desktop.
///
/// Touches no capture API: frames are drawn by CoreGraphics into
/// IOSurface-backed pixel buffers this process allocates.
@MainActor
final class SyntheticDesktopFrameSource: HostFrameSource {
    private let engine: Engine

    init(
        configuration: VideoEncoderConfiguration,
        pointer: BenchPointer,
        deliveryHandler: @escaping @Sendable (ScreenCaptureDelivery) -> Void,
        frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws {
        engine = try Engine(
            width: configuration.captureWidth,
            height: configuration.captureHeight,
            framesPerSecond: configuration.framesPerSecond,
            pointer: pointer,
            deliveryHandler: deliveryHandler,
            frameHandler: frameHandler
        )
    }

    func start() async throws {
        engine.start()
    }

    func stop() async throws {
        await engine.stop()
    }

    func apply(framesPerSecond: Int) async throws {
        engine.apply(framesPerSecond: framesPerSecond)
    }

    /// Everything here runs on `queue`, one tick at a time, so a frame is never
    /// delivered after `stop` has returned.
    private final class Engine: @unchecked Sendable {
        private let width: Int
        private let height: Int
        private let pointer: BenchPointer
        private let deliveryHandler: @Sendable (ScreenCaptureDelivery) -> Void
        private let frameHandler: @Sendable (CMSampleBuffer) -> Void
        private let pattern: CGImage
        private let pool: CVPixelBufferPool
        private let queue = DispatchQueue(label: "com.sensorium.bench-host-frames", qos: .userInteractive)
        private var framesPerSecond: Int
        private var timer: DispatchSourceTimer?
        private var formatDescription: CMVideoFormatDescription?
        private var lastDeliveredOffset: (x: Int, y: Int)?

        init(
            width: Int,
            height: Int,
            framesPerSecond: Int,
            pointer: BenchPointer,
            deliveryHandler: @escaping @Sendable (ScreenCaptureDelivery) -> Void,
            frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void
        ) throws {
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.pointer = pointer
            self.deliveryHandler = deliveryHandler
            self.frameHandler = frameHandler
            pattern = try SyntheticDesktopPattern.makeImage(width: width, height: height)
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else {
                throw SyntheticFrameSourceError.pixelBufferPoolUnavailable(status)
            }
            pool = created
        }

        func start() {
            queue.async { [self] in
                scheduleTimer()
            }
        }

        func apply(framesPerSecond: Int) {
            queue.async { [self] in
                self.framesPerSecond = framesPerSecond
                guard timer != nil else { return }
                scheduleTimer()
            }
        }

        func stop() async {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    timer?.cancel()
                    timer = nil
                    continuation.resume()
                }
            }
        }

        private func scheduleTimer() {
            timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(1_000_000_000 / max(framesPerSecond, 1)),
                leeway: .microseconds(200)
            )
            timer.setEventHandler { [self] in
                tick()
            }
            self.timer = timer
            timer.resume()
        }

        private func tick() {
            let position = pointer.position
            let offset = (x: Self.wrapped(position.x, within: width), y: Self.wrapped(position.y, within: height))
            if let last = lastDeliveredOffset, last == offset {
                return
            }
            guard let pixelBuffer = render(offsetX: offset.x, offsetY: offset.y),
                  let sampleBuffer = makeSampleBuffer(pixelBuffer) else {
                return
            }
            lastDeliveredOffset = offset
            deliveryHandler(.screenChange)
            frameHandler(sampleBuffer)
        }

        private static func wrapped(_ value: Double, within extent: Int) -> Int {
            guard value.isFinite else { return 0 }
            let whole = Int(value.rounded(.down)) % extent
            return whole < 0 ? whole + extent : whole
        }

        private func render(offsetX: Int, offsetY: Int) -> CVPixelBuffer? {
            var created: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
                  let pixelBuffer = created else {
                return nil
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                return nil
            }
            for tileX in [offsetX - width, offsetX] {
                for tileY in [offsetY - height, offsetY] {
                    context.draw(pattern, in: CGRect(x: tileX, y: tileY, width: width, height: height))
                }
            }
            return pixelBuffer
        }

        private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
            if formatDescription == nil {
                var description: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: pixelBuffer,
                    formatDescriptionOut: &description
                ) == noErr else {
                    return nil
                }
                formatDescription = description
            }
            guard let formatDescription else { return nil }
            // The monotonic clock in nanoseconds is the timebase the latency
            // recorder pairs a capture with its encoded frame by.
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1))),
                presentationTimeStamp: CMTime(value: MonotonicClock.nowNanoseconds(), timescale: 1_000_000_000),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ) == noErr else {
                return nil
            }
            return sampleBuffer
        }
    }
}
