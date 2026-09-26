import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import StreamKit

/// Encodes one keyframe with VideoToolbox and returns it the way moonlight-common-c delivers it:
/// parameter sets and picture data as Annex-B byte streams.
enum TestEncoder {
    struct Unit { let parameterSets: [Data]; let picture: Data }

    static func keyframe(codec: VideoCodec, width: Int32 = 640, height: Int32 = 360) throws -> Unit {
        var session: VTCompressionSession?
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: type,
                                   encoderSpecification: nil, imageBufferAttributes: nil,
                                   compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                   compressionSessionOut: &session)
        let encoder = try #require(session)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        let sampleBox = SampleBox()
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: try #require(pixelBuffer), presentationTimeStamp: .zero,
                                        duration: .invalid,
                                        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
                                        infoFlagsOut: nil) { [sampleBox] _, _, sample in sampleBox.set(sample) }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        let sample = try #require(sampleBox.value)
        let format = try #require(CMSampleBufferGetFormatDescription(sample))

        var parameterSets: [Data] = []
        var count = 0
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { break }
            parameterSets.append(Data([0, 0, 0, 1]) + Data(bytes: pointer, count: size))
            index += 1
        } while index < count

        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &base)
        let avcc = Data(bytes: try #require(base), count: length)
        var picture = Data()
        var offset = 0
        while offset + 4 <= avcc.count {
            let nalLength = avcc[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            picture += Data([0, 0, 1]) + avcc[offset + 4..<offset + 4 + nalLength]
            offset += 4 + nalLength
        }
        return Unit(parameterSets: parameterSets, picture: picture)
    }
}

/// The VTCompressionSession output callback crosses into a @Sendable context; a lock-protected
/// box carries the encoded sample out instead of mutating a captured local.
private final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: CMSampleBuffer?

    func set(_ newSample: CMSampleBuffer?) {
        lock.lock(); defer { lock.unlock() }
        sample = newSample
    }

    var value: CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        return sample
    }
}
