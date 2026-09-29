import Foundation
import Testing
@testable import HostKit

@Test func macAcceptsColonsDashesAndAnyCase() {
    #expect(MACAddress("00:11:22:aa:BB:cc")?.bytes == [0x00, 0x11, 0x22, 0xAA, 0xBB, 0xCC])
    #expect(MACAddress("00-11-22-AA-BB-CC")?.description == "00:11:22:AA:BB:CC")
}

@Test func macRejectsMalformedAndAllZero() {
    #expect(MACAddress("00:00:00:00:00:00") == nil)
    #expect(MACAddress("00:11:22:33:44") == nil)
    #expect(MACAddress("00:11:22:33:44:5G") == nil)
    #expect(MACAddress("+0:11:22:33:44:55") == nil)
    #expect(MACAddress("001:1:22:33:44:55") == nil)
    #expect(MACAddress("") == nil)
}

@Test func serverInfoReadsTheMAC() throws {
    let url = Bundle.module.url(forResource: "serverinfo", withExtension: "xml", subdirectory: "Fixtures")!
    let info = try ServerInfo(NvResponse.parse(Data(contentsOf: url)))
    #expect(info.macAddress?.description == "00:11:22:33:44:55")
}

@Test func pairedHostsSavedBeforeM1CStillDecode() throws {
    let old = #"[{"id":"A","name":"PC","address":"10.0.0.2","httpsPort":47984,"serverCertificateDER":"AQ=="}]"#
    let hosts = try JSONDecoder().decode([PairedHost].self, from: Data(old.utf8))
    #expect(hosts.first?.macAddress == nil)
    #expect(hosts.first?.wakeOnLAN == nil)
    #expect(hosts.first?.id == "A")
}

@Test func isVirtualDetectsLocallyAdministeredAndTheIncusPrefix() {
    #expect(MACAddress("00:16:3e:12:34:56")!.isVirtual)
    #expect(MACAddress("02:42:ac:11:00:02")!.isVirtual)
    #expect(!MACAddress("00:11:22:33:44:55")!.isVirtual)
    #expect(!MACAddress("A4:BB:6D:01:02:03")!.isVirtual)
}
