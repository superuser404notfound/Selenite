import CoreMedia
import Foundation

public enum VideoCodec: Sendable, Equatable { case h264, hevc }

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
        guard let firstStartCode = startCodeIndex(in: bytes),
              bytes[0..<firstStartCode].allSatisfy({ $0 == 0 }) else { return [] }

        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    appendTrimmed(bytes, s..<i, to: &units)
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start {
            appendTrimmed(bytes, s..<bytes.count, to: &units)
        }
        return units
    }

    /// The index of the first `00 00 01` marker, i.e. where the earliest start code begins
    /// (ignoring any extra zero bytes a 4-byte code is padded with).
    private static func startCodeIndex(in bytes: [UInt8]) -> Int? {
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { return i }
            i += 1
        }
        return nil
    }

    /// Strips every trailing zero byte from `bytes[range]` and appends the result unless it is
    /// empty (back-to-back start codes with nothing between them).
    private static func appendTrimmed(_ bytes: [UInt8], _ range: Range<Int>, to units: inout [Data]) {
        var end = range.upperBound
        while end > range.lowerBound, bytes[end - 1] == 0 { end -= 1 }
        guard end > range.lowerBound else { return }
        units.append(Data(bytes[range.lowerBound..<end]))
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
        let units = splitAnnexB(annexB)
        guard !units.isEmpty else { throw StreamKitError.sampleBuffer(kCMBlockBufferEmptyBBufErr) }
        let avccLength = units.reduce(0) { $0 + 4 + $1.count }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avccLength, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avccLength,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw StreamKitError.sampleBuffer(status) }

        var offset = 0
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            status = withUnsafeBytes(of: &length) {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: 4)
            }
            guard status == noErr else { throw StreamKitError.sampleBuffer(status) }
            offset += 4
            status = unit.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: unit.count)
            }
            guard status == noErr else { throw StreamKitError.sampleBuffer(status) }
            offset += unit.count
        }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = avccLength
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
