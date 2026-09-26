import Foundation
import MoonlightCore

public protocol SlotEventSink: AnyObject, Sendable {
    func decoderSetup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32
    func decoderStart()
    func decoderStop()
    func stageFailed(stage: Int32, error: Int32)
    func connectionStarted()
    func connectionTerminated(error: Int32)
    func connectionStatus(_ status: Int32)
    func setHdrMode(_ enabled: Bool)
    func audioInit(_ config: OPUS_MULTISTREAM_CONFIGURATION) -> Int32
    func audioSample(_ data: UnsafePointer<CChar>, length: Int32)
    func audioCleanup()
}

/// moonlight-common-c callbacks carry no context pointer; each slot's C trampolines look up their
/// session here.
final class SlotRouter: @unchecked Sendable {
    static let shared = SlotRouter()
    private let lock = NSLock()
    private var sinks: [Slot: any SlotEventSink] = [:]

    func attach(_ sink: any SlotEventSink, to slot: Slot) {
        lock.lock(); sinks[slot] = sink; lock.unlock()
    }

    /// Removes the entry only while `sink` is the one attached, so a stale session cannot unhook
    /// the session that reused its slot.
    func detach(_ slot: Slot, ifAttached sink: any SlotEventSink) {
        lock.lock(); defer { lock.unlock() }
        if sinks[slot] === sink { sinks[slot] = nil }
    }

    func sink(for slot: Slot) -> (any SlotEventSink)? {
        lock.lock(); defer { lock.unlock() }
        return sinks[slot]
    }
}
