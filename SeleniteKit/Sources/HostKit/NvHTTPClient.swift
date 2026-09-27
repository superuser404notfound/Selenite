import Foundation
import Security

/// nvhttp over URLSession: plain HTTP for serverinfo and the first pairing steps, HTTPS pinned to the
/// host certificate with our client certificate for everything else.
public final class NvHTTPClient: NSObject, NvHTTPTransport, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pinnedCertificate: Data?
    /// Set by `invalidate()`: a task created on an invalidated URLSession raises an Objective-C exception.
    private var invalidated = false
    private let clientIdentity: SecIdentity?
    private var sessionStorage: URLSession!
    private var session: URLSession { sessionStorage }

    public init(pinnedCertificate: Data?, clientIdentity: SecIdentity?) {
        self.pinnedCertificate = pinnedCertificate
        self.clientIdentity = clientIdentity
        super.init()
        sessionStorage = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    public func pinServerCertificate(_ der: Data) {
        lock.lock(); pinnedCertificate = der; lock.unlock()
    }

    /// Breaks the delegate's strong reference back to this client; call once the session is done.
    public func invalidate() {
        lock.withLock { invalidated = true }
        session.finishTasksAndInvalidate()
    }

    /// Throws `CancellationError` once the client was invalidated, before any task is created.
    public func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        if lock.withLock({ invalidated }) { throw CancellationError() }
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

/// Builds `NvHTTPClient`s that carry the client identity. A `@Sendable` factory closure captures
/// this object instead of a `SecIdentity`, which is not Sendable.
public final class NvHTTPClientFactory: @unchecked Sendable {
    private let clientIdentity: SecIdentity?

    public init(clientIdentity: SecIdentity?) {
        self.clientIdentity = clientIdentity
    }

    public func make(pinnedCertificate: Data?) -> NvHTTPClient {
        NvHTTPClient(pinnedCertificate: pinnedCertificate, clientIdentity: clientIdentity)
    }
}
