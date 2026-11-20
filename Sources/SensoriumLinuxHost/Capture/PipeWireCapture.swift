#if os(Linux)

import CSensoriumPipeWireGlue
import Foundation

/// A PipeWire video stream read from the remote the portal handed over. The
/// stream runs on a PipeWire thread loop of its own, so frames and state
/// changes arrive on that thread, never the caller's.
public final class PipeWireCapture: @unchecked Sendable {
    private final class Callbacks {
        let onFrame: @Sendable (CapturedFrame) -> Void
        let onState: @Sendable (CaptureState) -> Void

        init(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onState: @escaping @Sendable (CaptureState) -> Void) {
            self.onFrame = onFrame
            self.onState = onState
        }
    }

    private let callbacks: Callbacks
    private let lock = NSLock()
    private var handle: OpaquePointer?

    /// Takes ownership of `descriptor`, closing it on failure and when the
    /// capture is stopped. Nothing is delivered until `start()`.
    public init(
        descriptor: Int32,
        stream: PortalStream,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) throws {
        callbacks = Callbacks(onFrame: onFrame, onState: onState)
        var message = [CChar](repeating: 0, count: 256)
        let context = Unmanaged.passUnretained(callbacks).toOpaque()
        guard let created = sensorium_pw_capture_create(
            descriptor,
            stream.nodeID,
            stream.pipeWireSerial ?? 0,
            { context, frame in
                guard let context, let frame else { return }
                let callbacks = Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue()
                callbacks.onFrame(PipeWireCapture.capturedFrame(from: frame))
            },
            { context, state, message in
                guard let context else { return }
                let callbacks = Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue()
                switch state {
                case SENSORIUM_PW_STATE_STREAMING: callbacks.onState(.streaming)
                case SENSORIUM_PW_STATE_PAUSED: callbacks.onState(.paused)
                case SENSORIUM_PW_STATE_ERROR:
                    callbacks.onState(.failed(message.map { String(cString: $0) } ?? "the stream failed"))
                default: callbacks.onState(.connecting)
                }
            },
            context,
            &message,
            message.count
        ) else {
            throw CaptureError.couldNotCreate(String(cString: message))
        }
        handle = created
    }

    deinit {
        stop()
    }

    public func start() throws {
        try lock.withLock {
            guard let handle else { return }
            let result = sensorium_pw_capture_start(handle)
            if result < 0 {
                throw CaptureError.couldNotStart(errno: -result)
            }
        }
    }

    /// Stops the stream and closes the PipeWire connection. When this returns
    /// no callback is running or will run. Safe to call again.
    public func stop() {
        let taken = lock.withLock {
            defer { handle = nil }
            return handle
        }
        if let taken {
            sensorium_pw_capture_destroy(taken)
        }
    }

    /// The entry point for importing DMA-BUF frames into the encoder, which
    /// is not built: capture reads shared memory.
    public func enableDMABufImport() throws {
        throw CaptureError.dmaBufNotImplemented
    }

    /// Copies one buffer out of PipeWire's memory. The pointers in `frame`
    /// are valid only for the call.
    public static func capturedFrame(from frame: UnsafePointer<sensorium_pw_frame>) -> CapturedFrame {
        let source = frame.pointee
        var pixels: Data?
        if let base = source.pixels, source.stride > 0, source.height > 0 {
            pixels = Data(bytes: base, count: Int(source.stride) * Int(source.height))
        }
        var cursor: CapturedCursor?
        if source.has_cursor {
            var image: CapturedCursor.Image?
            if let bitmap = source.cursor_bitmap, source.cursor_stride > 0, source.cursor_height > 0,
               let format = pixelFormat(source.cursor_format) {
                image = CapturedCursor.Image(
                    width: Int(source.cursor_width),
                    height: Int(source.cursor_height),
                    stride: Int(source.cursor_stride),
                    format: format,
                    pixels: Data(bytes: bitmap, count: Int(source.cursor_stride) * Int(source.cursor_height))
                )
            }
            cursor = CapturedCursor(
                x: Int(source.cursor_x),
                y: Int(source.cursor_y),
                hotspotX: Int(source.cursor_hotspot_x),
                hotspotY: Int(source.cursor_hotspot_y),
                isVisible: source.cursor_visible,
                image: image
            )
        }
        return CapturedFrame(
            pixels: pixels,
            width: Int(source.width),
            height: Int(source.height),
            stride: Int(source.stride),
            format: pixelFormat(source.format) ?? .bgrx,
            presentationTimeNanoseconds: source.presentation_time_ns == 0 ? nil : source.presentation_time_ns,
            cursor: cursor
        )
    }

    private static func pixelFormat(_ format: sensorium_pw_format) -> CapturePixelFormat? {
        switch format {
        case SENSORIUM_PW_FORMAT_BGRX: .bgrx
        case SENSORIUM_PW_FORMAT_BGRA: .bgra
        default: nil
        }
    }
}

#endif
