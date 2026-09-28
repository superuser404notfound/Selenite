import MoonlightCore

public enum ResolutionPreference: String, CaseIterable, Sendable {
    case p720, p1080, p1440, p2160, matchDisplay
}

public enum FrameRatePreference: String, CaseIterable, Sendable {
    case fps30, fps60, matchDisplay
}

public enum CodecPreference: String, CaseIterable, Sendable {
    case automatic, hevc, h264
}

public enum AudioPreference: String, CaseIterable, Sendable {
    case automatic, stereo
}

public enum StatsPreference: String, CaseIterable, Sendable {
    case off, compact
}

/// The user's stream settings (M1-B spec, section 4.3), global for every host.
public struct StreamPreferences: Equatable, Sendable {
    public static let bitrateChoicesMbps = [10, 20, 30, 50, 80, 100, 150, 200, 300, 400, 500]

    public var resolution: ResolutionPreference = .matchDisplay
    public var frameRate: FrameRatePreference = .fps60
    public var bitrateMbps = 150
    public var codec: CodecPreference = .automatic
    public var audio: AudioPreference = .automatic
    public var stats: StatsPreference = .off
    public var pacing: FramePacingMode = .lowLatency

    public init() {}
}

/// The Apple TV's current output mode, as the app reads it from the screen.
public struct DisplayMode: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Int

    public init(width: Int, height: Int, refreshRate: Int) {
        self.width = width; self.height = height; self.refreshRate = refreshRate
    }
}

/// Pure mapping from what the user chose, what the Apple TV outputs, what the audio route can take
/// and what the host can encode, to the settings one stream asks the host for.
public enum StreamSettingsResolver {
    public static let fallbackDisplay = DisplayMode(width: 1920, height: 1080, refreshRate: 60)

    public static func resolve(_ preferences: StreamPreferences, display: DisplayMode,
                               maximumOutputChannels: Int, hostCodecModeSupport: Int32) -> StreamSettings {
        let display = display.width > 0 && display.height > 0 && display.refreshRate > 0 ? display : fallbackDisplay
        let (width, height) = size(for: preferences.resolution, display: display)
        let audio: AudioChannels = preferences.audio == .stereo
            ? .stereo
            : AudioRoutePolicy.channels(maximumOutputChannels: maximumOutputChannels, forceStereo: false)
        return StreamSettings(
            width: width, height: height,
            fps: fps(for: preferences.frameRate, display: display),
            bitrateKbps: preferences.bitrateMbps * 1000,
            hdr: false,
            audio: audio,
            codec: codec(for: preferences.codec, hostCodecModeSupport: hostCodecModeSupport),
            pacing: preferences.pacing)
    }

    static func size(for resolution: ResolutionPreference, display: DisplayMode) -> (Int, Int) {
        switch resolution {
        case .p720: (1280, 720)
        case .p1080: (1920, 1080)
        case .p1440: (2560, 1440)
        case .p2160: (3840, 2160)
        case .matchDisplay: (display.width, display.height)
        }
    }

    /// "Match display" follows the panel's refresh rate, capped at 60 (the Apple TV's 4K maximum)
    /// and held at 30 or more, so a panel left at 24 Hz by a film does not stream a game at 24.
    static func fps(for frameRate: FrameRatePreference, display: DisplayMode) -> Int {
        switch frameRate {
        case .fps30: 30
        case .fps60: 60
        case .matchDisplay: min(60, max(30, display.refreshRate))
        }
    }

    /// Automatic takes HEVC when the host lists it, H.264 when it lists only H.264, and HEVC while
    /// the host has not answered serverinfo yet (0): `supportedVideoFormats` keeps H.264 in every
    /// HEVC request, so moonlight-common-c still negotiates H.264 with a host that lacks HEVC.
    static func codec(for preference: CodecPreference, hostCodecModeSupport: Int32) -> VideoCodec {
        switch preference {
        case .h264: return .h264
        case .hevc: return .hevc
        case .automatic:
            if hostCodecModeSupport == 0 { return .hevc }
            return hostCodecModeSupport & Int32(SCM_HEVC) != 0 ? .hevc : .h264
        }
    }
}
