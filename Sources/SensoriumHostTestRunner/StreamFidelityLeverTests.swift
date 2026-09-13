import SensoriumHost

/// The two host levers that change a live stream's fidelity without tearing
/// the capture/encode pipeline down: frame rate and encoder quality. Both are
/// carried on `VideoEncoderConfiguration`, so a resolution rebuild -- which
/// does recreate the pipeline -- must carry them into the new configuration
/// rather than silently returning the stream to its opening fidelity.
///
/// Nothing here touches a `VTCompressionSession` or an `SCStream`; the seam is
/// `CanvasMediaStreaming`, exactly as docs/testing.md describes.
@MainActor
func runStreamFidelityLeverTests() async {
    let baseline = VideoEncoderConfiguration.remoteDefault
    expect(
        baseline.qualityScale == 1.0,
        "the default configuration streams at full quality, so nothing has to opt in to today's picture"
    )

    // What one refreshed still frame is encoded at. A quality target, not a
    // bit rate: VideoToolbox's average-bitrate control spends a fraction of a
    // second's budget on any one frame, however large that budget is made,
    // which is measurably not what a screen full of small text needs.
    expect(
        VideoEncoderConfiguration.stillRefreshQuality == 0.95,
        "a still frame is encoded at a named quality, and changing it is a decision about how sharp "
            + "a picture nobody is changing is worth sending, got \(VideoEncoderConfiguration.stillRefreshQuality)"
    )
    expect(
        VideoEncoderConfiguration.stillRefreshFallbackQualities == [0.5, 0.3],
        "each attempt after the first is softer than the one before it, or the ceiling below could "
            + "never be met, got \(VideoEncoderConfiguration.stillRefreshFallbackQualities)"
    )
    expect(
        baseline.stillRefreshCeilingBytes == VideoEncoderConfiguration.averageBitRate(
            encodeWidth: baseline.encodeWidth,
            encodeHeight: baseline.encodeHeight
        ) / 8,
        "one still frame may cost what a second of this resolution at full motion costs and no more, "
            + "got \(baseline.stillRefreshCeilingBytes)"
    )
    expect(
        baseline.with(qualityScale: 0.25).stillRefreshCeilingBytes == baseline.stillRefreshCeilingBytes,
        "the ceiling is the resolution's own, never the softened one the moving screen was left at"
    )
    expect(
        VideoEncoderConfiguration.stillRefreshRetryQuality(
            frameBytes: baseline.stillRefreshCeilingBytes,
            ceilingBytes: baseline.stillRefreshCeilingBytes,
            attemptsMade: 1
        ) == nil,
        "a frame that fits the ceiling is the frame that is sent, with nothing encoded twice"
    )
    expect(
        VideoEncoderConfiguration.stillRefreshRetryQuality(
            frameBytes: baseline.stillRefreshCeilingBytes + 1,
            ceilingBytes: baseline.stillRefreshCeilingBytes,
            attemptsMade: 1
        ) == VideoEncoderConfiguration.stillRefreshFallbackQualities[0],
        "a frame over it earns a softer attempt"
    )

    let halfQuality = baseline.with(qualityScale: 0.5)
    expect(
        halfQuality.averageBitRate == baseline.averageBitRate / 2,
        "half quality halves the average bitrate, expected \(baseline.averageBitRate / 2), got \(halfQuality.averageBitRate)"
    )
    expect(
        halfQuality.dataRateLimitBytes == VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: halfQuality.averageBitRate),
        "the burst ceiling follows the quality-scaled bitrate rather than staying at the full-quality budget"
    )
    expect(
        halfQuality.encodeWidth == baseline.encodeWidth && halfQuality.encodeHeight == baseline.encodeHeight,
        "quality changes bits, never pixels: a quality step must not resize the encoder"
    )

    expect(
        baseline.with(qualityScale: 0.1).qualityScale == 0.25,
        "a quality below the floor is clamped to it, since a stream nobody can read is not a fidelity step"
    )
    expect(
        baseline.with(qualityScale: 4.0).qualityScale == 1.0,
        "quality above full is clamped to full: there are no extra bits to spend"
    )
    expect(
        baseline.with(qualityScale: .nan).qualityScale == 1.0,
        "a non-finite quality falls back to full rather than producing a bitrate no encoder can be given"
    )

    expect(
        baseline.averageBitRate == 12_000_000,
        "the default 1920x1200 stream at 60 fps and full quality is unchanged at 12 Mbps, got \(baseline.averageBitRate)"
    )

    let slower = baseline.with(framesPerSecond: 30)
    expect(
        slower.framesPerSecond == 30,
        "a frame-rate step is carried on the configuration"
    )
    expect(
        slower.averageBitRate == baseline.averageBitRate / 2,
        "half the frames need half the bits per second, expected \(baseline.averageBitRate / 2), got \(slower.averageBitRate)"
    )
    expect(
        Double(slower.averageBitRate) / 30.0 == Double(baseline.averageBitRate) / 60.0,
        "bits per frame is what a frame-rate step holds constant, so text stays as sharp on a slower stream as on a fast one"
    )
    expect(
        slower.dataRateLimitBytes == VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: slower.averageBitRate),
        "the burst ceiling follows a frame-rate step down rather than leaving the previous rate's budget in place"
    )

    // What the encoder relies on when it derives each live property change
    // from the fidelity already in force rather than from the one it opened
    // with: either order of the two levers has to reach the same bitrate, or
    // one lever would silently undo the other.
    let qualityThenRate = baseline.with(qualityScale: 0.5).with(framesPerSecond: 30)
    let rateThenQuality = baseline.with(framesPerSecond: 30).with(qualityScale: 0.5)
    expect(
        qualityThenRate.averageBitRate == baseline.averageBitRate / 4
            && rateThenQuality.averageBitRate == qualityThenRate.averageBitRate,
        "the two levers compose in either order, expected \(baseline.averageBitRate / 4), got \(qualityThenRate.averageBitRate) and \(rateThenQuality.averageBitRate)"
    )
    expect(
        qualityThenRate.framesPerSecond == 30 && qualityThenRate.qualityScale == 0.5,
        "moving one lever leaves the other exactly where it was"
    )

    let rebuilt = baseline.with(framesPerSecond: 20).with(qualityScale: 0.75).scaled(toStreamScale: 2.0)
    expect(
        rebuilt.framesPerSecond == 20 && rebuilt.qualityScale == 0.75,
        "a resolution rebuild keeps the frame rate and quality already applied, got \(rebuilt.framesPerSecond) fps at \(rebuilt.qualityScale)"
    )
    expect(
        rebuilt.averageBitRate == VideoEncoderConfiguration.averageBitRate(
            encodeWidth: 3840,
            encodeHeight: 2400,
            framesPerSecond: 20,
            qualityScale: 0.75
        ),
        "the rebuilt bitrate is the new pixel count at the frame rate and quality still in force, got \(rebuilt.averageBitRate)"
    )
    expect(
        rebuilt.streamScale == 2.0,
        "the rebuild still applies the requested stream scale"
    )

    let media = FakeScalableCanvasMedia()
    try? await media.apply(framesPerSecond: 45)
    try? await media.apply(qualityScale: 0.5)
    expect(
        media.appliedFramesPerSecond == [45],
        "the media records the frame rate it was asked to apply, got \(media.appliedFramesPerSecond)"
    )
    expect(
        media.appliedQualityScales == [0.5],
        "the media records the quality it was asked to apply, got \(media.appliedQualityScales)"
    )
    let currentFrameRate = await media.currentFramesPerSecond
    let currentQuality = await media.currentQualityScale
    expect(
        currentFrameRate == 45 && currentQuality == 0.5,
        "the media reports the fidelity actually in force, got \(currentFrameRate) fps at \(currentQuality)"
    )

    await media.requestKeyFrame()
    expect(
        media.keyFrameRequestCount == 1,
        "a fidelity change can ask for a fresh key frame, so the viewer sees the new picture at once rather than waiting out the interval, got \(media.keyFrameRequestCount)"
    )

    media.frameCounts = HostFrameCounts(
        captured: 120,
        encoded: 112,
        encodeSubmissionFailures: 0,
        encoderInputDropped: 8
    )
    let counts = await media.frameCounts
    expect(
        counts.captured == 120 && counts.encoderInputDropped == 8,
        "the per-surface capture counters reach a caller through the media, so pressure is read from ground truth rather than inferred"
    )

    print("PASS: frame rate and encoder quality are live levers that survive a resolution rebuild, and the media reports ground-truth counts")
}
