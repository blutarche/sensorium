#if canImport(Metal)
import AppKit
import CoreVideo
import Metal
import MetalKit
import SensoriumCore
import simd

extension MetalFramePresenter: CanvasFramePresenting {}

/// Draws one surface's decoded frames onto its Metal view, on the screen's own
/// refresh and at the pace `PresentationPacer` decides.
///
/// The screen asks for a picture on every refresh, and each of those asks takes
/// the newest frame that is due. A refresh with nothing due draws nothing at
/// all, which both leaves the last picture on screen and spends no GPU time
/// re-encoding a picture that has not changed.
///
/// A frame reaches the screen as one textured quad: the decoded pixel buffer is
/// wrapped as a Metal texture without a copy, and any colour conversion happens
/// in the fragment shader. The letterbox is the clear colour of the render
/// pass rather than a picture drawn underneath.
@MainActor
public final class MetalFramePresenter: NSObject, MTKViewDelegate {
    private let view: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let textureCache: CVMetalTextureCache
    private let sampler: MTLSamplerState
    /// Built on first use and kept: one per combination of destination format
    /// and source layout, of which a session uses exactly one.
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    /// Frames superseded while they waited for their turn on screen. Counted
    /// in the same place as every other frame this viewer gave up.
    private let drops: ViewerFrameDropCounter?
    private var pacer = PresentationPacer()
    private var latestFrame: CVPixelBuffer?
    private var latestTiming: FrameTiming?
    /// When the frame in `latestFrame` was due on screen, which is what its
    /// completion sample is measured from.
    private var dueAtNanoseconds: Int64?
    /// Whether `latestFrame` is a picture no draw has put on screen yet.
    private var hasUndrawnFrame = false
    /// A frame the GPU refused to take leaves the screen blank, which is worth
    /// one line in the log and not one line per refresh.
    private var hasReportedRenderFailure = false
    /// Called on the main actor with each frame this presenter really drew and
    /// the moment it drew it. A frame superseded while it waited never reaches
    /// this, so what the session measures as presented is what a person
    /// actually saw.
    public var onFramePresented: ((FrameTiming, Int64) -> Void)?
    /// How long a frame takes from the moment it was due on screen to the GPU
    /// signalling its drawable is genuinely there. Measured from the due time
    /// rather than from `present(_:)`, so the hold this viewer adds on purpose
    /// is reported as the hold and never as the GPU being slow. Bounded the
    /// same way every other stage's `LatencySamples` is.
    public private(set) var completionLatency = LatencySamples()

