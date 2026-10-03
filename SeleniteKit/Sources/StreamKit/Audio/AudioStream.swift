import Foundation
import MoonlightCore

/// One session's audio: Opus packets in on moonlight's audio thread, PCM out through the shared engine.
final class AudioStream: @unchecked Sendable {
    let ring: AudioRing
    private let decoder: OpusDecoder
    private let attachment: AudioOutput.Attachment
    private let pcm: UnsafeMutablePointer<Float>
    private let maxFrames = 5760
    /// One packet's worth of frames (240 for Sunshine's 5 ms at 48 kHz), the size a lost packet is concealed as.
    private let samplesPerFrame: Int

    init(config: OPUS_MULTISTREAM_CONFIGURATION) throws {
        let mapping = withUnsafeBytes(of: config.mapping) { Array($0.prefix(Int(config.channelCount))) }
        decoder = try OpusDecoder(sampleRate: config.sampleRate, channels: config.channelCount,
                                  streams: config.streams, coupledStreams: config.coupledStreams, mapping: mapping)
        samplesPerFrame = min(Int(config.samplesPerFrame), maxFrames)
        ring = AudioRing(channels: Int(config.channelCount), sampleRate: Int(config.sampleRate))
        // Attach before allocating `pcm`: nothing after a successful attach can throw, so a failed
        // attach never leaves `pcm` allocated with no `deinit` to free it (a throwing init that
        // doesn't finish never runs deinit).
        attachment = try AudioOutput.shared.attach(ring)
        pcm = .allocate(capacity: maxFrames * Int(config.channelCount))
    }

    func submit(_ packet: UnsafeRawBufferPointer) {
        let budget = Self.frameBudget(packetBytes: packet.count, samplesPerFrame: samplesPerFrame, maxFrames: maxFrames)
        let frames = decoder.decode(packet, into: pcm, maxFrames: budget)
        if frames > 0 { ring.write(pcm, frames: frames) }
    }

    /// libopus conceals a lost packet across the whole frame size it is handed, so a loss gets one
    /// packet's duration; 5760 there would insert 120 ms per loss and force a ring catch-up.
    static func frameBudget(packetBytes: Int, samplesPerFrame: Int, maxFrames: Int) -> Int {
        packetBytes == 0 ? samplesPerFrame : maxFrames
    }

    func close() {
        AudioOutput.shared.detach(attachment)
    }

    func setVolume(_ volume: Float) {
        AudioOutput.shared.setVolume(volume, for: attachment)
    }

    deinit { pcm.deallocate() }

    var stats: AudioRingStats { ring.stats }
}
