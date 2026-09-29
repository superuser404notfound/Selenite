import Foundation
import HostKit
import StreamKit

/// Why a solo stream failed to start or ended on its own. The app target turns each case into a
/// plain sentence (`Selenite/App/FailureText.swift`).
public enum StreamFailure: Equatable, Sendable {
    case hostUnreachable
    case timedOut
    case hostRefused(String)
    case slotBusy
    case connectionFailed(Int32)
    case stageFailed(String, Int32)
    case gameClosed
    case noVideoTraffic
    case unstableConnection
    case earlyTermination
    case protectedContent
    case frameConversion
    case connectionEnded(Int32)
    case quitFailed
    case hostDidNotWake(String)
    case unknown(String)

    public static func from(error: any Error) -> StreamFailure {
        if let session = error as? StreamSessionError {
            switch session {
            case .noFreeSlot: return .slotBusy
            case .launchFailed(let message): return .hostRefused(message)
            case .connectionFailed(let code): return .connectionFailed(code)
            case .cancelled, .alreadyStarted: return .unknown(String(describing: session))
            }
        }
        if let nvError = error as? NvError {
            switch nvError {
            case .status(_, let message): return .hostRefused(message)
            case .malformed: return .unknown("malformed host reply")
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timedOut : .hostUnreachable
        }
        return .unknown(String(describing: error))
    }

    /// moonlight-common-c's `connectionTerminated` codes (`Limelight.h`, ML_ERROR_*).
    public static func from(terminationCode code: Int32) -> StreamFailure {
        switch code {
        case 0: .gameClosed
        case -100: .noVideoTraffic
        case -101: .unstableConnection
        case -102: .earlyTermination
        case -103: .protectedContent
        case -104: .frameConversion
        default: .connectionEnded(code)
        }
    }

    /// Whether the error panel offers "Try again". Not after a failed quit: retrying would relaunch
    /// the game that was just quit.
    public var offersRetry: Bool {
        self != .quitFailed
    }
}
