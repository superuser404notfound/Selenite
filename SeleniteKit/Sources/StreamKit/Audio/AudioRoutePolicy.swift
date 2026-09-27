public enum AudioChannels: Sendable, Equatable {
    case stereo, surround51
    public var count: Int { self == .stereo ? 2 : 6 }
}

public enum AudioRoutePolicy {
    public static func channels(maximumOutputChannels: Int, forceStereo: Bool) -> AudioChannels {
        !forceStereo && maximumOutputChannels >= 6 ? .surround51 : .stereo
    }

    /// Channels the hardware output runs with: what the attached streams carry, capped by the
    /// route. Following the route instead sent stereo as 6-channel PCM, so a receiver showed 5.1.
    public static func outputChannels(streamChannels: [Int], hardwareMaximum: Int) -> Int {
        let wanted = streamChannels.max() ?? 2
        let cap = hardwareMaximum > 0 ? hardwareMaximum : 2
        return max(2, min(wanted, cap))
    }
}
