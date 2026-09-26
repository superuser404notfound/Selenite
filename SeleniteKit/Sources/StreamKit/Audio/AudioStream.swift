import Foundation
import MoonlightCore

/// One session's audio: Opus packets in on moonlight's audio thread, PCM out through the shared engine.
final class AudioStream: @unchecked Sendable {
    let ring: AudioRing
    private let decoder: OpusDecoder
    private let attachment: AudioOutput.Attachment
    private let pcm: UnsafeMutablePointer<Float>
    private let maxFrames = 5760

    init(config: OPUS_MULTISTREAM_CONFIGURATION) throws {
        let mapping = withUnsafeBytes(of: config.mapping) { Array($0.prefix(Int(config.channelCount))) }
        decoder = try OpusDecoder(sampleRate: config.sampleRate, channels: config.channelCount,
                                  streams: config.streams, coupledStreams: config.coupledStreams, mapping: mapping)
        ring = AudioRing(channels: Int(config.channelCount), sampleRate: Int(config.sampleRate))
        // Attach before allocating `pcm`: nothing after a successful attach can throw, so a failed
        // attach never leaves `pcm` allocated with no `deinit` to free it (a throwing init that
        // doesn't finish never runs deinit).
        attachment = try AudioOutput.shared.attach(ring)
        pcm = .allocate(capacity: maxFrames * Int(config.channelCount))
    }

    func submit(_ packet: UnsafeRawBufferPointer) {
        let frames = decoder.decode(packet, into: pcm, maxFrames: maxFrames)
        if frames > 0 { ring.write(pcm, frames: frames) }
    }

    func close() {
        AudioOutput.shared.detach(attachment)
    }

    deinit { pcm.deallocate() }

    var stats: AudioRingStats { ring.stats }
}
