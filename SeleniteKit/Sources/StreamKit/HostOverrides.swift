import Foundation

/// The stream settings one host overrides (M3-A spec, section 3); nil follows the global value.
public struct HostOverrides: Codable, Equatable, Sendable {
    public var resolution: ResolutionPreference?
    public var frameRate: FrameRatePreference?
    public var bitrateMbps: Int?
    public var codec: CodecPreference?
    public var audio: AudioPreference?

    public init() {}

    public var isEmpty: Bool {
        resolution == nil && frameRate == nil && bitrateMbps == nil && codec == nil && audio == nil
    }

    private enum CodingKeys: String, CodingKey {
        case resolution, frameRate, bitrateMbps, codec, audio
    }

    /// A value an older or newer build wrote that this one does not know becomes nil for that field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func raw(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        resolution = raw(.resolution).flatMap(ResolutionPreference.init(rawValue:))
        frameRate = raw(.frameRate).flatMap(FrameRatePreference.init(rawValue:))
        codec = raw(.codec).flatMap(CodecPreference.init(rawValue:))
        audio = raw(.audio).flatMap(AudioPreference.init(rawValue:))
        let bitrate = (try? container.decodeIfPresent(Int.self, forKey: .bitrateMbps)) ?? nil
        bitrateMbps = bitrate.flatMap { StreamPreferences.bitrateChoicesMbps.contains($0) ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(resolution?.rawValue, forKey: .resolution)
        try container.encodeIfPresent(frameRate?.rawValue, forKey: .frameRate)
        try container.encodeIfPresent(bitrateMbps, forKey: .bitrateMbps)
        try container.encodeIfPresent(codec?.rawValue, forKey: .codec)
        try container.encodeIfPresent(audio?.rawValue, forKey: .audio)
    }
}

extension StreamPreferences {
    /// The effective preferences for a solo stream from this host.
    public func applying(_ overrides: HostOverrides) -> StreamPreferences {
        var effective = self
        if let value = overrides.resolution { effective.resolution = value }
        if let value = overrides.frameRate { effective.frameRate = value }
        if let value = overrides.bitrateMbps { effective.bitrateMbps = value }
        if let value = overrides.codec { effective.codec = value }
        if let value = overrides.audio { effective.audio = value }
        return effective
    }

    /// The preferences one split side resolves from: only the host's codec applies, the bitrate
    /// stays global so both sides together use exactly the configured bandwidth.
    public func forSplit(applying overrides: HostOverrides) -> StreamPreferences {
        var effective = self
        if let value = overrides.codec { effective.codec = value }
        return effective
    }
}
