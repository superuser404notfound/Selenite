import Darwin
import Foundation
import Testing
@testable import HostKit

@Test func packetIsSixFFThenTheMACSixteenTimes() throws {
    let mac = try #require(MACAddress("00:11:22:33:44:55"))
    let packet = WakeOnLAN.packet(for: mac)
    #expect(packet.count == 102)
    #expect(Array(packet.prefix(6)) == Array(repeating: 0xFF, count: 6))
    for copy in 0..<16 {
        let start = 6 + copy * 6
        #expect(Array(packet[start..<start + 6]) == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
    }
}

@Test func destinationsAreBroadcastSubnetAndLastAddress() {
    let lan = IPv4Interface(address: 0xC0A8_0114, netmask: 0xFFFF_FF00) // 192.168.1.20/24
    #expect(WakeOnLAN.destinations(lastAddress: "192.168.1.50", interfaces: [lan])
            == ["255.255.255.255", "192.168.1.255", "192.168.1.50"])
}

@Test func destinationsSkipHostnamesDuplicatesAndPointToPointMasks() {
    let lan = IPv4Interface(address: 0x0A00_0005, netmask: 0xFF00_0000) // 10.0.0.5/8
    let tunnel = IPv4Interface(address: 0x0A08_0001, netmask: 0xFFFF_FFFF)
    #expect(WakeOnLAN.destinations(lastAddress: "gaming-pc.local", interfaces: [lan, lan, tunnel])
            == ["255.255.255.255", "10.255.255.255"])
}

@Test func sendDeliversThePacketOverUDP() throws {
    let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    #expect(receiver >= 0)
    defer { close(receiver) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(receiver, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    #expect(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(receiver, $0, &length) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let mac = try #require(MACAddress("00:11:22:33:44:55"))
    let results = WakeOnLAN.send(WakeOnLAN.packet(for: mac), to: ["127.0.0.1"], port: port, repeats: 1)
    #expect(results == [WakeSendResult(destination: "127.0.0.1", errorCode: nil)])
    var buffer = [UInt8](repeating: 0, count: 200)
    let received = recv(receiver, &buffer, buffer.count, 0)
    #expect(received == 102)
}

@Test func aHostWithoutAMACIsNotWoken() {
    let host = PairedHost(id: "A", name: "PC", address: "10.0.0.2", httpsPort: 47984, serverCertificateDER: Data([1]))
    #expect(WakeOnLAN.wake(host).isEmpty)
}
