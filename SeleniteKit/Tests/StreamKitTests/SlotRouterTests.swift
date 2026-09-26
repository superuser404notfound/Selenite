import Testing
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
