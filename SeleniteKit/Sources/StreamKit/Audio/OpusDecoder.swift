import OpusCodec

public enum OpusError: Error, Equatable { case create(Int32) }

/// libopus multistream decoder for one session, configured from moonlight-common-c's
/// OPUS_MULTISTREAM_CONFIGURATION. Called only from moonlight's audio thread.
public final class OpusDecoder: @unchecked Sendable {
    public let channels: Int
    private let decoder: OpaquePointer

    public init(sampleRate: Int32, channels: Int32, streams: Int32, coupledStreams: Int32, mapping: [UInt8]) throws {
        guard mapping.count >= Int(channels) else { throw OpusError.create(OPUS_BAD_ARG) }
        var error: Int32 = 0
        guard let created = opus_multistream_decoder_create(sampleRate, channels, streams, coupledStreams, mapping, &error),
              error == OPUS_OK else { throw OpusError.create(error) }
        decoder = created
        self.channels = Int(channels)
    }

    deinit { opus_multistream_decoder_destroy(decoder) }

    /// Decoded frames (samples per channel) written interleaved into `pcm`; 0 when the packet is bad.
    public func decode(_ packet: UnsafeRawBufferPointer, into pcm: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let result = opus_multistream_decode_float(decoder, packet.bindMemory(to: UInt8.self).baseAddress,
                                                   Int32(packet.count), pcm, Int32(maxFrames), 0)
        return result > 0 ? Int(result) : 0
    }
}
