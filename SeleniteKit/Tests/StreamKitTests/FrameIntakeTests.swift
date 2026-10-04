import Testing
@testable import StreamKit

private func feed(_ intake: inout FrameIntake, _ number: Int32, overflows: Int = 0, bytes: Int = 1000,
                  latency: UInt16 = 0, receive: UInt64 = 0, enqueue: UInt64 = 0) {
    intake.receive(frameNumber: number, bytes: bytes, hostLatencyTenths: latency,
                   receiveMicroseconds: receive, enqueueMicroseconds: enqueue, overflowsSoFar: overflows)
}

@Test func consecutiveFramesDropNothing() {
    var intake = FrameIntake()
    for n in 1...5 { feed(&intake, Int32(n)) }
    #expect(intake.networkDrops == 0)
    #expect(intake.queueDrops == 0)
    #expect(intake.bytes == 5000)
}

@Test func aGapWithoutOverflowIsNetworkLoss() {
    var intake = FrameIntake()
    feed(&intake, 1)
    feed(&intake, 4)
    #expect(intake.networkDrops == 2)
    #expect(intake.queueDrops == 0)
}

@Test func onlyTheFirstGapAfterAnOverflowIsQueueDrops() {
    var intake = FrameIntake()
    feed(&intake, 1)
    feed(&intake, 2)
    feed(&intake, 9, overflows: 1)
    #expect(intake.queueDrops == 6)
    #expect(intake.networkDrops == 0)
    feed(&intake, 10, overflows: 1)
    feed(&intake, 13, overflows: 1)
    #expect(intake.queueDrops == 6)
    #expect(intake.networkDrops == 2)
}

@Test func aContiguousFrameDoesNotConsumeAnOverflow() {
    // The overflow count can tick up between the log line and the queue flush: a contiguous frame
    // pulled in that window must not advance overflowsAttributed, or the gap that follows reads
    // as network loss instead of the queue drop it actually was.
    var intake = FrameIntake()
    feed(&intake, 1)
    feed(&intake, 2)
    feed(&intake, 3, overflows: 1)
    feed(&intake, 9, overflows: 1)
    #expect(intake.queueDrops == 5)
    #expect(intake.networkDrops == 0)
}

@Test func zeroHostLatencyGivesNilRange() {
    var intake = FrameIntake()
    feed(&intake, 1, latency: 0)
    #expect(intake.hostLatencyRange == nil)
}

@Test func sameSecondSamplesGiveARangeThatReadsStable() {
    var intake = FrameIntake()
    feed(&intake, 1, latency: 40, receive: 1_000_000)
    feed(&intake, 2, latency: 80, receive: 1_500_000)
    #expect(intake.hostLatencySamples == 2)
    #expect(intake.hostLatencyTotalTenths == 120)
    #expect(intake.hostLatencyRange == 4.0...8.0)
    #expect(intake.hostLatencyRange == 4.0...8.0)
}

@Test func theNextSecondKeepsThePreviousSecondInRange() {
    var intake = FrameIntake()
    feed(&intake, 1, latency: 40, receive: 1_000_000)
    feed(&intake, 2, latency: 80, receive: 1_500_000)
    feed(&intake, 3, latency: 20, receive: 2_100_000)
    #expect(intake.hostLatencyRange == 2.0...8.0)
}

@Test func aGapOfTwoOrMoreSecondsDropsTheOldValues() {
    var intake = FrameIntake()
    feed(&intake, 1, latency: 40, receive: 1_000_000)
    feed(&intake, 2, latency: 80, receive: 1_500_000)
    feed(&intake, 3, latency: 20, receive: 4_000_000)
    #expect(intake.hostLatencyRange == 2.0...2.0)
}

@Test func receiveZeroJoinsTheLastKnownBucket() {
    var intake = FrameIntake()
    feed(&intake, 1, latency: 40, receive: 1_000_000)
    feed(&intake, 2, latency: 80, receive: 0)
    #expect(intake.hostLatencyRange == 4.0...8.0)
}

@Test func networkReceiveTimeIsEnqueueMinusReceive() {
    var intake = FrameIntake()
    feed(&intake, 1, receive: 1_000, enqueue: 3_500)
    feed(&intake, 2, receive: 10_000, enqueue: 10_500)
    feed(&intake, 3, receive: 0, enqueue: 0)
    #expect(intake.receiveTotalMicroseconds == 3_000)
    #expect(intake.receiveSamples == 2)
}
