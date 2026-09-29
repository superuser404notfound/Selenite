import Darwin
import Foundation

public struct IPv4Interface: Sendable, Equatable {
    /// Host byte order.
    public let address: UInt32
    public let netmask: UInt32

    public init(address: UInt32, netmask: UInt32) {
        self.address = address
        self.netmask = netmask
    }
}

public struct WakeSendResult: Sendable, Equatable {
    public let destination: String
    /// `errno` of the last failed send to this destination, nil when it went out.
    public let errorCode: Int32?

    public init(destination: String, errorCode: Int32?) {
        self.destination = destination
        self.errorCode = errorCode
    }
}

/// The Wake-on-LAN magic packet over UDP: to the limited broadcast, to each local subnet's
/// directed broadcast, and straight to the host's last address (M1-C spec, section 4).
public enum WakeOnLAN {
    public static let port: UInt16 = 9

    public static func packet(for mac: MACAddress) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac.bytes) }
        return packet
    }

    /// A hostname as last address is left out: a sleeping host does not answer its name.
    public static func destinations(lastAddress: String, interfaces: [IPv4Interface]) -> [String] {
        var result = ["255.255.255.255"]
        for interface in interfaces where interface.netmask != 0xFFFF_FFFF {
            let broadcast = format(interface.address | ~interface.netmask)
            if !result.contains(broadcast) { result.append(broadcast) }
        }
        var probe = in_addr()
        if inet_pton(AF_INET, lastAddress, &probe) == 1, !result.contains(lastAddress) {
            result.append(lastAddress)
        }
        return result
    }

    /// Up, non-loopback IPv4 interfaces.
    public static func currentInterfaces() -> [IPv4Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [IPv4Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            result.append(IPv4Interface(address: hostOrder(address), netmask: hostOrder(netmask)))
        }
        return result
    }

    public static func send(_ packet: Data, to destinations: [String], port: UInt16, repeats: Int) -> [WakeSendResult] {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else {
            return destinations.map { WakeSendResult(destination: $0, errorCode: errno) }
        }
        defer { close(socket) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var errors: [String: Int32?] = [:]
        for _ in 0..<max(repeats, 1) {
            for destination in destinations {
                var target = sockaddr_in()
                target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = port.bigEndian
                guard inet_pton(AF_INET, destination, &target.sin_addr) == 1 else {
                    errors[destination] = EINVAL
                    continue
                }
                let sent = packet.withUnsafeBytes { raw in
                    withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socket, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                errors[destination] = sent < 0 ? errno : nil
            }
        }
        return destinations.map { WakeSendResult(destination: $0, errorCode: errors[$0] ?? nil) }
    }

    /// Blocking but short: call it off the main actor.
    public static func wake(_ host: PairedHost) -> [WakeSendResult] {
        guard let mac = host.macAddress.flatMap(MACAddress.init) else { return [] }
        return send(packet(for: mac), to: destinations(lastAddress: host.address, interfaces: currentInterfaces()),
                    port: port, repeats: 3)
    }

    private static func hostOrder(_ address: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }

    private static func format(_ address: UInt32) -> String {
        "\(address >> 24 & 0xFF).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }
}
