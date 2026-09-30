import Foundation
import HostKit
import InputKit
import Observation
import StreamKit

/// The split wizard's steps (M2 spec, section 4): host and game for side 1, the same for side 2,
/// then layout and format. `replacing:in:` is the one-side wizard for a side that ended.
@MainActor @Observable
public final class SplitWizardModel: Identifiable {
    public enum Step: Equatable, Sendable {
        case host(SplitSide)
        case game(SplitSide)
        case layout
    }

    public let id = UUID()
    public private(set) var step: Step
    public private(set) var hostIDs: [SplitSide: String] = [:]
    public private(set) var apps: [SplitSide: AppEntry] = [:]
    public var layout: SplitLayout
    public var format: SplitFormat
    /// Set in one-side mode: the side being replaced and the plan it belongs to.
    public let replacing: SplitSide?
    private let basePlan: SplitPlan?

    public init(startingFrom plan: SplitPlan? = nil) {
        step = .host(.first)
        layout = plan?.layout ?? .sideBySide
        format = plan?.format ?? .fillHalf
        replacing = nil
        basePlan = nil
    }

    public init(replacing side: SplitSide, in plan: SplitPlan) {
        step = .host(side)
        layout = plan.layout
        format = plan.format
        replacing = side
        basePlan = plan
        hostIDs[side.other] = plan[side.other].hostID
        apps[side.other] = plan[side.other].app
    }

    /// A Sunshine host streams one session at a time, so the other side's host is off limits.
    public func isHostSelectable(_ hostID: String) -> Bool {
        guard case .host(let side) = step else { return true }
        return hostIDs[side.other] != hostID
    }

    public var currentSide: SplitSide? {
        switch step {
        case .host(let side), .game(let side): side
        case .layout: nil
        }
    }

    public func chooseHost(_ hostID: String) {
        guard case .host(let side) = step, isHostSelectable(hostID) else { return }
        hostIDs[side] = hostID
        step = .game(side)
    }

    public func chooseGame(_ app: AppEntry) {
        guard case .game(let side) = step else { return }
        apps[side] = app
        if replacing != nil {
            step = .layout
        } else {
            step = side == .first ? .host(.second) : .layout
        }
    }

    /// False when there is nothing to go back to: the caller closes the wizard.
    public func back() -> Bool {
        switch step {
        case .host(let side):
            guard replacing == nil, side == .second else { return false }
            step = .game(.first)
        case .game(let side):
            step = .host(side)
        case .layout:
            if let side = replacing {
                step = .game(side)
            } else {
                step = .game(.second)
            }
        }
        return true
    }

    /// The finished plan; nil until every choice is made. In one-side mode `.layout` means done.
    public func finish() -> SplitPlan? {
        guard step == .layout,
              let firstHost = hostIDs[.first], let firstApp = apps[.first],
              let secondHost = hostIDs[.second], let secondApp = apps[.second] else { return nil }
        return SplitPlan(first: SplitSideChoice(hostID: firstHost, app: firstApp),
                         second: SplitSideChoice(hostID: secondHost, app: secondApp),
                         layout: basePlan?.layout ?? layout, format: basePlan?.format ?? format)
    }
}
