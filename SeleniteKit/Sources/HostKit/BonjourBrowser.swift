import Foundation
import Network
import os

/// `_nvstream._tcp` over NWBrowser. Each added service is resolved to an IPv4 address by opening
/// a TCP connection to it and reading the path's remote endpoint; the connection is closed again.
public struct BonjourBrowser: ServiceBrowsing {
    public init() {}

    public func events() -> AsyncStream<BrowseEvent> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "selenite.bonjour")
            let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { _, changes in
                for change in changes {
                    switch change {
                    case .added(let result):
                        guard case .service(let name, _, _, _) = result.endpoint else { continue }
                        Self.resolve(result.endpoint, on: queue) { address in
                            if let address { continuation.yield(.found(service: name, address: address)) }
                        }
                    case .removed(let result):
                        guard case .service(let name, _, _, _) = result.endpoint else { continue }
                        continuation.yield(.lost(service: name))
                    default:
                        continue
                    }
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    private static func resolve(_ endpoint: NWEndpoint, on queue: DispatchQueue, done: @escaping @Sendable (String?) -> Void) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let finish: @Sendable (String?) -> Void = { address in
            guard finished.withLock({ state in defer { state = true }; return !state }) else { return }
            connection.cancel()
            done(address)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let ipv4) = host {
                    var address = "\(ipv4)"
                    if let percent = address.firstIndex(of: "%") {
                        address = String(address[address.startIndex..<percent])
                    }
                    finish(address)
                } else {
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(nil) }
    }
}
