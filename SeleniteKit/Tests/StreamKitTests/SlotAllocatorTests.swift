import Testing
@testable import StreamKit

@Test func onlyTwoSlotsExist() {
    let allocator = SlotAllocator()
    let first = allocator.acquire()
    let second = allocator.acquire()
    #expect(Set([first, second]) == [.a, .b])
    #expect(allocator.acquire() == nil)     // third session must fail, never share globals
    allocator.release(.a)
    #expect(allocator.acquire() == .a)
}

@Test func slotsReachTheirOwnCopy() {
    #expect(Slot.a.api.slot == 0)
    #expect(Slot.b.api.slot == 1)
}
