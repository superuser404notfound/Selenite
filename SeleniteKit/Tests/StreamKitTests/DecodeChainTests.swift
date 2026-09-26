import CoreMedia
import Foundation
import Testing
@testable import StreamKit

@Test func splitsThreeAndFourByteStartCodes() {
    let stream = Data([0, 0, 0, 1, 0xAA, 0xBB, 0, 0, 1, 0xCC, 0, 0, 0, 1, 0xDD, 0xEE, 0xFF])
    #expect(NALPackager.splitAnnexB(stream) == [Data([0xAA, 0xBB]), Data([0xCC]), Data([0xDD, 0xEE, 0xFF])])
}

@Test(arguments: [VideoCodec.hevc, .h264])
func annexBKeyframeDecodesToAPixelBuffer(codec: VideoCodec) throws {
    let unit = try TestEncoder.keyframe(codec: codec)
    let parameterSets = unit.parameterSets.map { bytes in bytes.withUnsafeBytes(NALPackager.stripStartCode) }
    let format = try NALPackager.formatDescription(codec: codec, parameterSets: parameterSets)
    let sample = try NALPackager.sampleBuffer(annexB: unit.picture, format: format, pts: .zero)

    let received = FrameMailbox<CVPixelBuffer>()
    let decoder = try VideoDecoder(format: format, color: .sdr709) { received.put($0) }
    try decoder.decode(sample)
    decoder.invalidate()

    let frame = try #require(received.take())
    #expect(CVPixelBufferGetWidth(frame) == 640)
    let display = try DisplaySample.make(frame)
    let attachments = CMSampleBufferGetSampleAttachmentsArray(display, createIfNecessary: false) as? [[CFString: Any]]
    #expect(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
}

@Test func decoderRejectsANewResolution() throws {
    let small = try TestEncoder.keyframe(codec: .hevc, width: 640, height: 360)
    let large = try TestEncoder.keyframe(codec: .hevc, width: 1280, height: 720)
    func format(_ unit: TestEncoder.Unit) throws -> CMVideoFormatDescription {
        try NALPackager.formatDescription(codec: .hevc,
            parameterSets: unit.parameterSets.map { $0.withUnsafeBytes(NALPackager.stripStartCode) })
    }
    let decoder = try VideoDecoder(format: try format(small), color: .sdr709) { _ in }
    #expect(decoder.canAccept(try format(small)))
    #expect(!decoder.canAccept(try format(large)))
    decoder.invalidate()
}
