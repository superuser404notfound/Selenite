import Foundation
import Testing
@testable import HostKit

/// A task on an invalidated URLSession raises an Objective-C exception; the client refuses first.
@Test func requestAfterInvalidateIsCancelledInsteadOfReachingTheSession() async {
    let client = NvHTTPClient(pinnedCertificate: nil, clientIdentity: nil)
    client.invalidate()
    let url = URL(string: "http://127.0.0.1:9/serverinfo")!
    await #expect(throws: CancellationError.self) {
        _ = try await client.get(url, timeout: 1)
    }
}
