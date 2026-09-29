import Foundation
import HostKit
import Observation

public enum WakeOutcome: Equatable, Sendable {
    case awake
    case timedOut
    case cancelled
}

/// Wakes one host (M1-C spec, section 4): sends the magic packet once, then asks serverinfo every
/// `interval` until it answers or `timeout` passes. `onEnd` runs exactly once per wake.
@MainActor @Observable
public final class HostWaker {
    public private(set) var wakingHostID: String?
    private let send: @Sendable (PairedHost) async -> Void
    private let probe: any ServerInfoProbe
    private let interval: Duration
    private let timeout: Duration
    @ObservationIgnored private var current: (token: UUID, task: Task<Void, Never>, onEnd: @MainActor (WakeOutcome) -> Void)?

    public init(send: @escaping @Sendable (PairedHost) async -> Void, probe: any ServerInfoProbe,
                interval: Duration = .seconds(1), timeout: Duration = .seconds(60)) {
        self.send = send
        self.probe = probe
        self.interval = interval
        self.timeout = timeout
    }

    nonisolated public static func canWake(_ host: PairedHost) -> Bool {
        host.macAddress.flatMap(MACAddress.init) != nil
    }

    public func wake(_ host: PairedHost, onEnd: @escaping @MainActor (WakeOutcome) -> Void) {
        cancel()
        let token = UUID()
        let send = self.send
        let probe = self.probe
        let interval = self.interval
        let timeout = self.timeout
        let task = Task { [weak self] in
            await send(host)
            let deadline = ContinuousClock.now + timeout
            var outcome = WakeOutcome.timedOut
            while !Task.isCancelled {
                if let info = try? await probe.serverInfo(for: host), info.uniqueID.isEmpty || info.uniqueID == host.id {
                    outcome = .awake
                    break
                }
                guard ContinuousClock.now + interval < deadline else { break }
                try? await Task.sleep(for: interval)
            }
            self?.finish(token, outcome)
        }
        wakingHostID = host.id
        current = (token, task, onEnd)
    }

    public func cancel() {
        guard let current else { return }
        self.current = nil
        wakingHostID = nil
        current.task.cancel()
        current.onEnd(.cancelled)
    }

    private func finish(_ token: UUID, _ outcome: WakeOutcome) {
        guard let current, current.token == token else { return }
        self.current = nil
        wakingHostID = nil
        current.onEnd(outcome)
    }
}
