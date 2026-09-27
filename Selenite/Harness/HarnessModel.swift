import Foundation
import HostKit
import InputKit
import MoonlightCore
import Observation
import StreamKit

enum SplitLayout: String, CaseIterable, Identifiable {
    case solo, sideBySide, topBottom
    var id: String { rawValue }
}

struct SideChoice: Equatable {
    var hostID: String?
    var appID: Int?
}

/// Signatures already match `ControllerFeedbackHandler` exactly (each of `ControllerFeedback`'s
/// five methods is declared `nonisolated` on the `@MainActor` class), so the conformance costs
/// nothing: no isolation mismatch, InputKit untouched.
extension ControllerFeedback: ControllerFeedbackHandler {}

@Observable @MainActor
final class HarnessModel {
    let identity: ClientIdentity
    let hostStore = HostStore()
    var hosts: [PairedHost] = []
    var apps: [String: [AppEntry]] = [:]
    var status = ""
    var pairingPIN: String?
    var isPairing = false
    var newAddress = ""
    var layout: SplitLayout = .solo
    var sideA = SideChoice()
    var sideB = SideChoice()
    var bitrateMbps = 150
    var hdr = false
    var forceStereo = false
    var sessions: [StreamSession] = []
    /// The latest session event per half, index-aligned with `sessions`.
    var eventTexts: [String] = []
    /// The audio channel layout actually requested per half, index-aligned with `sessions`.
    var audioChannels: [AudioChannels] = []
    var isStreaming = false
    private var eventTasks: [Task<Void, Never>] = []
    private var controllerManager: ControllerManager?
    private var controllerFeedback: ControllerFeedback?

    init() {
        do {
            identity = try IdentityStore.loadOrCreate()
        } catch {
            identity = try! ClientIdentity.generate()
            status = "Keychain unavailable, pairings will not persist: \(error)"
        }
        hosts = hostStore.all()
        MLSetLogSink(seleniteLogSink)
    }

    func pair() async {
        let address = newAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        let client = NvHTTPClient(pinnedCertificate: nil, clientIdentity: try? IdentityStore.secIdentity(for: identity))
        defer { client.invalidate() }
        let endpoints = NvEndpoints(address: address, uniqueID: identity.uniqueID)
        do {
            let info = try ServerInfo(NvResponse.parse(try await client.get(endpoints.serverInfo(secure: false), timeout: 5)).requireOK())
            let pin = Pairing.makePIN()
            pairingPIN = pin
            status = "Enter \(pin) in the Sunshine web UI of \(info.hostname)"
            let cert = try await Pairing(transport: client, endpoints: endpoints, identity: identity)
                .run(pin: pin, serverMajorVersion: info.majorVersion)
            let host = PairedHost(id: info.uniqueID, name: info.hostname, address: address,
                                  httpsPort: info.httpsPort, serverCertificateDER: cert)
            hostStore.save(host)
            hosts = hostStore.all()
            status = "Paired with \(info.hostname)"
        } catch {
            status = "Pairing failed: \(error)"
        }
        pairingPIN = nil
    }

    func loadApps(for host: PairedHost) async {
        do {
            let client = NvHTTPClient(pinnedCertificate: host.serverCertificateDER,
                                      clientIdentity: try IdentityStore.secIdentity(for: identity))
            defer { client.invalidate() }
            let endpoints = NvEndpoints(address: host.address, httpsPort: host.httpsPort, uniqueID: identity.uniqueID)
            apps[host.id] = AppEntry.list(try NvResponse.parse(try await client.get(endpoints.appList(), timeout: 10)).requireOK())
        } catch {
            status = "App list failed for \(host.name): \(error)"
        }
    }

    /// 4K panel: a side-by-side half is 1920x2160, a top-bottom half 3840x1080. `maximumOutputChannels`
    /// is read by the caller before this is invoked, off the main thread: reading it here would read
    /// it on whatever thread computes settings, and every existing caller does that on the main actor.
    func settings(for layout: SplitLayout, maximumOutputChannels: Int) -> StreamSettings {
        let (width, height) = switch layout {
        case .solo: (3840, 2160)
        case .sideBySide: (1920, 2160)
        case .topBottom: (3840, 1080)
        }
        // Split is always a stereo mix; only solo can offer 5.1 (M2 revisits per-side audio).
        let audio: AudioChannels = layout == .solo
            ? AudioRoutePolicy.channels(maximumOutputChannels: maximumOutputChannels, forceStereo: forceStereo)
            : .stereo
        return StreamSettings(width: width, height: height, fps: 60, bitrateKbps: bitrateMbps * 1000,
                              hdr: layout == .solo && hdr, audio: audio)
    }

