import CoreMedia
import CoreVideo

/// Wraps a decoded frame for AVSampleBufferVideoRenderer; DisplayImmediately because the pacer, not
/// the renderer's clock, decides when a frame is shown.
public enum DisplaySample {
    public static func make(_ pixelBuffer: CVPixelBuffer) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                                  formatDescriptionOut: &format)
        guard status == noErr, let format else { throw StreamKitError.formatDescription(status) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                          formatDescription: format, sampleTiming: &timing,
                                                          sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw StreamKitError.sampleBuffer(status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
