import Foundation
import HostKit
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
    var sessions: [StreamSession] = []
    /// The latest session event per half, index-aligned with `sessions`.
    var eventTexts: [String] = []
    var isStreaming = false
    private var eventTasks: [Task<Void, Never>] = []

    init() {
        do {
            identity = try IdentityStore.loadOrCreate()
        } catch {
            identity = try! ClientIdentity.generate()
            status = "Keychain unavailable, pairings will not persist: \(error)"
        }
        hosts = hostStore.all()
        MLSetLogSink { slot, line in
            guard let line else { return }
            print("[slot \(slot)] \(String(cString: line))", terminator: "")
        }
    }

    func pair() async {
        let address = newAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        let client = NvHTTPClient(pinnedCertificate: nil, clientIdentity: try? IdentityStore.secIdentity(for: identity))
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
            let endpoints = NvEndpoints(address: host.address, httpsPort: host.httpsPort, uniqueID: identity.uniqueID)
            apps[host.id] = AppEntry.list(try NvResponse.parse(try await client.get(endpoints.appList(), timeout: 10)).requireOK())
        } catch {
            status = "App list failed for \(host.name): \(error)"
        }
    }

    /// 4K panel: a side-by-side half is 1920x2160, a top-bottom half 3840x1080.
    func settings(for layout: SplitLayout) -> StreamSettings {
        let (width, height) = switch layout {
        case .solo: (3840, 2160)
        case .sideBySide: (1920, 2160)
        case .topBottom: (3840, 1080)
        }
        return StreamSettings(width: width, height: height, fps: 60, bitrateKbps: bitrateMbps * 1000,
                              hdr: layout == .solo && hdr)
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
            var started: [StreamSession] = []
            do {
                for (host, appID) in resolved {
                    started.append(try StreamSession(host: host, appID: appID, settings: settings(for: layout),
                                                      identity: identity, clientIdentity: secIdentity))
                }
            } catch {
                // A later side failed to construct (e.g. no free slot): release every slot this
                // call already acquired before `sessions`/`isStreaming` ever see them.
                for session in started { await session.stop() }
                status = "Start failed: \(error)"
                return
            }
            sessions = started
            eventTexts = Array(repeating: "", count: started.count)
            eventTasks = started.enumerated().map { index, session in
                Task { [weak self] in
                    for await event in session.events {
                        self?.record(event, forHalf: index)
                    }
                }
            }
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
        eventTasks.forEach { $0.cancel() }
        eventTasks = []
        for session in sessions { await session.stop() }
        sessions = []
        eventTexts = []
        isStreaming = false
    }

    private func record(_ event: StreamEvent, forHalf index: Int) {
        guard index < eventTexts.count else { return }
        let text = switch event {
        case .started: "connected"
        case .stageFailed(let name, let code): "stage \(name) failed (\(code))"
        case .terminated(let code): "terminated (\(code))"
        case .poorConnection(let poor): poor ? "poor connection" : "connection ok"
        case .hostHDR(let enabled): "host HDR \(enabled ? "on" : "off")"
        }
        eventTexts[index] = text
        status = "Side \(index == 0 ? "A" : "B"): \(text)"
    }
}
