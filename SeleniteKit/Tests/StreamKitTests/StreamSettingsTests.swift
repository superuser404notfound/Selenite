import Testing
@testable import StreamKit

// VIDEO_FORMAT_H264 = 0x0001, VIDEO_FORMAT_H265 = 0x0100, VIDEO_FORMAT_H265_MAIN10 = 0x0200.

@Test func h264OffersOnlyH264() {
    let settings = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, hdr: false, codec: .h264)
    let formats: Int32 = settings.supportedVideoFormats
    #expect(formats == 0x0001)
}

@Test func hevcKeepsH264AsTheHostsFallback() {
    let settings = StreamSettings(width: 3840, height: 2160, fps: 60, bitrateKbps: 150_000, hdr: false, codec: .hevc)
    let formats: Int32 = settings.supportedVideoFormats
    #expect(formats == 0x0101)
}

@Test func hevcWithHDRAddsMain10() {
    let settings = StreamSettings(width: 3840, height: 2160, fps: 60, bitrateKbps: 150_000, hdr: true, codec: .hevc)
    let formats: Int32 = settings.supportedVideoFormats
    #expect(formats == 0x0301)
}

@Test func h264IgnoresHDR() {
    let settings = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, hdr: true, codec: .h264)
    let formats: Int32 = settings.supportedVideoFormats
    #expect(formats == 0x0001)
}

@Test func codecDefaultsToHEVC() {
    let settings = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, hdr: false)
    let codec: VideoCodec = settings.codec
    #expect(codec == .hevc)
}

@Test func statsHavePublicDefaults() {
    let stats = StreamStats()
    let presented: Int = stats.pacer.presented
    #expect(presented == 0)
    var audio = AudioRingStats()
    audio.underruns = 2
    let withAudio = StreamStats(audio: audio)
    let underruns: Int? = withAudio.audio?.underruns
    #expect(underruns == 2)
}

@Test func pacingDefaultsToLowestLatency() {
    let settings = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, hdr: false)
    let pacing: FramePacingMode = settings.pacing
    #expect(pacing == .lowLatency)
}

@Test func directPresentDefaultsToOff() {
    let settings = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, hdr: false)
    let directPresent: Bool = settings.directPresent
    #expect(!directPresent)
}
