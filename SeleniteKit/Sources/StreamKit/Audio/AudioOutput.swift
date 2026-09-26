import AVFoundation
import Foundation

/// One AVAudioEngine for the whole app: every session's ring feeds its own source node into the
/// main mixer, so split screen mixes by construction (M2 uses setVolume per side).
public final class AudioOutput: @unchecked Sendable {
    public static let shared = AudioOutput()
    public struct Attachment: Hashable, Sendable { fileprivate let id: UUID }

    /// Owns the render-thread scratch buffer alongside its node so `detach` can free it; the
    /// render block captures the same pointer, and it must outlive every render call the engine
    /// can still make until the node is detached.
    private struct NodeEntry {
        let node: AVAudioSourceNode
        let scratch: UnsafeMutablePointer<Float>
    }

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var nodes: [Attachment: NodeEntry] = [:]
    private var observers: [NSObjectProtocol] = []

    public var maximumOutputChannels: Int {
        #if os(tvOS)
        AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        #else
        2
        #endif
    }

    private init() {
        #if os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setPreferredIOBufferDuration(0.005)
        #endif
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.rewire()
        })
    }

    public func attach(_ ring: AudioRing) throws -> Attachment {
        let layoutTag = ring.channels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_A : kAudioChannelLayoutTag_Stereo
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: layoutTag)!)
        let channels = ring.channels
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * channels)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let frames = min(Int(frameCount), 4096)
            ring.read(into: scratch, frames: frames)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for (channel, buffer) in buffers.enumerated() where channel < channels {
                let out = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { out[i] = scratch[i * channels + channel] }
            }
            return noErr
        }
        let attachment = Attachment(id: UUID())
        try lock.withLock {
            #if os(tvOS)
            if channels == 6 {
                try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(6)
            }
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes[attachment] = NodeEntry(node: node, scratch: scratch)
            connectOutput()
            if !engine.isRunning { try engine.start() }
        }
        return attachment
    }

    public func detach(_ attachment: Attachment) {
        lock.withLock {
            guard let entry = nodes.removeValue(forKey: attachment) else { return }
            engine.detach(entry.node)
            entry.scratch.deallocate()
            if nodes.isEmpty { engine.stop() }
        }
    }

    public func setVolume(_ volume: Float, for attachment: Attachment) {
        lock.withLock { nodes[attachment]?.node.volume = volume }
    }

    /// Mixer to hardware in the hardware's channel count, so 5.1 reaches an eARC receiver and a
    /// stereo route gets the mixer's downmix.
    private func connectOutput() {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate > 0 ? hardware.sampleRate : 48000,
                                   channels: max(2, hardware.channelCount))
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
    }

    private func rewire() {
        lock.withLock {
            guard !nodes.isEmpty else { return }
            connectOutput()
            try? engine.start()
        }
    }
}
