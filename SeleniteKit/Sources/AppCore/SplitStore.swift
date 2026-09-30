import Foundation
import InputKit
import Observation

/// The last split for the quick-start tile and each side's volume, in UserDefaults.
@MainActor @Observable
public final class SplitStore {
    static let planKey = "split.plan"
    static func volumeKey(_ side: SplitSide) -> String { "split.volume.\(side.rawValue)" }

    public private(set) var plan: SplitPlan?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        plan = defaults.data(forKey: Self.planKey).flatMap { try? JSONDecoder().decode(SplitPlan.self, from: $0) }
    }

    public func save(_ plan: SplitPlan) {
        self.plan = plan
        defaults.set(try? JSONEncoder().encode(plan), forKey: Self.planKey)
    }

    public func volume(for side: SplitSide) -> Float {
        (defaults.object(forKey: Self.volumeKey(side)) as? Double).map { Float(min(max($0, 0), 1)) } ?? 1
    }

    public func setVolume(_ volume: Float, for side: SplitSide) {
        defaults.set(Double(min(max(volume, 0), 1)), forKey: Self.volumeKey(side))
    }

    public func removeHost(id: String) {
        guard plan?.involves(hostID: id) == true else { return }
        plan = nil
        defaults.removeObject(forKey: Self.planKey)
    }
}
