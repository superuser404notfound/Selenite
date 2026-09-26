import Foundation
import OpusCodec
import Testing
@testable import StreamKit

/// Encodes 20 packets of a 440 Hz sine (5 ms each, like Sunshine) and decodes them back.
private func roundTrip(channels: Int32) throws -> (decoder: OpusDecoder, frames: Int, peak: Float) {
    var streams: Int32 = 0, coupled: Int32 = 0
    var mapping = [UInt8](repeating: 0, count: 8)
    var error: Int32 = 0
    let encoder = opus_multistream_surround_encoder_create(48000, channels, channels > 2 ? 1 : 0,
                                                           &streams, &coupled, &mapping, OPUS_APPLICATION_AUDIO, &error)
    #expect(error == OPUS_OK)
    defer { opus_multistream_encoder_destroy(encoder) }
    let decoder = try OpusDecoder(sampleRate: 48000, channels: channels, streams: streams,
                                  coupledStreams: coupled, mapping: Array(mapping.prefix(Int(channels))))
    let frameSize = 240
    var input = [Float](repeating: 0, count: frameSize * Int(channels))
    var packet = [UInt8](repeating: 0, count: 4000)
    var output = [Float](repeating: 0, count: 5760 * Int(channels))
    var total = 0
    var peak: Float = 0
    for p in 0..<20 {
        for i in 0..<frameSize {
            let v = sinf(2 * .pi * 440 * Float(p * frameSize + i) / 48000) * 0.5
            for c in 0..<Int(channels) { input[i * Int(channels) + c] = v }
        }
        let bytes = opus_multistream_encode_float(encoder!, input, Int32(frameSize), &packet, Int32(packet.count))
        #expect(bytes > 0)
        let decoded = packet.withUnsafeBytes { raw in
            output.withUnsafeMutableBufferPointer { decoder.decode(UnsafeRawBufferPointer(rebasing: raw.prefix(Int(bytes))), into: $0.baseAddress!, maxFrames: 5760) }
        }
        total += decoded
        if p > 5 { peak = max(peak, output.prefix(decoded * Int(channels)).map(abs).max() ?? 0) }
    }
    return (decoder, total, peak)
}

@Test func stereoRoundTrip() throws {
    let result = try roundTrip(channels: 2)
    #expect(result.decoder.channels == 2)
    #expect(result.frames == 20 * 240)
    #expect(result.peak > 0.3)
}

@Test func surround51RoundTrip() throws {
    let result = try roundTrip(channels: 6)
    #expect(result.decoder.channels == 6)
    #expect(result.frames == 20 * 240)
    #expect(result.peak > 0.3)
}

@Test func mappingShorterThanChannelCountThrows() {
    #expect(throws: OpusError.create(OPUS_BAD_ARG)) {
        try OpusDecoder(sampleRate: 48000, channels: 6, streams: 4, coupledStreams: 2, mapping: [0, 1])
    }
}

@Test func concealsALostPacketAfterRealPackets() throws {
    let result = try roundTrip(channels: 2)
    var out = [Float](repeating: 0, count: 5760 * 2)
    let frames = out.withUnsafeMutableBufferPointer { buffer in
        result.decoder.decode(UnsafeRawBufferPointer(start: nil, count: 0), into: buffer.baseAddress!, maxFrames: 5760)
    }
    #expect(frames > 0)
}

@Test func garbagePacketDecodesToNothing() throws {
    let decoder = try OpusDecoder(sampleRate: 48000, channels: 2, streams: 1, coupledStreams: 1, mapping: [0, 1])
    var out = [Float](repeating: 0, count: 5760 * 2)
    let n = [UInt8](repeating: 0xFF, count: 3).withUnsafeBytes { raw in
        out.withUnsafeMutableBufferPointer { decoder.decode(raw, into: $0.baseAddress!, maxFrames: 5760) }
    }
    #expect(n == 0)
}
