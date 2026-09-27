import AppCore
import HostKit
import Observation
import Security
import StreamKit
import SwiftUI

enum AddHostRequest: Identifiable {
    case new
    case pairAgain(PairedHost)

    var id: String {
        switch self {
        case .new: "new"
        case .pairAgain(let host): "pair-again-\(host.id)"
        }
    }
}

struct ErrorPanelModel: Identifiable {
    let id = UUID()
    let failure: StreamFailure
    let canRetry: Bool
}

struct AppSwitchPrompt: Identifiable {
    let id = UUID()
    let host: PairedHost
    let app: AppEntry
    let runningTitle: String?
}

/// The app's one model (M1-B spec, section 3): hosts, the selected host, app lists, settings, the
/// active stream, and which panel is up. The live dependencies are built here.
///
/// Presentations never replace each other directly: a panel that should lead into a stream (retry,
/// switch game) queues the launch and starts it from its `onDismiss`, and a stream that ends with an
/// error shows the error panel from the cover's `onDismiss`, because tvOS refuses to present a cover
/// while another is still leaving.
@MainActor @Observable
final class AppModel {
    let identity: ClientIdentity
    let directory: HostDirectory
    let catalog: AppCatalog
    let settings: SettingsStore
    var activeStream: StreamController?
    var errorPanel: ErrorPanelModel?
    var addHostRequest: AddHostRequest?
    var pendingRemoval: PairedHost?
    var pendingSwitch: AppSwitchPrompt?
    var isShowingSettings = false

    private let hostStore: HostStore
    private let clients: NvHTTPClientFactory
    private let secIdentity: SecIdentity?
    private let identityProblem: String?
    @ObservationIgnored private var homeVisible = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var lastLaunch: (host: PairedHost, app: AppEntry)?
    @ObservationIgnored private var queuedLaunch: (host: PairedHost, app: AppEntry)?
    @ObservationIgnored private var failureAfterCover: StreamFailure?

    init() {
        let identity: ClientIdentity
        var problem: String?
        do {
            identity = try IdentityStore.loadOrCreate()
        } catch {
            identity = try! ClientIdentity.generate()
            problem = String(describing: error)
        }
        let secIdentity = try? IdentityStore.secIdentity(for: identity)
        let clients = NvHTTPClientFactory(clientIdentity: secIdentity)
        let hostStore = HostStore()
        self.identity = identity
        self.identityProblem = problem
        self.secIdentity = secIdentity
        self.clients = clients
        self.hostStore = hostStore
        self.directory = HostDirectory(store: hostStore,
                                       probe: LiveServerInfoProbe(uniqueID: identity.uniqueID, clients: clients))
        self.catalog = AppCatalog(source: LiveAppCatalogSource(uniqueID: identity.uniqueID, clients: clients),
                                  cacheDirectory: AppCatalog.defaultCacheDirectory())
        self.settings = SettingsStore()
        if let problem { DiagnosticLog.note("keychain unavailable, pairings will not persist: \(problem)") }
    }

    // MARK: Hosts

    var selectedHost: HostSnapshot? {
        directory.hosts.first { $0.id == settings.selectedHostID } ?? directory.hosts.first
    }

    func select(_ hostID: String) {
        guard settings.selectedHostID != hostID else { return }
        settings.setSelectedHostID(hostID)
    }

    /// Only for a host that answered: an offline one shows its notice instead of a grid.
    func loadApps(for snapshot: HostSnapshot) async {
        guard snapshot.status == .online || snapshot.status == .busy else { return }
        await catalog.loadApps(for: snapshot.host)
    }

    /// Home polls serverinfo every 5 s while visible and no stream runs (spec 4.1).
    func homeAppeared() {
        homeVisible = true
        if activeStream == nil, !isStarting { directory.startPolling() }
    }

    func homeDisappeared() {
        homeVisible = false
        directory.stopPolling()
    }

    func makeAddHostModel(for request: AddHostRequest) -> AddHostModel {
        let clients = self.clients
        let flow = PairingFlow(identity: identity, store: hostStore,
                               makeTransport: { clients.make(pinnedCertificate: $0) })
        switch request {
        case .new: return AddHostModel(flow: flow)
        case .pairAgain(let host): return AddHostModel(flow: flow, pairAgainAddress: host.address)
        }
    }

    /// The add-host panel closes itself; the host appears in the row, selected.
    func hostAdded(_ host: PairedHost) {
        directory.reload()
        settings.setSelectedHostID(host.id)
        addHostRequest = nil
        Task { await directory.refresh() }
    }

    func removeHost(_ host: PairedHost) {
        pendingRemoval = nil
        directory.remove(id: host.id)
        if settings.selectedHostID == host.id {
            settings.setSelectedHostID(directory.hosts.first?.id)
        }
    }

