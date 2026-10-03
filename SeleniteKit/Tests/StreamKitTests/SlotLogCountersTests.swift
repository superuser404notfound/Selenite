import Foundation
import Testing
@testable import StreamKit

@Test func logLinesCountPerSlot() {
    let counters = SlotLogCounters()
    counters.observe(slot: 0, line: "Video decode unit queue overflow\n")
    counters.observe(slot: 1, line: "Unrecoverable frame 12: 3+0=3 received < 5 needed\n")
    counters.observe(slot: 1, line: "Unrecoverable frame 13 (block 0 of 2): 1+1=2 received < 4 needed\n")
    counters.observe(slot: 0, line: "Received first video packet\n")
    #expect(counters.overflows(.a) == 1)
    #expect(counters.overflows(.b) == 0)
    #expect(counters.unrecoverable(.a) == 0)
    #expect(counters.unrecoverable(.b) == 2)
}

@Test func unknownSlotsAreIgnored() {
    let counters = SlotLogCounters()
    counters.observe(slot: -1, line: "Video decode unit queue overflow")
    counters.observe(slot: 7, line: "Video decode unit queue overflow")
    #expect(counters.overflows(.a) == 0 && counters.overflows(.b) == 0)
}

/// The counters match moonlight-common-c's log text; an update that rewords it must fail here.
@Test func theMatchedLinesExistInTheVendoredSources() throws {
    let src = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/moonlight-common-c/src")
    let depacketizer = try String(contentsOf: src.appendingPathComponent("VideoDepacketizer.c"), encoding: .utf8)
    let queue = try String(contentsOf: src.appendingPathComponent("RtpVideoQueue.c"), encoding: .utf8)
    #expect(depacketizer.contains("Limelog(\"\(SlotLogCounters.overflowLine)\\n\")"))
    #expect(queue.contains("Limelog(\"\(SlotLogCounters.unrecoverableLine) "))
}
