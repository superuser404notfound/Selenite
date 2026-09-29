import Foundation

/// A host's Ethernet address for Wake-on-LAN. Sunshine reports `00:00:00:00:00:00` when it
/// does not know it, which is no address at all.
public struct MACAddress: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ text: String) {
        let separator: Character = text.contains(":") ? ":" : "-"
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.count == 2, part.allSatisfy(\.isHexDigit), let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = bytes
    }

    public var description: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// A container's virtual NIC, not the host's real one: the locally administered bit
    /// (`02:42:...` for Docker) or Incus/LXD's default `00:16:3E` prefix. Wakes nothing.
    public var isVirtual: Bool {
        bytes[0] & 0x02 != 0 || bytes[0] == 0x00 && bytes[1] == 0x16 && bytes[2] == 0x3E
    }
}