    // MARK: Streams

    /// An app tile was chosen. The running app resumes; another app running on the host would be
    /// quit by the launch (LaunchPlan.quitThenLaunch), so that asks first.
    func appSelected(_ app: AppEntry) {
        guard let snapshot = selectedHost else { return }
        if LaunchPlan.decide(currentGame: snapshot.currentGame, appID: app.id) == .quitThenLaunch {
            let running = catalog.apps[snapshot.id]?.first { $0.id == snapshot.currentGame }?.title
            pendingSwitch = AppSwitchPrompt(host: snapshot.host, app: app, runningTitle: running)
        } else {
            startStream(host: snapshot.host, app: app)
        }
    }

    func confirmSwitch(_ prompt: AppSwitchPrompt) {
        queuedLaunch = (prompt.host, prompt.app)
        pendingSwitch = nil
    }

    func retryLastLaunch() {
        queuedLaunch = lastLaunch
        errorPanel = nil
    }

    /// `onDismiss` of the switch prompt and the error panel: start what they queued.
    func presentationDismissed() {
        guard let launch = queuedLaunch else { return }
        queuedLaunch = nil
        startStream(host: launch.host, app: launch.app)
    }

    func startStream(host: PairedHost, app: AppEntry) {
        guard activeStream == nil, !isStarting else { return }
        isStarting = true
        lastLaunch = (host, app)
        directory.stopPolling()
        let codecs = directory.snapshot(id: host.id)?.codecModeSupport ?? 0
        let preferences = settings.preferences
        let display = DisplayModeReader.current()
        Task {
            defer { isStarting = false }
            guard let secIdentity = self.secIdentity else {
                showFailure(.unknown(identityProblem ?? "no client identity"))
                return
            }
            // Activates the audio session and can block briefly: off the main actor.
            let channels = await Task.detached { AudioOutput.shared.maximumOutputChannels }.value
            // Backgrounded while the audio query ran: the start is abandoned, nothing was built yet.
            guard !isBackgrounded else { return }
            let streamSettings = StreamSettingsResolver.resolve(preferences, display: display,
                                                                maximumOutputChannels: channels,
                                                                hostCodecModeSupport: codecs)
            DiagnosticLog.note("stream start: \(host.name) app \(app.id) \(streamSettings.width)x\(streamSettings.height)"
                + " at \(streamSettings.fps) fps, \(streamSettings.bitrateKbps) kbps, \(streamSettings.codec),"
                + " audio \(streamSettings.audio), display \(display.width)x\(display.height) at \(display.refreshRate) Hz")
            do {
                let session = try StreamSession(host: host, appID: app.id, settings: streamSettings,
                                                identity: identity, clientIdentity: secIdentity)
                let controller = StreamController(
                    host: host, app: app, settings: streamSettings, session: session,
                    input: ControllerInput(),
                    commands: LiveHostCommands(uniqueID: identity.uniqueID, clients: clients),
                    // Strong: AppModel lives as long as the app, and streamEnded clears activeStream,
                    // which drops the controller and this closure with it.
                    onEnded: { failure in self.streamEnded(failure) })
                guard !isBackgrounded else { return }
                activeStream = controller
                controller.start()
            } catch {
                showFailure(StreamFailure.from(error: error))
            }
        }
    }

    /// The cover is up when this runs; the error panel waits for the cover's `onDismiss`.
    private func streamEnded(_ failure: StreamFailure?) {
        DiagnosticLog.note("stream end: \(failure.map { String(describing: $0) } ?? "by the user")")
        failureAfterCover = failure
        activeStream = nil
        if homeVisible, !isBackgrounded {
            directory.startPolling()
        } else {
            Task { await directory.refresh() }
        }
    }

    func streamCoverDismissed() {
        guard let failure = failureAfterCover else { return }
        failureAfterCover = nil
        errorPanel = ErrorPanelModel(failure: failure, canRetry: lastLaunch != nil)
    }

    /// A start that failed before any cover was shown.
    private func showFailure(_ failure: StreamFailure) {
        DiagnosticLog.note("stream start failed: \(String(describing: failure))")
        errorPanel = ErrorPanelModel(failure: failure, canRetry: lastLaunch != nil)
        if homeVisible { directory.startPolling() }
    }

    /// Backgrounding or sleep disconnects cleanly; the game keeps running on the host and shows as
    /// Running on Home afterwards (spec 4.5).
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isBackgrounded = true
            directory.stopPolling()
            activeStream?.disconnect()
        case .active:
            isBackgrounded = false
            if homeVisible, activeStream == nil, !isStarting { directory.startPolling() }
        default:
            break
        }
    }
}
