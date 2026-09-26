import MoonlightCore
import MoonlightSlotA
import MoonlightSlotB

public enum Slot: Int, Sendable, CaseIterable {
    case a = 0, b = 1

    public var api: MLSlotAPI { self == .a ? MLSlotA : MLSlotB }
}
