import Foundation

public struct PairedHost: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var address: String
    public var httpsPort: Int
    public var serverCertificateDER: Data
    /// From the paired serverinfo, for Wake-on-LAN; nil until a poll reported one.
    public var macAddress: String?

    public init(id: String, name: String, address: String, httpsPort: Int, serverCertificateDER: Data,
                macAddress: String? = nil) {
        self.id = id; self.name = name; self.address = address
        self.httpsPort = httpsPort; self.serverCertificateDER = serverCertificateDER
        self.macAddress = macAddress
    }
}
