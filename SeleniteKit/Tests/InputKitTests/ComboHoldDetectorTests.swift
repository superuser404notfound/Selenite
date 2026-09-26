import Testing
@testable import InputKit

@Test func firesOnceAfterHold() {
    var d = ComboHoldDetector()
    var fired = d.update(pressed: true, now: 0)
    #expect(!fired)
    fired = d.update(pressed: true, now: 0.99)
    #expect(!fired)
    fired = d.update(pressed: true, now: 1.0)
    #expect(fired)
    fired = d.update(pressed: true, now: 2.0)
    #expect(!fired)
    fired = d.update(pressed: false, now: 2.1)
    #expect(!fired)
    fired = d.update(pressed: true, now: 2.2)
    #expect(!fired)
    fired = d.update(pressed: true, now: 3.3)
    #expect(fired)
}

@Test func releaseResetsTheTimer() {
    var d = ComboHoldDetector()
    _ = d.update(pressed: true, now: 0)
    _ = d.update(pressed: false, now: 0.5)
    var fired = d.update(pressed: true, now: 0.9)
    #expect(!fired)
    fired = d.update(pressed: true, now: 1.8)
    #expect(!fired)
    fired = d.update(pressed: true, now: 1.9)
    #expect(fired)
}
