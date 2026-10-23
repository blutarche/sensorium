import CoreGraphics
import CoreVideo
import Foundation
import SensoriumHost

/// How much of a frame changed, read from its pixels. The sentinel the tests
/// pass as the dirty-rect fraction is what capture would have said, so a test
/// can tell which of the two answered.
func runFrameChangeSamplerTests() {
    expectIdenticalFramesHaveNoChange()
    expectTheFractionIsTheShareOfTheFrameThatChanged()
    expectASmallChangeIsASmallFraction()
    expectAScrolledPageIsABroadChange()
    expectOnlyALargeEnoughStepInLumaIsAChange()
    expectTheFirstFrameAndANewSizeAnswerWithTheDirtyRects()
    expectAnUnreadableFormatAnswersWithTheDirtyRects()
}

private let sentinel = 0.77
private let width = 640
private let height = 352

private func page() -> NV12TestImage {
    var image = NV12TestImage(width: width, height: height)
    image.drawText(in: CGRect(x: 0, y: 0, width: width, height: height))
    return image
}

private func fractions(_ images: [NV12TestImage]) -> [Double?] {
    let sampler = FrameChangeSampler()
    return images.map { sampler.changedFraction(of: $0.makePixelBuffer(), dirtyRectFraction: sentinel) }
}

private func expectIdenticalFramesHaveNoChange() {
    let result = fractions([page(), page(), page()])
    expect(result[1] == 0 && result[2] == 0, "two frames with the same pixels changed nothing, got \(result)")
    print("PASS: identical frames are no change")
}

private func expectTheFractionIsTheShareOfTheFrameThatChanged() {
    var half = page()
    half.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height), with: 128)
    let result = fractions([page(), half])
    expect(
        result[1].map { abs($0 - 0.5) < 0.02 } == true,
        "half the frame changed, got \(String(describing: result[1]))"
    )
    print("PASS: the fraction is the share of the frame that changed")
}

private func expectASmallChangeIsASmallFraction() {
    var caret = page()
    caret.fill(CGRect(x: 301, y: 100, width: 2, height: 40), with: 0)
    let result = fractions([page(), caret, page()])
    expect(
        result[1].map { $0 < 0.1 } == true && result[2].map { $0 < 0.1 } == true,
        "a 2 pixel caret appearing and going is under a tenth of the frame, got \(result)"
    )
    print("PASS: a caret is a small change")
}

private func expectAScrolledPageIsABroadChange() {
    var before = NV12TestImage(width: width, height: height)
    before.drawText(in: CGRect(x: 0, y: 0, width: width, height: height * 6 / 10))
    var after = NV12TestImage(width: width, height: height)
    after.drawText(in: CGRect(x: 0, y: 0, width: width, height: height * 6 / 10), scrolledBy: 20)
    let result = fractions([before, after])
    expect(
        result[1].map { $0 >= 0.1 } == true,
        "a page covering 60% of the frame scrolled 20 pixels is a broad change, got \(String(describing: result[1]))"
    )
    print("PASS: a scrolled page is a broad change")
}

private func expectOnlyALargeEnoughStepInLumaIsAChange() {
    var quiet = page()
    quiet.offset(CGRect(x: 0, y: 0, width: width, height: height), by: 2)
    var visible = page()
    visible.offset(CGRect(x: 0, y: 0, width: width, height: height), by: 3)
    let result = fractions([page(), quiet, page(), visible])
    expect(result[1] == 0, "a step of 2 levels is encoder noise, not a change, got \(String(describing: result[1]))")
    expect(result[3] == 1, "a step of 3 levels everywhere is the whole frame, got \(String(describing: result[3]))")
    print("PASS: a luma step of 2 levels or less is not a change")
}

private func expectTheFirstFrameAndANewSizeAnswerWithTheDirtyRects() {
    let sampler = FrameChangeSampler()
    expect(
        sampler.changedFraction(of: page().makePixelBuffer(), dirtyRectFraction: sentinel) == sentinel,
        "the first frame has nothing to be compared with, so capture's own answer stands"
    )
    expect(
        sampler.changedFraction(of: page().makePixelBuffer(), dirtyRectFraction: sentinel) == 0,
        "the second one is compared with the first"
    )
    var resized = NV12TestImage(width: width + 64, height: height)
    resized.drawText(in: CGRect(x: 0, y: 0, width: width + 64, height: height))
    expect(
        sampler.changedFraction(of: resized.makePixelBuffer(), dirtyRectFraction: nil) == nil,
        "a frame of another size is not compared with the last, so capture's answer stands, even when it is no answer"
    )
    expect(
        sampler.changedFraction(of: resized.makePixelBuffer(), dirtyRectFraction: sentinel) == 0,
        "and the frame after it is compared with that one"
    )
    print("PASS: a frame with nothing to be compared with answers with the dirty rects")
}

private func expectAnUnreadableFormatAnswersWithTheDirtyRects() {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    let sampler = FrameChangeSampler()
    for _ in 0..<2 {
        expect(
            sampler.changedFraction(of: pixelBuffer!, dirtyRectFraction: sentinel) == sentinel,
            "a frame in a format this cannot read keeps capture's answer"
        )
    }
    print("PASS: a format the sampler cannot read answers with the dirty rects")
}
