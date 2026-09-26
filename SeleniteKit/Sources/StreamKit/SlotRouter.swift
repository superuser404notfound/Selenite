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
    /// `data` is nil for a lost packet: moonlight-common-c calls this with (nil, 0) so libopus can
    /// conceal it, and that nil must reach `OpusDecoder.decode` unfiltered.
    func audioSample(_ data: UnsafePointer<CChar>?, length: Int32)
    func audioCleanup()
    func rumble(controller: UInt16, low: UInt16, high: UInt16)
    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16)
    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16)
    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8)
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8])
}

/// Host-side sink for controller feedback the server sends back to the client (rumble, LED,
/// motion sensor requests, adaptive triggers). `StreamSession` forwards its `SlotEventSink`
/// feedback callbacks here so callers do not need to conform to the full playback sink.
public protocol ControllerFeedbackHandler: AnyObject, Sendable {
    func rumble(controller: UInt16, low: UInt16, high: UInt16)
    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16)
    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16)
    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8)
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8])
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
