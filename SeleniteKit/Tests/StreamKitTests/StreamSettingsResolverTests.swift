import Testing
@testable import StreamKit

private let display4K = DisplayMode(width: 3840, height: 2160, refreshRate: 60)
private let display1080 = DisplayMode(width: 1920, height: 1080, refreshRate: 60)
// serverinfo ServerCodecModeSupport: SCM_H264 = 0x1, SCM_HEVC = 0x100.
private let hevcHost: Int32 = 0x0101
private let h264Host: Int32 = 0x0001

private func resolve(_ preferences: StreamPreferences, display: DisplayMode = display4K,
                     channels: Int = 6, codecs: Int32 = hevcHost) -> StreamSettings {
    StreamSettingsResolver.resolve(preferences, display: display, maximumOutputChannels: channels,
                                   hostCodecModeSupport: codecs)
}

@Test func defaultsMatchTheSpec() {
    let preferences = StreamPreferences()
    #expect(preferences.resolution == .matchDisplay)
    #expect(preferences.frameRate == .fps60)
    #expect(preferences.bitrateMbps == 150)
    #expect(preferences.codec == .automatic)
    #expect(preferences.audio == .automatic)
    #expect(preferences.stats == .off)
    #expect(preferences.pacing == .lowLatency)
}

@Test func bitrateChoicesMatchTheSpec() {
    let choices: [Int] = StreamPreferences.bitrateChoicesMbps
    #expect(choices == [10, 20, 30, 50, 80, 100, 150, 200, 300, 400, 500])
}

@Test func everyResolutionOnA4KDisplay() {
    let cases: [(ResolutionPreference, Int, Int)] = [
        (.p720, 1280, 720), (.p1080, 1920, 1080), (.p1440, 2560, 1440), (.p2160, 3840, 2160), (.matchDisplay, 3840, 2160),
    ]
    for (resolution, width, height) in cases {
        var preferences = StreamPreferences()
        preferences.resolution = resolution
        let settings = resolve(preferences)
        let resolvedWidth: Int = settings.width
        let resolvedHeight: Int = settings.height
        #expect(resolvedWidth == width, "\(resolution)")
        #expect(resolvedHeight == height, "\(resolution)")
    }
}

@Test func matchDisplayOnA1080pDisplay() {
    let settings = resolve(StreamPreferences(), display: display1080)
    let width: Int = settings.width
    let height: Int = settings.height
    #expect(width == 1920)
    #expect(height == 1080)
}

@Test func matchDisplayWithoutAReadableModeFallsBackTo1080p() {
    let settings = resolve(StreamPreferences(), display: DisplayMode(width: 0, height: 0, refreshRate: 0))
    let width: Int = settings.width
    let fps: Int = settings.fps
    #expect(width == 1920)
    #expect(fps == 60)
}

@Test func frameRates() {
    let cases: [(FrameRatePreference, Int, Int)] = [
        (.fps30, 60, 30), (.fps60, 60, 60), (.matchDisplay, 60, 60),
        (.matchDisplay, 50, 50), (.matchDisplay, 120, 60), (.matchDisplay, 24, 30),
    ]
    for (frameRate, refreshRate, expected) in cases {
        var preferences = StreamPreferences()
        preferences.frameRate = frameRate
        let settings = resolve(preferences, display: DisplayMode(width: 3840, height: 2160, refreshRate: refreshRate))
        let fps: Int = settings.fps
        #expect(fps == expected, "\(frameRate) at \(refreshRate) Hz")
    }
}

@Test func everyBitrateReachesTheSessionInKbps() {
    for mbps in StreamPreferences.bitrateChoicesMbps {
        var preferences = StreamPreferences()
        preferences.bitrateMbps = mbps
        let kbps: Int = resolve(preferences).bitrateKbps
        #expect(kbps == mbps * 1000)
    }
}

@Test func automaticCodecPicksHEVCWhenTheHostHasIt() {
    let codec: VideoCodec = resolve(StreamPreferences(), codecs: hevcHost).codec
    #expect(codec == .hevc)
}

@Test func automaticCodecFallsBackToH264() {
    let codec: VideoCodec = resolve(StreamPreferences(), codecs: h264Host).codec
    #expect(codec == .h264)
}

@Test func automaticCodecTrustsHEVCWhileTheHostIsUnknown() {
    // No serverinfo yet (0): HEVC is asked for, H.264 stays in supportedVideoFormats as the fallback.
    let settings = resolve(StreamPreferences(), codecs: 0)
    let codec: VideoCodec = settings.codec
    let formats: Int32 = settings.supportedVideoFormats
    #expect(codec == .hevc)
    #expect(formats & 0x0001 == 0x0001)
}

@Test func explicitCodecs() {
    var preferences = StreamPreferences()
    preferences.codec = .h264
    let h264: VideoCodec = resolve(preferences, codecs: hevcHost).codec
    #expect(h264 == .h264)
    preferences.codec = .hevc
    let hevc: VideoCodec = resolve(preferences, codecs: h264Host).codec
    #expect(hevc == .hevc)
}

@Test func audioFollowsTheRouteUnlessStereoIsChosen() {
    let cases: [(AudioPreference, Int, AudioChannels)] = [
        (.automatic, 6, .surround51), (.automatic, 8, .surround51), (.automatic, 2, .stereo),
        (.stereo, 6, .stereo), (.stereo, 2, .stereo),
    ]
    for (audio, channels, expected) in cases {
        var preferences = StreamPreferences()
        preferences.audio = audio
        let resolved: AudioChannels = resolve(preferences, channels: channels).audio
        #expect(resolved == expected, "\(audio) with \(channels) channels")
    }
}

@Test func hdrIsAlwaysOff() {
    let hdr: Bool = resolve(StreamPreferences()).hdr
    #expect(!hdr)
}

@Test func framePacingReachesTheSession() {
    for mode in FramePacingMode.allCases {
        var preferences = StreamPreferences()
        preferences.pacing = mode
        let pacing: FramePacingMode = resolve(preferences).pacing
        #expect(pacing == mode)
    }
}
