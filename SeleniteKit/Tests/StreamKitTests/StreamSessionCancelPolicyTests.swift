import HostKit
import Testing
@testable import StreamKit

@Test func cancelsOnlyTheAppThisSessionLaunchedOrQuitInto() {
    #expect(StreamSession.shouldCancelOnStop(plan: .launch, launchIssued: true, cancelSent: false))
    #expect(StreamSession.shouldCancelOnStop(plan: .quitThenLaunch, launchIssued: true, cancelSent: false))
    #expect(!StreamSession.shouldCancelOnStop(plan: .resume, launchIssued: true, cancelSent: false))
}

@Test func cancelWaitsForTheLaunchRequestAndFiresOnlyOnce() {
    #expect(!StreamSession.shouldCancelOnStop(plan: .launch, launchIssued: false, cancelSent: false))
    #expect(!StreamSession.shouldCancelOnStop(plan: .launch, launchIssued: true, cancelSent: true))
}
