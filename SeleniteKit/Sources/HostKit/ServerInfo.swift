import Foundation

public struct ServerInfo: Sendable, Equatable {
    public let hostname: String
    public let appVersion: String
    public let gfeVersion: String
    public let uniqueID: String
    public let state: String
    public let httpsPort: Int
    public let codecModeSupport: Int32
    public let isPaired: Bool

    /// Sunshine reports a running session as a state ending in `_SERVER_BUSY`; launch then becomes resume.
    public var isBusy: Bool { state.hasSuffix("_SERVER_BUSY") }
    /// Pairing hashes with SHA-256 from generation 7 on, SHA-1 before.
    public var majorVersion: Int { Int(appVersion.prefix { $0 != "." }) ?? 0 }

    public init(_ response: NvResponse) throws {
        guard let appVersion = response["appversion"] else { throw NvError.malformed }
        self.hostname = response["hostname"] ?? ""
        self.appVersion = appVersion
        self.gfeVersion = response["GfeVersion"] ?? ""
        self.uniqueID = response["uniqueid"] ?? ""
        self.state = response["state"] ?? ""
        self.httpsPort = response["HttpsPort"].flatMap(Int.init) ?? 47984
        self.codecModeSupport = response["ServerCodecModeSupport"].flatMap(Int32.init) ?? 0
        self.isPaired = response["PairStatus"] == "1"
    }
}

public struct AppEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let title: String
    public let supportsHDR: Bool

    public init(id: Int, title: String, supportsHDR: Bool) {
        self.id = id
        self.title = title
        self.supportsHDR = supportsHDR
    }

    public static func list(_ response: NvResponse) -> [AppEntry] {
        response.apps.compactMap { app in
            guard let id = app["ID"].flatMap(Int.init), let title = app["AppTitle"] else { return nil }
            return AppEntry(id: id, title: title, supportsHDR: app["IsHdrSupported"] == "1")
        }
    }
}
