import Testing
@testable import InputKit

@Test func aSwipeMovesOneStepPerHalfUnitOfTravel() {
    var nav = RemoteNavigator()
    #expect(nav.touch(x: -0.6, y: 0.1) == [])
    #expect(nav.touch(x: -0.3, y: 0.1) == [])
    #expect(nav.touch(x: -0.05, y: 0.1) == [.move(.right)])
    #expect(nav.touch(x: 0.2, y: 0.1) == [])
    #expect(nav.touch(x: 0.5, y: 0.15) == [.move(.right)])
}

@Test func aVerticalSwipeMovesUpAndDown() {
    var nav = RemoteNavigator()
    _ = nav.touch(x: 0.1, y: 0.6)
    #expect(nav.touch(x: 0.1, y: 0.0001) == [.move(.down)])
}

@Test func liftingTheFingerStartsTheNextSwipeFresh() {
    var nav = RemoteNavigator()
    _ = nav.touch(x: -0.6, y: 0.1)
    _ = nav.touch(x: 0, y: 0)
    #expect(nav.touch(x: 0.3, y: 0.1) == [])
}

@Test func samplesWithOneAxisAtZeroAreTouchEdgesNotPositions() {
    var nav = RemoteNavigator()
    _ = nav.touch(x: -0.6, y: 0.1)
    #expect(nav.touch(x: 0.6, y: 0) == [])
    #expect(nav.touch(x: 0, y: 0.1) == [])
}

@Test func aClickInTheMiddleSelects() {
    var nav = RemoteNavigator()
    _ = nav.touch(x: 0.1, y: -0.2)
    #expect(nav.click(pressed: true) == [.select])
    #expect(nav.click(pressed: false) == [])
}

@Test func aClickWithoutATouchSelects() {
    var nav = RemoteNavigator()
    #expect(nav.click(pressed: true) == [.select])
}

@Test func aClickSelectsWhereverTheFingerRests() {
    var nav = RemoteNavigator()
    _ = nav.touch(x: 0.85, y: 0.1)
    #expect(nav.click(pressed: true) == [.select])
}

@Test func movementWhileClickedIsNotASwipe() {
    var nav = RemoteNavigator()
    _ = nav.touch(x: 0.1, y: 0.1)
    _ = nav.click(pressed: true)
    #expect(nav.touch(x: 0.8, y: 0.1) == [])
    _ = nav.click(pressed: false)
    #expect(nav.touch(x: 0.9, y: 0.1) == [])
}
