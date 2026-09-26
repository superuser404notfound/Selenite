public enum AudioChannels: Sendable, Equatable {
    case stereo, surround51
    public var count: Int { self == .stereo ? 2 : 6 }
}

public enum AudioRoutePolicy {
    public static func channels(maximumOutputChannels: Int, forceStereo: Bool) -> AudioChannels {
        !forceStereo && maximumOutputChannels >= 6 ? .surround51 : .stereo
    }
}