    public init(
        view: MTKView,
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        drops: ViewerFrameDropCounter? = nil
    ) throws {
        guard let device, let commandQueue = device.makeCommandQueue() else {
            throw MetalFramePresenterError.deviceUnavailable
        }
        self.view = view
        self.device = device
        self.commandQueue = commandQueue
        self.drops = drops
        // The package has no compiled Metal library: the command line tools
        // carry no shader compiler, so the shaders are compiled here from
        // source, once per presenter.
        library = try device.makeLibrary(source: MetalFramePresenter.shaderSource, options: nil)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw MetalFramePresenterError.textureCacheUnavailable
        }
        textureCache = cache
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalFramePresenterError.samplerUnavailable
        }
        self.sampler = sampler
        super.init()
        view.device = device
        view.framebufferOnly = true
        view.delegate = self
        // The view runs its own display link rather than being told to redraw
        // by each arriving frame: which frame belongs on this refresh is a
        // decision the pacer makes on the refresh itself.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        updatePreferredFramesPerSecond()
    }

    /// How far past its capture time each frame is currently being held, for
    /// the session panel to show.
    public var holdNanoseconds: Int64 {
        pacer.holdNanoseconds
    }

    /// Takes one decoded frame and returns. Nothing is drawn here: the frame
    /// waits until the refresh its due time falls on.
    public func present(_ frame: DecodedFrame) {
        // Admitted first and counted second: an optional chain skips its own
        // argument, so a presenter with no counter attached would admit
        // nothing at all.
        let superseded = pacer.admit(frame, nowNanoseconds: MonotonicClock.nowNanoseconds())
        drops?.recordDroppedBeforePresent(superseded)
        updatePreferredFramesPerSecond()
    }

    /// Gives up every frame still waiting and forgets what this session taught
    /// the pacer about the link. The picture already on screen stays: a session
    /// that ended leaves what a person was looking at in front of them.
    public func discardPendingFrames() {
        pacer.reset()
    }

    /// Draws one frame into a texture of the caller's choosing and returns once
    /// the GPU has finished, which is what makes the drawing path measurable
    /// and testable away from a screen. The refresh path does the same work
    /// without waiting.
    public func render(_ pixelBuffer: CVPixelBuffer, into texture: MTLTexture) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalFramePresenterError.commandBufferUnavailable
        }
        guard try encodeFrame(pixelBuffer, into: texture, commandBuffer: commandBuffer) else {
            return
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    public func draw(in view: MTKView) {
        let now = MonotonicClock.nowNanoseconds()
        if let due = pacer.frameToPresent(nowNanoseconds: now) {
            drops?.recordDroppedBeforePresent(due.supersededCount)
            latestFrame = due.frame.pixelBuffer
            latestTiming = due.frame.timing
            dueAtNanoseconds = due.dueAtNanoseconds
            hasUndrawnFrame = true
        }
        // Nothing new is due, so the drawable already holds the right picture.
        // The frame is kept rather than released for the same reason: a
        // session that has stopped decoding is deliberately showing its last
        // picture, and the drawables rotate underneath it.
        guard hasUndrawnFrame,
              let pixelBuffer = latestFrame,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        let dueAt = dueAtNanoseconds
        do {
            guard try encodeFrame(pixelBuffer, into: drawable.texture, commandBuffer: commandBuffer) else {
                return
            }
        } catch {
            reportRenderFailure(error)
            // Given up rather than kept: a frame the GPU refused once it will
            // refuse on every refresh after it, and holding on to it would
            // keep the frames behind it off the screen as well.
            drops?.recordDroppedBeforePresent(1)
            latestFrame = nil
            latestTiming = nil
            hasUndrawnFrame = false
            return
        }
        commandBuffer.present(drawable)
        // Fires once the GPU has actually finished this work, on a Metal
        // dispatch queue rather than the main actor -- the clock read
        // happens right there so the sample is not skewed by the hop back,
        // and only the resulting number, a plain Int64, needs to cross.
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let dueAt else { return }
            let completedAt = MonotonicClock.nowNanoseconds()
            Task { @MainActor in
                self?.completionLatency.record(nanoseconds: completedAt - dueAt)
            }
        }
        commandBuffer.commit()
        hasUndrawnFrame = false
        if let latestTiming {
            onFramePresented?(latestTiming, MonotonicClock.nowNanoseconds())
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Encodes the aspect-fitted quad for one frame. Returns false when the
    /// destination leaves no room to draw into, in which case nothing was
    /// encoded and the command buffer is still empty.
    private func encodeFrame(
        _ pixelBuffer: CVPixelBuffer,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        let sourceWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        let videoRect = CanvasPresentationLayout.videoRect(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            viewportWidth: Double(texture.width),
            viewportHeight: Double(texture.height)
        )
        guard videoRect.width > 0, videoRect.height > 0 else {
            return false
        }
        // Releases the wrappers whose frames the GPU has finished with. The
        // textures themselves are the decoder's buffers, never copies.
        CVMetalTextureCacheFlush(textureCache, 0)
        let source = try FrameTextures(pixelBuffer: pixelBuffer, cache: textureCache)
        let pipeline = try pipelineState(for: texture.pixelFormat, layout: source.layout)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        // The bars beside or above the picture, drawn by clearing rather than
        // by compositing the frame over a black picture.
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalFramePresenterError.commandBufferUnavailable
        }
        var placement = QuadPlacement(
            videoRect: videoRect,
            destinationWidth: Double(texture.width),
            destinationHeight: Double(texture.height)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&placement, length: MemoryLayout<QuadPlacement>.stride, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for (index, plane) in source.textures.enumerated() {
            encoder.setFragmentTexture(plane, index: index)
        }
        if var conversion = source.colorConversion {
            encoder.setFragmentBytes(&conversion, length: MemoryLayout<ColorConversion>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // The wrappers have to outlive the work that reads them.
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(source) {}
        }
        return true
    }

    private func pipelineState(
        for destinationFormat: MTLPixelFormat,
        layout: FrameTextures.Layout
    ) throws -> MTLRenderPipelineState {
        let key = PipelineKey(destinationFormat: destinationFormat, layout: layout)
        if let existing = pipelines[key] {
            return existing
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sensoriumFrameVertex")
        descriptor.fragmentFunction = library.makeFunction(name: layout.fragmentFunctionName)
        descriptor.colorAttachments[0].pixelFormat = destinationFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = pipeline
        return pipeline
    }

    private func reportRenderFailure(_ error: Error) {
        guard !hasReportedRenderFailure else { return }
        hasReportedRenderFailure = true
        print("Sensorium: a decoded frame could not be drawn -- \(error)")
    }

    /// Asks the display link for this screen's own refresh rate, so a frame
    /// waits for the next real refresh rather than for a rate MetalKit
    /// assumed. Re-read as frames arrive because a window can be moved to
    /// another screen mid-session.
    private func updatePreferredFramesPerSecond() {
        guard let refreshRate = view.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond,
            refreshRate > 0,
            refreshRate != view.preferredFramesPerSecond else {
            return
        }
        view.preferredFramesPerSecond = refreshRate
    }

    private struct PipelineKey: Hashable {
        let destinationFormat: MTLPixelFormat
        let layout: FrameTextures.Layout
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadVertex {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    struct QuadPlacement {
        float2 scale;
        float2 offset;
    };

    struct ColorConversion {
        float3x3 matrix;
        float3 offset;
    };

    vertex QuadVertex sensoriumFrameVertex(uint vertexID [[vertex_id]],
                                           constant QuadPlacement &placement [[buffer(0)]]) {
        float2 corner = float2(float(vertexID & 1u), float((vertexID >> 1u) & 1u));
        QuadVertex out;
        out.position = float4(corner * placement.scale + placement.offset, 0.0, 1.0);
        out.textureCoordinate = corner;
        return out;
    }

    fragment float4 sensoriumFrameFragmentPacked(QuadVertex in [[stage_in]],
                                                 texture2d<float> frame [[texture(0)]],
                                                 sampler frameSampler [[sampler(0)]]) {
        return float4(frame.sample(frameSampler, in.textureCoordinate).rgb, 1.0);
    }

    fragment float4 sensoriumFrameFragmentBiplanar(QuadVertex in [[stage_in]],
                                                   texture2d<float> luma [[texture(0)]],
                                                   texture2d<float> chroma [[texture(1)]],
                                                   sampler frameSampler [[sampler(0)]],
                                                   constant ColorConversion &conversion [[buffer(0)]]) {
        float3 encoded = float3(luma.sample(frameSampler, in.textureCoordinate).r,
                                chroma.sample(frameSampler, in.textureCoordinate).rg);
        return float4(saturate(conversion.matrix * (encoded - conversion.offset)), 1.0);
    }
    """
}

/// Where the quad lands in the destination, in clip space. The vertex shader
/// reads the corner it was asked for as a texture coordinate and maps it
/// through this, so no vertex buffer is ever allocated.
private struct QuadPlacement {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>

    init(videoRect: CanvasVideoRect, destinationWidth: Double, destinationHeight: Double) {
        // Clip space runs from -1 to 1 with y upwards; the rect is in pixels
        // from the top left, which is also how the frame's rows are ordered.
        scale = SIMD2(
            Float(2 * videoRect.width / destinationWidth),
            Float(-2 * videoRect.height / destinationHeight)
        )
        offset = SIMD2(
            Float(2 * videoRect.x / destinationWidth - 1),
            Float(1 - 2 * videoRect.y / destinationHeight)
        )
    }
}

/// Turns the coded values of a frame into red, green and blue: one matrix and
/// the offset subtracted before it.
private struct ColorConversion {
    var matrix: simd_float3x3
    var offset: SIMD3<Float>

    /// `luma` scales the luma channel, `rv`, `gu`, `gv` and `bu` are the
    /// chroma terms, and the offset is what a black frame carries.
    init(luma: Float, rv: Float, gu: Float, gv: Float, bu: Float, offset: SIMD3<Float>) {
        matrix = simd_float3x3(
            SIMD3(luma, luma, luma),
            SIMD3(0, gu, bu),
            SIMD3(rv, gv, 0)
        )
        self.offset = offset
    }

    static let videoRange709 = ColorConversion(
        luma: 1.164384,
        rv: 1.792741,
        gu: -0.213249,
        gv: -0.532909,
        bu: 2.112402,
        offset: SIMD3(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
    )
    static let fullRange709 = ColorConversion(
        luma: 1,
        rv: 1.5748,
        gu: -0.187324,
        gv: -0.468124,
        bu: 1.8556,
        offset: SIMD3(0, 0.5, 0.5)
    )
    static let videoRange601 = ColorConversion(
        luma: 1.164384,
        rv: 1.596027,
        gu: -0.391762,
        gv: -0.812968,
        bu: 2.017232,
        offset: SIMD3(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
    )
    static let fullRange601 = ColorConversion(
        luma: 1,
        rv: 1.402,
        gu: -0.344136,
        gv: -0.714136,
        bu: 1.772,
        offset: SIMD3(0, 0.5, 0.5)
    )

    /// Frames coded for standard definition name the older matrix; everything
    /// else, including anything that names nothing at all, is read as the
    /// high definition one the encoders in use here produce.
    static func matching(attachmentsOf pixelBuffer: CVPixelBuffer, isFullRange: Bool) -> ColorConversion {
        let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let isSD = (attachment as? NSString) == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as NSString)
        switch (isSD, isFullRange) {
        case (true, true): return .fullRange601
        case (true, false): return .videoRange601
        case (false, true): return .fullRange709
        case (false, false): return .videoRange709
        }
    }
}

/// The decoder's own buffer, wrapped as textures without a copy. Held until
/// the GPU has finished reading it, which is why it crosses to the thread the
/// completion handler runs on: nothing here changes after it is made, and that
/// handler only lets go of it.
private final class FrameTextures: @unchecked Sendable {
    enum Layout: Hashable {
        /// One texture carrying red, green and blue already.
        case packed
        /// Luma and chroma in two planes, converted in the shader.
        case biplanar

        var fragmentFunctionName: String {
            switch self {
            case .packed: return "sensoriumFrameFragmentPacked"
            case .biplanar: return "sensoriumFrameFragmentBiplanar"
            }
        }
    }

    let layout: Layout
    let textures: [MTLTexture]
    let colorConversion: ColorConversion?
    private let wrappers: [CVMetalTexture]

    init(pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        switch format {
        case kCVPixelFormatType_32BGRA:
            layout = .packed
            colorConversion = nil
            let wrapper = try FrameTextures.wrap(
                pixelBuffer: pixelBuffer,
                cache: cache,
                plane: 0,
                format: .bgra8Unorm,
                width: width,
                height: height
            )
            wrappers = [wrapper.0]
            textures = [wrapper.1]
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            layout = .biplanar
            colorConversion = ColorConversion.matching(
                attachmentsOf: pixelBuffer,
                isFullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
            // Each plane is read at its own size. A frame of odd width or
            // height carries a chroma plane wider or taller than half of it,
            // and half of it would leave the last row or column out.
            let luma = try FrameTextures.wrap(
                pixelBuffer: pixelBuffer,
                cache: cache,
                plane: 0,
                format: .r8Unorm,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            )
            let chroma = try FrameTextures.wrap(
                pixelBuffer: pixelBuffer,
                cache: cache,
                plane: 1,
                format: .rg8Unorm,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            )
            wrappers = [luma.0, chroma.0]
            textures = [luma.1, chroma.1]
        default:
            throw MetalFramePresenterError.unsupportedPixelFormat(format)
        }
    }

    private static func wrap(
        pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        plane: Int,
        format: MTLPixelFormat,
        width: Int,
        height: Int
    ) throws -> (CVMetalTexture, MTLTexture) {
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            plane,
            &wrapper
        )
        guard status == kCVReturnSuccess,
              let wrapper,
              let texture = CVMetalTextureGetTexture(wrapper) else {
            throw MetalFramePresenterError.frameNotTexturable(status)
        }
        return (wrapper, texture)
    }
}

public enum MetalFramePresenterError: Error, Equatable {
    case deviceUnavailable
    case textureCacheUnavailable
    case samplerUnavailable
    case commandBufferUnavailable
    /// The frame could not be read by the GPU without a copy, which a frame
    /// with no IOSurface behind it cannot be.
    case frameNotTexturable(CVReturn)
    case unsupportedPixelFormat(OSType)
}
#endif
