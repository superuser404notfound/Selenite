import Foundation

public struct NvEndpoints: Sendable {
    public let address: String
    public let httpPort: Int
    public let httpsPort: Int
    public let uniqueID: String
    public let deviceName: String

    public init(address: String, httpPort: Int = 47989, httpsPort: Int = 47984,
                uniqueID: String, deviceName: String = "Selenite") {
        self.address = address; self.httpPort = httpPort; self.httpsPort = httpsPort
        self.uniqueID = uniqueID; self.deviceName = deviceName
    }

    private var urlHost: String { address.contains(":") ? "[\(address)]" : address }
    private var http: String { "http://\(urlHost):\(httpPort)" }
    private var https: String { "https://\(urlHost):\(httpsPort)" }
    private var pairPrefix: String {
        let encodedDeviceName = deviceName.addingPercentEncoding(withAllowedCharacters: Self.deviceNameQueryCharacters) ?? deviceName
        return "uniqueid=\(uniqueID)&devicename=\(encodedDeviceName)&updateState=1"
    }

    /// `.urlQueryAllowed` still permits `&`, `=`, `+` and `#`, which are query syntax, not safe
    /// inside a value: an unescaped `&` in a device name would split the query into bogus pairs.
    private static let deviceNameQueryCharacters =
        CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))

    /// Never crashes: a user-typed address (e.g. "my pc") or odd device name must fail the
    /// request, not the app. Falls back to an unroutable placeholder if even lenient encoding
    /// can't produce a URL.
    private func url(_ string: String) -> URL {
        URL(string: string, encodingInvalidCharacters: true) ?? URL(string: "http://invalid.invalid/")!
    }

    public func serverInfo(secure: Bool) -> URL {
        url("\(secure ? https : http)/serverinfo?uniqueid=\(uniqueID)")
    }
    public func pairGetServerCert(salt: Data, clientCertPEM: Data) -> URL {
        url("\(http)/pair?\(pairPrefix)&phrase=getservercert&salt=\(salt.hexString)&clientcert=\(clientCertPEM.hexString)")
    }
    public func pairClientChallenge(_ encrypted: Data) -> URL {
        url("\(http)/pair?\(pairPrefix)&clientchallenge=\(encrypted.hexString)")
    }
    public func pairServerChallengeResponse(_ encrypted: Data) -> URL {
        url("\(http)/pair?\(pairPrefix)&serverchallengeresp=\(encrypted.hexString)")
    }
    public func pairClientPairingSecret(_ secret: Data) -> URL {
        url("\(http)/pair?\(pairPrefix)&clientpairingsecret=\(secret.hexString)")
    }
    public func pairChallenge() -> URL {
        url("\(https)/pair?\(pairPrefix)&phrase=pairchallenge")
    }
    public func unpair() -> URL { url("\(http)/unpair?uniqueid=\(uniqueID)") }
    public func appList() -> URL { url("\(https)/applist?uniqueid=\(uniqueID)") }
    /// Box art (Sunshine returns a PNG), same parameters as Moonlight's app asset request.
    public func appAsset(appID: Int) -> URL {
        url("\(https)/appasset?uniqueid=\(uniqueID)&appid=\(appID)&AssetType=2&AssetIdx=0")
    }
    public func launch(_ request: LaunchRequest, resume: Bool) -> URL {
        url("\(https)/\(resume ? "resume" : "launch")?uniqueid=\(uniqueID)&\(request.query)")
    }
    public func cancel() -> URL { url("\(https)/cancel?uniqueid=\(uniqueID)") }
}
