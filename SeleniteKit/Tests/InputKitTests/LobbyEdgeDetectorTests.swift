import Testing
@testable import InputKit

private final class Pad {}

@Test func aPressReportsTheDirectionHeldAtThatMoment() {
    let pad = ObjectIdentifier(Pad())
    var detector = LobbyEdgeDetector()
    var s = GamepadSnapshot()
    s.leftX = 1
    #expect(detector.events(pad: pad, snapshot: s) == [])
    s.a = true
    #expect(detector.events(pad: pad, snapshot: s) == [.a(.right)])
    // Held: no second press.
    #expect(detector.events(pad: pad, snapshot: s) == [])
}

@Test func firstReportWithAPressedCountsWithoutABaseline() {
    let pad = ObjectIdentifier(Pad())
    var detector = LobbyEdgeDetector()
    var s = GamepadSnapshot()
    s.a = true
    #expect(detector.events(pad: pad, snapshot: s) == [.a(.center)])
}

@Test func aBaselineHoldingAIsNotAPress() {
    let pad = ObjectIdentifier(Pad())
    var detector = LobbyEdgeDetector()
    var s = GamepadSnapshot()
    s.a = true
    detector.baseline(pad: pad, snapshot: s)
    #expect(detector.events(pad: pad, snapshot: s) == [])
    s.a = false
    #expect(detector.events(pad: pad, snapshot: s) == [])
    s.a = true
    #expect(detector.events(pad: pad, snapshot: s) == [.a(.center)])
}

@Test func bAndStartArePresses() {
    let pad = ObjectIdentifier(Pad())
    var detector = LobbyEdgeDetector()
    var s = GamepadSnapshot()
    detector.baseline(pad: pad, snapshot: s)
    s.b = true
    s.menu = true
    #expect(detector.events(pad: pad, snapshot: s) == [.b, .start])
}

@Test func forgetDropsTheBaseline() {
    let pad = ObjectIdentifier(Pad())
    var detector = LobbyEdgeDetector()
    var s = GamepadSnapshot()
    s.a = true
    detector.baseline(pad: pad, snapshot: s)
    detector.forget(pad)
    #expect(detector.events(pad: pad, snapshot: s) == [.a(.center)])
}
