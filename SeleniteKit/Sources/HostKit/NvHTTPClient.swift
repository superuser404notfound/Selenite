import Foundation
import Security

/// nvhttp over URLSession: plain HTTP for serverinfo and the first pairing steps, HTTPS pinned to the
/// host certificate with our client certificate for everything else.
public final class NvHTTPClient: NSObject, NvHTTPTransport, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pinnedCertificate: Data?
    private let clientIdentity: SecIdentity?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public init(pinnedCertificate: Data?, clientIdentity: SecIdentity?) {
        self.pinnedCertificate = pinnedCertificate
        self.clientIdentity = clientIdentity
    }

    public func pinServerCertificate(_ der: Data) {
        lock.lock(); pinnedCertificate = der; lock.unlock()
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, _) = try await session.data(for: request)
        return data
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            let pinned = lock.withLock { pinnedCertificate }
            guard let pinned,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  SecCertificateCopyData(leaf) as Data == pinned else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
        if space.authenticationMethod == NSURLAuthenticationMethodClientCertificate, let clientIdentity {
            return (.useCredential, URLCredential(identity: clientIdentity, certificates: nil, persistence: .forSession))
        }
        return (.performDefaultHandling, nil)
    }
}
