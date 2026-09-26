import Testing
@testable import StreamKit

@Test func surroundOnlyWhenRouteCarriesSixChannels() {
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 2, forceStereo: false) == .stereo)
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 6, forceStereo: false) == .surround51)
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 8, forceStereo: false) == .surround51)
    #expect(AudioRoutePolicy.channels(maximumOutputChannels: 8, forceStereo: true) == .stereo)
}
