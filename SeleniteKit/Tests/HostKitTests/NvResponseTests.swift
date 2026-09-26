import Foundation
import Testing
@testable import HostKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func parsesServerInfo() throws {
    let info = try ServerInfo(NvResponse.parse(fixture("serverinfo")).requireOK())
    #expect(info.hostname == "GAMING-PC")
    #expect(info.httpsPort == 47984)
    #expect(info.codecModeSupport == 259)
    #expect(info.isPaired)
    #expect(!info.isBusy)
    #expect(info.majorVersion == 7)
}

@Test func parsesAppList() throws {
    let apps = AppEntry.list(try NvResponse.parse(fixture("applist")).requireOK())
    #expect(apps == [
        AppEntry(id: 881448767, title: "Desktop", supportsHDR: true),
        AppEntry(id: 1093255277, title: "Steam Big Picture", supportsHDR: false),
    ])
}

@Test func parsesLaunchSessionURL() throws {
    let response = try NvResponse.parse(fixture("launch")).requireOK()
    #expect(response["sessionUrl0"] == "rtsp://192.168.1.20:48010")
}

@Test func unauthorizedSurfacesHostMessage() throws {
    let response = try NvResponse.parse(fixture("unauthorized"))
    #expect(throws: NvError.status(401, "The client is not authorized. Certificate verification failed.")) {
        try response.requireOK()
    }
}

@Test func garbageIsMalformed() {
    #expect(throws: NvError.malformed) { try NvResponse.parse(Data("not xml".utf8)) }
}
