import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum ColorSignal: Sendable { case sdr709, hdr10 }

/// Real-time VideoToolbox decode with no reorder buffer (game streams carry no B-frames).
public final class VideoDecoder: @unchecked Sendable {
    private let session: VTDecompressionSession
    private let format: CMVideoFormatDescription
    private let color: ColorSignal
    private let output: @Sendable (CVPixelBuffer) -> Void

    public init(format: CMVideoFormatDescription, color: ColorSignal,
                output: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
        self.format = format
        self.color = color
        self.output = output
        let pixelFormat = color == .hdr10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { throw StreamKitError.decoder(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
    }

    public func canAccept(_ newFormat: CMVideoFormatDescription) -> Bool {
        VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat)
            && CMVideoFormatDescriptionGetDimensions(newFormat) == CMVideoFormatDescriptionGetDimensions(format)
    }

    public func decode(_ sample: CMSampleBuffer) throws {
        let statusBox = DecodeStatusBox()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [color, output, statusBox] status, _, imageBuffer, _, _ in
            statusBox.record(status)
            guard status == noErr, let imageBuffer else { return }
            Self.attachColor(color, to: imageBuffer)
            output(imageBuffer)
        }
        let decodeStatus = statusBox.value
        guard status == noErr, decodeStatus == noErr else { throw StreamKitError.decoder(status != noErr ? status : decodeStatus) }
    }

    public func invalidate() {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    // Adapted from AetherEngine Sources/AetherEngine/Decoder/HardwareVideoDecoder.swift:392-401:
    // without explicit attachments PQ renders as desaturated SDR on AVSampleBufferDisplayLayer.
    private static func attachColor(_ color: ColorSignal, to buffer: CVImageBuffer) {
        let (primaries, transfer, matrix): (CFString, CFString, CFString) = switch color {
        case .sdr709: (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2,
                       kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        case .hdr10: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                      kCVImageBufferYCbCrMatrix_ITU_R_2020)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }
}

extension CMVideoDimensions: @retroactive Equatable {
    public static func == (a: CMVideoDimensions, b: CMVideoDimensions) -> Bool { a.width == b.width && a.height == b.height }
}

/// The VTDecompressionSession output callback crosses into a @Sendable context; a lock-protected
/// box carries the status out instead of mutating a captured local (Swift 6 flags that as a
/// concurrently-mutated capture even though this decoder calls the session synchronously).
private final class DecodeStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: OSStatus = noErr

    func record(_ newStatus: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        status = newStatus
    }

    var value: OSStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }
}
