import HostKit
import InputKit
import StreamKit

public struct SplitSideChoice: Codable, Equatable, Sendable {
    public var hostID: String
    public var app: AppEntry

    public init(hostID: String, app: AppEntry) {
        self.hostID = hostID
        self.app = app
    }
}

/// What a split plays (M2 spec, section 3): a host and a game per side, the layout, the format.
public struct SplitPlan: Codable, Equatable, Sendable {
    public var first: SplitSideChoice
    public var second: SplitSideChoice
    public var layout: SplitLayout
    public var format: SplitFormat

    public init(first: SplitSideChoice, second: SplitSideChoice, layout: SplitLayout, format: SplitFormat) {
        self.first = first
        self.second = second
        self.layout = layout
        self.format = format
    }

    public subscript(side: SplitSide) -> SplitSideChoice {
        get { side == .first ? first : second }
        set { if side == .first { first = newValue } else { second = newValue } }
    }

    public func involves(hostID: String) -> Bool {
        first.hostID == hostID || second.hostID == hostID
    }
}
