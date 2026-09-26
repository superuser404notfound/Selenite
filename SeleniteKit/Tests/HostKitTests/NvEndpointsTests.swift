import Foundation
import Testing
@testable import HostKit

@Test func ipv4URLs() {
    let e = NvEndpoints(address: "192.168.1.20", uniqueID: "0123456789abcdef")
    #expect(e.serverInfo(secure: false).absoluteString == "http://192.168.1.20:47989/serverinfo?uniqueid=0123456789abcdef")
    #expect(e.appList().absoluteString == "https://192.168.1.20:47984/applist?uniqueid=0123456789abcdef")
}

@Test func ipv6LiteralIsBracketed() {
    let e = NvEndpoints(address: "fe80::1", uniqueID: "0123456789abcdef")
    #expect(e.serverInfo(secure: true).absoluteString == "https://[fe80::1]:47984/serverinfo?uniqueid=0123456789abcdef")
}

@Test func launchQueryMatchesMoonlight() {
    let request = LaunchRequest(
        appID: 881448767, width: 1920, height: 2160, fps: 60,
        riKey: Data(repeating: 0xab, count: 16), riKeyID: 42, hdr: false,
        surroundAudioInfo: 0x30002, gamepadMask: 1, launchQueryTail: "&corever=1")
    #expect(request.query ==
        "appid=881448767&mode=1920x2160x60&additionalStates=1&sops=0"
        + "&rikey=abababababababababababababababab&rikeyid=42&localAudioPlayMode=0"
        + "&surroundAudioInfo=196610&remoteControllersBitmap=1&gcmap=1&gcpersist=0&corever=1")
    let e = NvEndpoints(address: "10.0.0.2", uniqueID: "0123456789abcdef")
    #expect(e.launch(request, resume: true).absoluteString.hasPrefix(
        "https://10.0.0.2:47984/resume?uniqueid=0123456789abcdef&appid=881448767"))
}

@Test func hdrLaunchAddsCapabilityParameters() {
    let request = LaunchRequest(
        appID: 1, width: 3840, height: 2160, fps: 60,
        riKey: Data(count: 16), riKeyID: 0, hdr: true,
        surroundAudioInfo: 0x30002, gamepadMask: 1, launchQueryTail: "")
    #expect(request.query.contains("&hdrMode=1&clientHdrCapVersion=0"))
}

@Test func unusualAddressDoesNotCrash() {
    let e = NvEndpoints(address: "my pc", uniqueID: "0123456789abcdef")
    let url = e.serverInfo(secure: false)
    #expect(!url.absoluteString.isEmpty)
}

@Test func deviceNameIsPercentEncodedInQuery() {
    let e = NvEndpoints(address: "10.0.0.2", uniqueID: "0123456789abcdef", deviceName: "Living Room & TV")
    let url = e.pairChallenge().absoluteString
    #expect(url.contains("%20"))
    #expect(url.contains("%26"))
    let value = url.components(separatedBy: "devicename=")[1].components(separatedBy: "&updateState")[0]
    #expect(!value.contains("&"))
}
