import Testing
@testable import HostKit

@Test func resumesOnlyTheSameApp() {
    #expect(LaunchPlan.decide(currentGame: 0, appID: 42) == .launch)
    #expect(LaunchPlan.decide(currentGame: 42, appID: 42) == .resume)
    #expect(LaunchPlan.decide(currentGame: 7, appID: 42) == .quitThenLaunch)
}

@Test func serverInfoReadsCurrentGame() throws {
    let info = try ServerInfo(NvResponse.parse(fixture("serverinfo")).requireOK())
    #expect(info.currentGame == 0)
}
