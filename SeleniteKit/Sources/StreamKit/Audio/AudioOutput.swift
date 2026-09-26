import AVFoundation
import Foundation

/// One AVAudioEngine for the whole app: every session's ring feeds its own source node into the
/// main mixer, so split screen mixes by construction (M2 uses setVolume per side).
public final class AudioOutput: @unchecked Sendable {
    public static let shared = AudioOutput()
    public struct Attachment: Hashable, Sendable { fileprivate let id: UUID }

    /// The render block captures this object, not a bare pointer: the block can still be called
    /// briefly after `detach` drops the engine's own reference, so the scratch memory must live
    /// exactly as long as something can call the block, not as long as `detach` happens to run.
    private final class ScratchBuffer {
        let pointer: UnsafeMutablePointer<Float>
        init(capacity: Int) { pointer = .allocate(capacity: capacity) }
        deinit { pointer.deallocate() }
    }

    private struct NodeEntry {
        let node: AVAudioSourceNode
    }

    private static let scratchFrameCapacity = 4096

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var nodes: [Attachment: NodeEntry] = [:]
    private var observers: [NSObjectProtocol] = []
    #if os(tvOS)
    private var sessionActivated = false
    #endif

    public var maximumOutputChannels: Int {
        #if os(tvOS)
        lock.withLock {
            do {
                try activateSessionLocked()
            } catch {
                NSLog("AudioOutput: session activation failed: %@", String(describing: error))
            }
            return AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        }
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

    #if os(tvOS)
    /// Category is set once at init; activation happens once, lazily, here, so a caller that only
    /// reads `maximumOutputChannels` before ever attaching still sees the real route.
    private func activateSessionLocked() throws {
        guard !sessionActivated else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        sessionActivated = true
    }
    #endif

    public func attach(_ ring: AudioRing) throws -> Attachment {
        let layoutTag = ring.channels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_A : kAudioChannelLayoutTag_Stereo
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: layoutTag)!)
        let channels = ring.channels
        let scratch = ScratchBuffer(capacity: Self.scratchFrameCapacity * channels)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            var remaining = Int(frameCount)
            var offset = 0
            while remaining > 0 {
                let chunk = min(remaining, AudioOutput.scratchFrameCapacity)
                ring.read(into: scratch.pointer, frames: chunk)
                for (channel, buffer) in buffers.enumerated() where channel < channels {
                    guard let mData = buffer.mData else { continue }
                    let out = mData.assumingMemoryBound(to: Float.self)
                    for i in 0..<chunk {
                        out[offset + i] = scratch.pointer[i * channels + channel]
                    }
                }
                remaining -= chunk
                offset += chunk
            }
            return noErr
        }
        let attachment = Attachment(id: UUID())
        try lock.withLock {
            #if os(tvOS)
            try activateSessionLocked()
            if channels == 6 {
                do {
                    try AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(6)
                } catch {
                    // Expected to fail on a route that only carries stereo; the mixer still
                    // downmixes correctly, so this is diagnostic, not fatal.
                    NSLog("AudioOutput: setPreferredOutputNumberOfChannels(6) failed: %@", String(describing: error))
                }
            }
            #endif
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes[attachment] = NodeEntry(node: node)
            let outputChannels = connectOutput()
            NSLog("[Selenite] AudioOutput: attached a %d-channel stream, output runs %d channels",
                  Int32(channels), Int32(outputChannels))
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    NSLog("[Selenite] AudioOutput: engine start failed: %@", String(describing: error))
                    nodes.removeValue(forKey: attachment)
                    engine.detach(node)
                    throw error
                }
            }
        }
        return attachment
    }

    public func detach(_ attachment: Attachment) {
        lock.withLock {
            guard let entry = nodes[attachment] else { return }
            if nodes.count == 1 { engine.stop() }
            engine.detach(entry.node)
            nodes.removeValue(forKey: attachment)
        }
    }

    public func setVolume(_ volume: Float, for attachment: Attachment) {
        lock.withLock { nodes[attachment]?.node.volume = volume }
    }

    /// Mixer to hardware in the hardware's channel count and layout. The plain
    /// `standardFormat(sampleRate:channels:)` initializer returns nil above 2 channels, so using
    /// it here silently kept every route at stereo; 5.1 needs an explicit channel layout to reach
    /// an eARC receiver. Returns the channel count the output was connected with.
    @discardableResult
    private func connectOutput() -> AVAudioChannelCount {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 48000
        let format = Self.outputFormat(sampleRate: sampleRate, channelCount: hardware.channelCount)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        return format.channelCount
    }

    private static func outputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> AVAudioFormat {
        let layoutTag: AudioChannelLayoutTag = switch channelCount {
        case 2: kAudioChannelLayoutTag_Stereo
        case 6: kAudioChannelLayoutTag_MPEG_5_1_A
        default: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
        }
        guard channelCount > 0, let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    private func rewire() {
        lock.withLock {
            guard !nodes.isEmpty else { return }
            let outputChannels = connectOutput()
            do {
                try engine.start()
                NSLog("[Selenite] AudioOutput: rewired after a configuration change, output runs %d channels",
                      Int32(outputChannels))
            } catch {
                NSLog("[Selenite] AudioOutput: engine restart after a configuration change failed: %@",
                      String(describing: error))
            }
        }
    }
}
