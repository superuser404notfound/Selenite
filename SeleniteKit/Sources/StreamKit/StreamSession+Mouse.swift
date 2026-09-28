import Foundation
import MoonlightCore

public enum MouseButton: Sendable, Hashable, CaseIterable {
    case left
    case right

    var moonlightButton: Int32 {
        switch self {
        case .left: BUTTON_LEFT
        case .right: BUTTON_RIGHT
        }
    }
}

/// Relative mouse input for the host, sent through `whileConnected` like the controller events.
extension StreamSession {
    public func sendMouseMove(dx: Int16, dy: Int16) {
        guard dx != 0 || dy != 0 else { return }
        _ = lifecycle.whileConnected { slot.api.sendMouseMoveEvent!(dx, dy) }
    }

    public func sendMouseButton(_ button: MouseButton, pressed: Bool) {
        let action = CChar(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE)
        _ = lifecycle.whileConnected { slot.api.sendMouseButtonEvent!(action, button.moonlightButton) }
    }
}
