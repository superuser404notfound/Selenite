import Foundation
import MoonlightCore
import Testing
@testable import StreamKit

private final class RecordingSink: SlotEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ e: String) { lock.withLock { events.append(e) } }
    var recorded: [String] { lock.withLock { events } }
    func decoderSetup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32 { record("setup"); return 0 }
    func decoderStart() { record("start") }
    func decoderStop() { record("stop") }
    func stageFailed(stage: Int32, error: Int32) { record("stageFailed") }
    func connectionStarted() { record("started") }
    func connectionTerminated(error: Int32) { record("terminated") }
    func connectionStatus(_ status: Int32) { record("status") }
    func setHdrMode(_ enabled: Bool) { record("hdr") }
    func audioInit(_ config: OPUS_MULTISTREAM_CONFIGURATION) -> Int32 { record("audioInit"); return 0 }
    func audioSample(_ data: UnsafePointer<CChar>?, length: Int32) { record("audioSample") }
    func audioCleanup() { record("audioCleanup") }
    func rumble(controller: UInt16, low: UInt16, high: UInt16) { record("rumble") }
    func rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16) { record("rumbleTriggers") }
    func setMotionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16) { record("motion") }
    func setControllerLED(controller: UInt16, r: UInt8, g: UInt8, b: UInt8) { record("led") }
    func setAdaptiveTriggers(controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) { record("triggers") }
}

@Suite(.serialized)
struct SlotCallbackRoutingTests {
    @Test func slotBCallbacksNeverReachSlotA() {
        let a = RecordingSink(), b = RecordingSink()
        SlotRouter.shared.attach(a, to: .a)
        SlotRouter.shared.attach(b, to: .b)
        defer { SlotRouter.shared.detach(.a, ifAttached: a); SlotRouter.shared.detach(.b, ifAttached: b) }
        let connection = SlotCallbacks.connection(for: .b)
        connection.connectionStarted!()
        connection.connectionTerminated!(0)
        connection.stageFailed!(1, 2)
        connection.connectionStatusUpdate!(1)
        connection.setHdrMode!(true)
        connection.rumble!(0, 1, 2)
        connection.rumbleTriggers!(0, 1, 2)
        connection.setMotionEventState!(0, 1, 100)
        connection.setControllerLED!(0, 1, 2, 3)
        var leftPayload = [UInt8](repeating: 0, count: 10)
        var rightPayload = [UInt8](repeating: 0, count: 10)
        connection.setAdaptiveTriggers!(0, 0x0C, 0x21, 0x21, &leftPayload, &rightPayload)
        let video = SlotCallbacks.video(for: .b)
        _ = video.setup!(0x100, 1920, 1080, 60, nil, 0)
        video.start!(); video.stop!()
        let audio = SlotCallbacks.audio(for: .b)
        audio.cleanup!()
        #expect(a.recorded.isEmpty)
        #expect(b.recorded.count == 14)
    }
}
