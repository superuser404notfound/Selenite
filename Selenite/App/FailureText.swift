import AppCore
import Foundation
import HostKit

extension PairingFailure {
    var message: String {
        switch self {
        case .unreachable:
            String(localized: "The host did not answer. Check the address and that Sunshine is running.")
        case .timedOut:
            String(localized: "Pairing timed out. Enter the PIN in Sunshine's web UI within two minutes.")
        case .incorrectPIN:
            String(localized: "The PIN did not match. Try again with the new PIN.")
        case .alreadyInProgress:
            String(localized: "Sunshine is already pairing with another device. Finish or cancel that first.")
        case .declined(let reason):
            String(localized: "The host declined pairing: \(reason)")
        case .cancelled:
            String(localized: "Pairing was cancelled.")
        case .failed(let reason):
            String(localized: "Pairing failed: \(reason)")
        }
    }
}

extension StreamFailure {
    /// Plain reasons (spec 4.5); an unknown termination code reads "Connection ended (code N)".
    var message: String {
        switch self {
        case .hostUnreachable:
            String(localized: "The host could not be reached. Check that it is on and connected to the network.")
        case .timedOut:
            String(localized: "The host took too long to answer.")
        case .hostRefused(let reason):
            String(localized: "The host refused to start the game: \(reason)")
        case .slotBusy:
            String(localized: "Another stream is still running in Selenite.")
        case .connectionFailed(let code):
            String(localized: "The connection could not be set up (code \(Int(code))).")
        case .stageFailed(let stage, let code):
            String(localized: "The connection failed during \(stage) (code \(Int(code))).")
        case .gameClosed:
            String(localized: "The game was closed on the host.")
        case .noVideoTraffic:
            String(localized: "No video arrived from the host. A firewall may be blocking UDP port 47998.")
        case .unstableConnection:
            String(localized: "The connection became too unstable. Try a lower bitrate or a wired network.")
        case .earlyTermination:
            String(localized: "The host ended the stream right after it started.")
        case .protectedContent:
            String(localized: "The host stopped the stream because protected content was on screen.")
        case .frameConversion:
            String(localized: "The host could not convert the picture for streaming.")
        case .connectionEnded(let code):
            String(localized: "Connection ended (code \(Int(code)))")
        case .quitFailed:
            String(localized: "The game could not be quit on the host.")
        case .unknown(let reason):
            String(localized: "Something went wrong: \(reason)")
        }
    }
}