    func start() async {
        let choices = layout == .solo ? [sideA] : [sideA, sideB]
        // Resolve and validate every side before acquiring any slot, so a missing choice on a
        // later side never leaves an earlier side's already-constructed session (and its slot)
        // stranded.
        var resolved: [(host: PairedHost, appID: Int)] = []
        for choice in choices {
            guard let host = hosts.first(where: { $0.id == choice.hostID }), let appID = choice.appID else {
                status = "Pick a host and an app for every side"
                return
            }
            resolved.append((host, appID))
        }
        do {
            let secIdentity = try IdentityStore.secIdentity(for: identity)
            // Activates the audio session and can block briefly: hop off the main actor for it
            // rather than paying that cost inline here or, worse, in a SwiftUI body.
            let maximumOutputChannels = await Task.detached { AudioOutput.shared.maximumOutputChannels }.value
            var started: [StreamSession] = []
            var channels: [AudioChannels] = []
            do {
                for (host, appID) in resolved {
                    let settings = settings(for: layout, maximumOutputChannels: maximumOutputChannels)
                    started.append(try StreamSession(host: host, appID: appID, settings: settings,
                                                      identity: identity, clientIdentity: secIdentity))
                    channels.append(settings.audio)
                }
            } catch {
                // A later side failed to construct (e.g. no free slot): release every slot this
                // call already acquired before `sessions`/`isStreaming` ever see them.
                for session in started { await session.stop() }
                status = "Start failed: \(error)"
                return
            }
            sessions = started
            audioChannels = channels
            NSLog("[Selenite] stream start: layout %@, %d side(s), audio %@, hdr %@, %d Mbps",
                  layout.rawValue, Int32(started.count), String(describing: channels),
                  String(describing: hdr), Int32(bitrateMbps))
            eventTexts = Array(repeating: "", count: started.count)
            eventTasks = started.enumerated().map { index, session in
                Task { [weak self] in
                    for await event in session.events {
                        self?.record(event, forHalf: index)
                    }
                }
            }
            // M1-A routes every controller to side A regardless of layout; M2 brings per-side assignment.
            // Only the Siri Remote ends a stream (Vincent); Start+Select go to the host like any button.
            let manager = ControllerManager(sink: started[0])
            let feedback = ControllerFeedback(manager: manager)
            feedback.sink = started[0]
            started[0].feedbackHandler = feedback
            controllerManager = manager
            controllerFeedback = feedback
            manager.start()
            // Must run before session.start() can hand the host anything to send feedback for:
            // `stopped` starts false, but an explicit resume() keeps that true regardless of
            // whether this is the first stream or a later one reusing a stopped instance.
            feedback.resume()
            isStreaming = true
            try await withThrowingTaskGroup(of: Void.self) { group in
                for session in started { group.addTask { try await session.start() } }
                try await group.waitForAll()
            }
        } catch StreamSessionError.cancelled {
            await stop()
        } catch {
            status = "Start failed: \(error)"
            await stop()
        }
    }

    func stop() async {
        if !sessions.isEmpty { NSLog("[Selenite] stream stop: %d side(s)", Int32(sessions.count)) }
        // Order matters: manager stop, then feedback stopAll, then sessions stop, so nothing keeps
        // delivering feedback callbacks into a handler that has already been torn down.
        controllerManager?.stop()
        controllerFeedback?.stopAll()
        controllerManager = nil
        controllerFeedback = nil
        eventTasks.forEach { $0.cancel() }
        eventTasks = []
        for session in sessions { await session.stop() }
        sessions = []
        eventTexts = []
        audioChannels = []
        isStreaming = false
    }

    private func record(_ event: StreamEvent, forHalf index: Int) {
        guard index < eventTexts.count else { return }
        let text = switch event {
        case .launching: "launching"
        case .started: "connected"
        case .stageFailed(let name, let code): "stage \(name) failed (\(code))"
        case .terminated(let code): "terminated (\(code))"
        case .poorConnection(let poor): poor ? "poor connection" : "connection ok"
        case .hostHDR(let enabled): "host HDR \(enabled ? "on" : "off")"
        }
        // Arrival events sent before the session reports connected are dropped by the host, so the
        // controller manager re-sends them here. Side A only: that is the only side it drives.
        if case .started = event, index == 0 { controllerManager?.reannounce() }
        eventTexts[index] = text
        status = "Side \(index == 0 ? "A" : "B"): \(text)"
    }
}

/// moonlight-common-c logs from its own connection threads. A closure written inside the
/// @MainActor init would inherit main-actor isolation and trap on its first off-main call.
private nonisolated func seleniteLogSink(_ slot: Int32, _ line: UnsafePointer<CChar>?) {
    guard let line else { return }
    let text = "[slot \(slot)] \(String(cString: line))"
    print(text, terminator: "")
    DiagnosticLogFile.shared.append(text)
}

/// Device diagnostics: tvOS drops stdout without a debugger, so log lines also go to
/// Library/Caches/selenite-log.txt, which `devicectl device copy from` can pull.
final class DiagnosticLogFile: @unchecked Sendable {
    static let shared = DiagnosticLogFile()
    private let queue = DispatchQueue(label: "selenite.diagnostic-log")
    private let handle: FileHandle?
    private let start = Date()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("selenite-log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func append(_ line: String) {
        let stamp = String(format: "%9.3f ", Date().timeIntervalSince(start))
        let text = stamp + (line.hasSuffix("\n") ? line : line + "\n")
        queue.async { [handle] in try? handle?.write(contentsOf: Data(text.utf8)) }
    }
}
