import Foundation
import QuartzCore
import Synchronization

/// Device-round diagnostics: per-second counters for the hot paths, read and reset once a second
/// by the harness. Temporary; removed once the M1-A regression is understood.
public final class DiagnosticCounters: Sendable {
    public static let shared = DiagnosticCounters()

    public struct Snapshot: Sendable {
        public var audioCalls = 0, audioMaxCallMicros = 0, audioMaxGapMicros = 0
        public var videoFrames = 0, videoMaxProcessMicros = 0, videoMaxGapMicros = 0
        public var controllerStates = 0, controllerMotions = 0, controllerTouches = 0
        public var controllerMaxSendMicros = 0
    }

    private struct State {
        var snapshot = Snapshot()
        var lastAudio: Double = 0
        var lastVideo: Double = 0
    }

    private let state = Mutex(State())

    public func audioCall(start: Double, end: Double) {
        state.withLock { s in
            s.snapshot.audioCalls += 1
            s.snapshot.audioMaxCallMicros = max(s.snapshot.audioMaxCallMicros, Int((end - start) * 1_000_000))
            if s.lastAudio > 0 { s.snapshot.audioMaxGapMicros = max(s.snapshot.audioMaxGapMicros, Int((start - s.lastAudio) * 1_000_000)) }
            s.lastAudio = start
        }
    }

    public func videoFrame(start: Double, end: Double) {
        state.withLock { s in
            s.snapshot.videoFrames += 1
            s.snapshot.videoMaxProcessMicros = max(s.snapshot.videoMaxProcessMicros, Int((end - start) * 1_000_000))
            if s.lastVideo > 0 { s.snapshot.videoMaxGapMicros = max(s.snapshot.videoMaxGapMicros, Int((start - s.lastVideo) * 1_000_000)) }
            s.lastVideo = start
        }
    }

    public enum ControllerKindOfSend: Sendable { case state, motion, touch }

    public func controllerSend(_ kind: ControllerKindOfSend, start: Double, end: Double) {
        state.withLock { s in
            switch kind {
            case .state: s.snapshot.controllerStates += 1
            case .motion: s.snapshot.controllerMotions += 1
            case .touch: s.snapshot.controllerTouches += 1
            }
            s.snapshot.controllerMaxSendMicros = max(s.snapshot.controllerMaxSendMicros, Int((end - start) * 1_000_000))
        }
    }

    public func takeSnapshot() -> Snapshot {
        state.withLock { s in
            let snapshot = s.snapshot
            s.snapshot = Snapshot()
            return snapshot
        }
    }
}
