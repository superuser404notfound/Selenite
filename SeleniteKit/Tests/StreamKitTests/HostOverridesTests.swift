import Foundation
import Testing
@testable import StreamKit

@Test func emptyOverridesEqualTheGlobalPreferences() {
    var global = StreamPreferences()
    global.bitrateMbps = 80
    #expect(HostOverrides().isEmpty)
    #expect(global.applying(HostOverrides()) == global)
}

@Test func eachFieldOverridesAlone() {
    let global = StreamPreferences()
    var overrides = HostOverrides()
    overrides.resolution = .p1080
    #expect(global.applying(overrides).resolution == .p1080)
    #expect(global.applying(overrides).bitrateMbps == global.bitrateMbps)
    overrides = HostOverrides(); overrides.frameRate = .fps30
    #expect(global.applying(overrides).frameRate == .fps30)
    overrides = HostOverrides(); overrides.bitrateMbps = 20
    #expect(global.applying(overrides).bitrateMbps == 20)
    overrides = HostOverrides(); overrides.codec = .h264
    #expect(global.applying(overrides).codec == .h264)
    overrides = HostOverrides(); overrides.audio = .stereo
    #expect(global.applying(overrides).audio == .stereo)
    #expect(!overrides.isEmpty)
}

@Test func deviceValuesAreNeverOverridden() {
    var global = StreamPreferences()
    global.pacing = .smooth
    global.stats = .compact
    var overrides = HostOverrides()
    overrides.resolution = .p720
    let effective = global.applying(overrides)
    #expect(effective.pacing == .smooth)
    #expect(effective.stats == .compact)
}

@Test func aLaterGlobalChangeReachesNonOverriddenFields() {
    var overrides = HostOverrides()
    overrides.codec = .h264
    var global = StreamPreferences()
    global.bitrateMbps = 50
    #expect(global.applying(overrides).bitrateMbps == 50)
    global.bitrateMbps = 300
    global.resolution = .p1440
    let effective = global.applying(overrides)
    #expect(effective.bitrateMbps == 300)
    #expect(effective.resolution == .p1440)
    #expect(effective.codec == .h264)
}

@Test func splitTakesOnlyTheHostCodec() {
    var global = StreamPreferences()
    global.bitrateMbps = 100
    var overrides = HostOverrides()
    overrides.codec = .h264
    overrides.bitrateMbps = 20
    overrides.resolution = .p720
    overrides.audio = .automatic
    let split = global.forSplit(applying: overrides)
    #expect(split.codec == .h264)
    #expect(split.bitrateMbps == 100)
    #expect(split.resolution == global.resolution)
    let settings = StreamSettingsResolver.resolveSplit(split, layout: .sideBySide, format: .fillHalf,
                                                       display: DisplayMode(width: 3840, height: 2160, refreshRate: 60),
                                                       hostCodecModeSupport: 0)
    #expect(settings.bitrateKbps == 50_000)
    #expect(settings.codec == .h264)
    #expect(settings.fps == 60)
    #expect(settings.audio == .stereo)
}

@Test func unknownStoredValuesDecodeAsNilPerField() throws {
    let json = #"{"resolution":"p9999","frameRate":"fps30","bitrateMbps":77,"codec":"av1","audio":"stereo"}"#
    let decoded = try JSONDecoder().decode(HostOverrides.self, from: Data(json.utf8))
    #expect(decoded.resolution == nil)
    #expect(decoded.frameRate == .fps30)
    #expect(decoded.bitrateMbps == nil)
    #expect(decoded.codec == nil)
    #expect(decoded.audio == .stereo)
}

@Test func overridesRoundTrip() throws {
    var overrides = HostOverrides()
    overrides.resolution = .p2160
    overrides.bitrateMbps = 400
    let data = try JSONEncoder().encode(overrides)
    #expect(try JSONDecoder().decode(HostOverrides.self, from: data) == overrides)
}
