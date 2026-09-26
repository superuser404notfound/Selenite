import Foundation

public protocol SlotEventSink: AnyObject, Sendable {
    func decoderSetup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32
    func decoderStart()
    func decoderStop()
    func stageFailed(stage: Int32, error: Int32)
    func connectionStarted()
    func connectionTerminated(error: Int32)
    func connectionStatus(_ status: Int32)
    func setHdrMode(_ enabled: Bool)
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

    func detach(_ slot: Slot) {
        lock.lock(); sinks[slot] = nil; lock.unlock()
    }

    func sink(for slot: Slot) -> (any SlotEventSink)? {
        lock.lock(); defer { lock.unlock() }
        return sinks[slot]
    }
}
