import Testing
import MoonlightCore
@testable import StreamKit

private final class StubSink: SlotEventSink {
    func decoderSetup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32 { 0 }
    func decoderStart() {}
    func decoderStop() {}
    func stageFailed(stage: Int32, error: Int32) {}
    func connectionStarted() {}
    func connectionTerminated(error: Int32) {}
    func connectionStatus(_ status: Int32) {}
    func setHdrMode(_ enabled: Bool) {}
    func audioInit(_ config: OPUS_MULTISTREAM_CONFIGURATION) -> Int32 { 0 }
    func audioSample(_ data: UnsafePointer<CChar>?, length: Int32) {}
    func audioCleanup() {}
    func rumble(controller: UInt16, low: UInt16, high: UInt16) {}
    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) {}
    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) {}
    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) {}
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {}
}

@Test func detachWithAnotherSinkLeavesTheAttachedOneInPlace() {
    let router = SlotRouter()
    let current = StubSink()
    router.attach(current, to: .a)
    router.detach(.a, ifAttached: StubSink())   // a stale session stopping after its slot was reused
    #expect(router.sink(for: .a) === current)
    router.detach(.a, ifAttached: current)
    #expect(router.sink(for: .a) == nil)
}
