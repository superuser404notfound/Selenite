import InputKit
import Testing
@testable import AppCore

@Test func cursorStartsOnResume() {
    #expect(OverlayCursor().item == .resume)
}

@Test func leftAndRightStayInTheRowAndStopAtItsEnds() {
    var cursor = OverlayCursor(item: .swap)
    cursor.move(.left)
    #expect(cursor.item == .swap)
    cursor.move(.right)
    #expect(cursor.item == .reassign)
    cursor = OverlayCursor(item: .primary(.first))
    cursor.move(.right)
    #expect(cursor.item == .primary(.second))
    cursor.move(.right)
    #expect(cursor.item == .primary(.second))
}

@Test func upAndDownPickTheNearestColumn() {
    var cursor = OverlayCursor(item: .resume)
    cursor.move(.up)
    #expect(cursor.item == .secondary(.second))
    cursor.move(.up)
    #expect(cursor.item == .primary(.second))
    cursor.move(.up)
    #expect(cursor.item == .volumeDown(.second))
    cursor.move(.up)
    #expect(cursor.item == .volumeDown(.second))
    cursor = OverlayCursor(item: .volumeUp(.first))
    cursor.move(.down)
    #expect(cursor.item == .primary(.first))
    cursor = OverlayCursor(item: .primary(.first))
    cursor.move(.down)
    cursor.move(.down)
    #expect(cursor.item == .swap)
    cursor.move(.down)
    #expect(cursor.item == .swap)
}
