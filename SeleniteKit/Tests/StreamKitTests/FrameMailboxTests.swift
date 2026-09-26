import Testing
@testable import StreamKit

@Test func tickTakesNewestAndCountsOverwrittenAsDropped() {
    let mailbox = FrameMailbox<Int>()
    for frame in 1...5 { mailbox.put(frame) }   // burst after a network hiccup
    #expect(mailbox.take() == 5)
    #expect(mailbox.take() == nil)               // never more than one held
    #expect(mailbox.stats == MailboxStats(delivered: 1, dropped: 4, emptyTicks: 1))
}

@Test func steadyStreamDropsNothing() {
    let mailbox = FrameMailbox<Int>()
    for frame in 1...60 {
        mailbox.put(frame)
        #expect(mailbox.take() == frame)
    }
    #expect(mailbox.stats == MailboxStats(delivered: 60, dropped: 0, emptyTicks: 0))
}
