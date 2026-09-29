import Foundation

public struct PairedHost: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var address: String
    public var httpsPort: Int
    public var serverCertificateDER: Data
    /// From the paired serverinfo, for Wake-on-LAN; nil until a poll reported one.
    public var macAddress: String?
    /// The per-host switch (Home > host card, long press). nil means automatic: a virtual MAC
    /// (a container's, not the physical host's) defaults to off, a real one to on.
    public var wakeOnLAN: Bool?

    public init(id: String, name: String, address: String, httpsPort: Int, serverCertificateDER: Data,
                macAddress: String? = nil, wakeOnLAN: Bool? = nil) {
        self.id = id; self.name = name; self.address = address
        self.httpsPort = httpsPort; self.serverCertificateDER = serverCertificateDER
        self.macAddress = macAddress
        self.wakeOnLAN = wakeOnLAN
    }

    /// The switch's effective state: the explicit choice, or automatic (off for a virtual MAC).
    public var wakesOnLAN: Bool {
        guard let mac = macAddress.flatMap(MACAddress.init) else { return false }
        return wakeOnLAN ?? !mac.isVirtual
    }
}
