import CoreMedia
import Foundation

public enum VideoCodec: Sendable { case h264, hevc }

public enum StreamKitError: Error {
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
    case decoder(OSStatus)
}

/// Turns moonlight-common-c's Annex-B decode units into length-prefixed CMSampleBuffers.
public enum NALPackager {
    public static func stripStartCode(_ bytes: UnsafeRawBufferPointer) -> Data {
        let data = Data(bytes)
        if data.starts(with: [0, 0, 0, 1]) { return data.dropFirst(4) }
        if data.starts(with: [0, 0, 1]) { return data.dropFirst(3) }
        return data
    }

    public static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    let end = (i > s && bytes[i - 1] == 0) ? i - 1 : i
                    units.append(Data(bytes[s..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count { units.append(Data(bytes[s...])) }
        return units
    }

    public static func formatDescription(codec: VideoCodec, parameterSets: [Data]) throws -> CMVideoFormatDescription {
        let copies = parameterSets.map { [UInt8]($0) }
        var format: CMVideoFormatDescription?
        let status: OSStatus = withPointers(copies) { pointers, sizes in
            switch codec {
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: copies.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: copies.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw StreamKitError.formatDescription(status) }
        return format
    }

    public static func sampleBuffer(annexB: Data, format: CMVideoFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        var avcc = Data(capacity: annexB.count + 16)
        for unit in splitAnnexB(annexB) {
            var length = UInt32(unit.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(unit)
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw StreamKitError.sampleBuffer(status) }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { throw StreamKitError.sampleBuffer(status) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw StreamKitError.sampleBuffer(status) }
        return sample
    }

    private static func withPointers<R>(_ arrays: [[UInt8]],
                                        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = arrays.map { array -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: array.count)
            p.initialize(from: array, count: array.count)
            return p
        }
        defer { buffers.enumerated().forEach { $0.element.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = arrays.map(\.count)
        return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }
}
