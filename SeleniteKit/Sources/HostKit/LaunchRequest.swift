import Foundation

public struct LaunchRequest: Sendable {
    public var appID: Int
    public var width: Int
    public var height: Int
    public var fps: Int
    public var riKey: Data
    public var riKeyID: Int32
    public var hdr: Bool
    public var surroundAudioInfo: Int
    public var gamepadMask: Int
    /// `LiGetLaunchUrlQueryParameters()` of the slot that will run the session.
    public var launchQueryTail: String

    public init(appID: Int, width: Int, height: Int, fps: Int, riKey: Data, riKeyID: Int32, hdr: Bool,
                surroundAudioInfo: Int, gamepadMask: Int, launchQueryTail: String) {
        self.appID = appID; self.width = width; self.height = height; self.fps = fps
        self.riKey = riKey; self.riKeyID = riKeyID; self.hdr = hdr
        self.surroundAudioInfo = surroundAudioInfo; self.gamepadMask = gamepadMask
        self.launchQueryTail = launchQueryTail
    }

    /// Same parameters and order as Moonlight's newLaunchOrResumeRequest, without the uniqueid.
    public var query: String {
        var q = "appid=\(appID)&mode=\(width)x\(height)x\(fps)&additionalStates=1&sops=0"
        q += "&rikey=\(riKey.hexString)&rikeyid=\(riKeyID)"
        if hdr {
            q += "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0"
            q += "&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"
        }
        q += "&localAudioPlayMode=0&surroundAudioInfo=\(surroundAudioInfo)"
        q += "&remoteControllersBitmap=\(gamepadMask)&gcmap=\(gamepadMask)&gcpersist=0"
        q += launchQueryTail
        return q
    }
}
