import AppCore
import InputKit
import StreamKit
import UIKit

/// Moved from the harness: ControllerFeedback's five methods are nonisolated and match
/// ControllerFeedbackHandler exactly, so the conformance costs nothing.
extension ControllerFeedback: @retroactive ControllerFeedbackHandler {}

/// Controllers for one solo stream: every pad goes to the session on slot A, host feedback comes back.
@MainActor
final class ControllerInput: StreamInput {
    private var manager: ControllerManager?
    private var feedback: ControllerFeedback?

    func begin(session: any StreamSessionHandle) {
        guard manager == nil, let session = session as? StreamSession else { return }
        let manager = ControllerManager(sink: session)
        let feedback = ControllerFeedback(manager: manager)
        feedback.sink = session
        session.feedbackHandler = feedback
        self.manager = manager
        self.feedback = feedback
        manager.start()
        // Before the session can hand the host anything to send feedback for.
        feedback.resume()
    }

    func sessionConnected() {
        manager?.reannounce()
    }

    func setForwarding(_ forwarding: Bool) {
        manager?.isForwarding = forwarding
    }

    /// Manager first (it lifts every button on the host), then feedback, then forget both.
    func end() {
        manager?.stop()
        feedback?.stopAll()
        manager = nil
        feedback = nil
    }
}

@MainActor
enum DisplayModeReader {
    /// The Apple TV's current output mode, for "Match display": a 4K TV reads 3840x2160 at 60.
    static func current() -> DisplayMode {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        guard let screen else { return StreamSettingsResolver.fallbackDisplay }
        let size = screen.currentMode?.size ?? screen.nativeBounds.size
        return DisplayMode(width: Int(size.width), height: Int(size.height), refreshRate: screen.maximumFramesPerSecond)
    }
}
