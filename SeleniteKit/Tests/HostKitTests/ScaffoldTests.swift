import Testing
@testable import HostKit

@Test func packageBuilds() {
    #expect(HostKit.clientName == "Selenite")
}
