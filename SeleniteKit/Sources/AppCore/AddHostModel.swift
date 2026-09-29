import Foundation
import HostKit
import Observation

public enum AddHostPhase: Equatable, Sendable {
    case enterAddress
    case checking
    case showingPIN(String)
    case failed(PairingFailure)
    case finished(PairedHost)
}

/// The state of the Add host panel over `PairingFlow` (M1-B spec, section 4.2). "Pair again"
/// enters at the check with the stored address and always runs the PIN handshake.
@MainActor @Observable
public final class AddHostModel {
    public var address: String
    public private(set) var phase: AddHostPhase
    public let isPairAgain: Bool
    private let startsAtOnce: Bool
    private let flow: PairingFlow
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(flow: PairingFlow, pairAgainAddress: String? = nil, discoveredAddress: String? = nil) {
        self.flow = flow
        self.address = pairAgainAddress ?? discoveredAddress ?? ""
        self.isPairAgain = pairAgainAddress != nil
        self.startsAtOnce = pairAgainAddress != nil || discoveredAddress != nil
        self.phase = startsAtOnce ? .checking : .enterAddress
    }

    /// Pair again and a discovered host start right away; a new host waits for `submit()`.
    public func begin() {
        if startsAtOnce { submit() }
    }

    public func submit() {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, task == nil else { return }
        phase = .checking
        let force = isPairAgain
        task = Task { await self.run(address: address, force: force) }
    }

    /// "Try again": a new host goes back to the address (kept, so a typo can be fixed), pair again
    /// and a discovered host retry at once.
    public func retry() {
        guard task == nil else { return }
        if startsAtOnce {
            submit()
        } else {
            phase = .enterAddress
        }
    }

    /// The panel closed. A cancelled run leaves the phase alone; Pairing unpairs on the host.
    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(address: String, force: Bool) async {
        let result: Result<PairingOutcome, PairingFailure>
        do {
            let outcome = try await flow.run(address: address, forcePairing: force) { [weak self] pin in
                self?.phase = .showingPIN(pin)
            }
            result = .success(outcome)
        } catch let failure as PairingFailure {
            result = .failure(failure)
        } catch {
            result = .failure(.failed(String(describing: error)))
        }
        guard !Task.isCancelled else { return }
        task = nil
        switch result {
        case .success(.paired(let host)), .success(.alreadyPaired(let host)):
            phase = .finished(host)
        case .failure(let failure):
            phase = .failed(failure)
        }
    }
}
