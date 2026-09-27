import Testing
@testable import StreamKit

@Test func surroundOnlyWhenRouteCarriesSixChannels() {
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 2, forceStereo: false) == .stereo)
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 6, forceStereo: false) == .surround51)
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 8, forceStereo: false) == .surround51)
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 8, forceStereo: true) == .stereo)
}

@Test func outputFollowsTheContentNotTheRoute() {
    let stereoOnSurroundRoute: Int = AudioRoutePolicy.outputChannels(streamChannels: [2], hardwareMaximum: 6)
    let surroundOnSurroundRoute: Int = AudioRoutePolicy.outputChannels(streamChannels: [6], hardwareMaximum: 8)
    let surroundOnStereoRoute: Int = AudioRoutePolicy.outputChannels(streamChannels: [6], hardwareMaximum: 2)
    let mixed: Int = AudioRoutePolicy.outputChannels(streamChannels: [2, 6], hardwareMaximum: 6)
    let nothingAttached: Int = AudioRoutePolicy.outputChannels(streamChannels: [], hardwareMaximum: 6)
    let unknownRoute: Int = AudioRoutePolicy.outputChannels(streamChannels: [6], hardwareMaximum: 0)
    #expect(stereoOnSurroundRoute == 2)
    #expect(surroundOnSurroundRoute == 6)
    #expect(surroundOnStereoRoute == 2)
    #expect(mixed == 6)
    #expect(nothingAttached == 2)
    #expect(unknownRoute == 2)
}
