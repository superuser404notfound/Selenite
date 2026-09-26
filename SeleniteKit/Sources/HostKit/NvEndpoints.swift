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
    private var pairPrefix: String { "uniqueid=\(uniqueID)&devicename=\(deviceName)&updateState=1" }

    private func url(_ string: String) -> URL { URL(string: string)! }

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
    public func launch(_ request: LaunchRequest, resume: Bool) -> URL {
        url("\(https)/\(resume ? "resume" : "launch")?uniqueid=\(uniqueID)&\(request.query)")
    }
    public func cancel() -> URL { url("\(https)/cancel?uniqueid=\(uniqueID)") }
}
