import Foundation
import HostKit

public protocol HostCommands: Sendable {
    /// Quits the app running on the host (`/cancel`).
    func quitApp(on host: PairedHost) async throws
}

public struct LiveHostCommands: HostCommands {
    private let uniqueID: String
    private let clients: NvHTTPClientFactory

    public init(uniqueID: String, clients: NvHTTPClientFactory) {
        self.uniqueID = uniqueID
        self.clients = clients
    }

    public func quitApp(on host: PairedHost) async throws {
        let client = clients.make(pinnedCertificate: host.serverCertificateDER)
        defer { client.invalidate() }
        let endpoints = NvEndpoints(address: host.address, httpsPort: host.httpsPort, uniqueID: uniqueID)
        _ = try NvResponse.parse(try await client.get(endpoints.cancel(), timeout: 30)).requireOK()
    }
}
