import AppCore
import HostKit
import Observation
import Security
import StreamKit
import SwiftUI

enum AddHostRequest: Identifiable {
    case new
    case pairAgain(PairedHost)
    case discovered(DiscoveredHost)

    var id: String {
        switch self {
        case .new: "new"
        case .pairAgain(let host): "pair-again-\(host.id)"
        case .discovered(let host): "discovered-\(host.id)"
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
    let discovery: HostDiscovery
    let catalog: AppCatalog
    let settings: SettingsStore
    let waker: HostWaker
    let recents = RecentsStore()
    var activeStream: StreamController?
    var errorPanel: ErrorPanelModel?
    var addHostRequest: AddHostRequest?
    var pendingRemoval: PairedHost?
    var pendingSwitch: AppSwitchPrompt?
    var isShowingSettings = false
    var isShowingWake = false
    /// Kept after the wake ends, so the panel does not lose its title while it animates out.
    private(set) var wakingHostName = ""
    private(set) var isWakingForGame = false

    private let hostStore: HostStore
    private let clients: NvHTTPClientFactory
    private let secIdentity: SecIdentity?
    private let identityProblem: String?
    @ObservationIgnored private var homeVisible = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var lastLaunch: (host: PairedHost, app: AppEntry)?
    @ObservationIgnored private var queuedLaunch: (host: PairedHost, app: AppEntry)?
    @ObservationIgnored private var queuedRetry: (host: PairedHost, app: AppEntry)?
    @ObservationIgnored private var backgroundTeardown: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var failureAfterCover: StreamFailure?
    private var wakeTarget: (host: PairedHost, app: AppEntry?)?
    @ObservationIgnored private var queuedWakeLaunch: (host: PairedHost, app: AppEntry)?
    @ObservationIgnored private var queuedWakeFailure: StreamFailure?
    @ObservationIgnored private var lastWakeTarget: (host: PairedHost, app: AppEntry?)?
    @ObservationIgnored private var queuedWakeRetry: (host: PairedHost, app: AppEntry?)?

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
        let directory = HostDirectory(store: hostStore,
                                      probe: LiveServerInfoProbe(uniqueID: identity.uniqueID, clients: clients))
        self.directory = directory
        self.discovery = HostDiscovery(browser: BonjourBrowser(),
                                       probe: LivePlainServerInfoProbe(uniqueID: identity.uniqueID, clients: clients),
                                       pinnedProbe: LiveServerInfoProbe(uniqueID: identity.uniqueID, clients: clients),
                                       store: hostStore,
                                       onKnownHostMoved: {
                                           directory.reload()
                                           Task { await directory.refresh() }
                                       })
        self.catalog = AppCatalog(source: LiveAppCatalogSource(uniqueID: identity.uniqueID, clients: clients),
                                  cacheDirectory: AppCatalog.defaultCacheDirectory())
        self.settings = SettingsStore()
        self.waker = HostWaker(send: { host in
            _ = await Task.detached {
                let results = WakeOnLAN.wake(host)
                let lines = results.map { result in
                    result.errorCode.map { "\(result.destination) errno \(Int($0))" } ?? "\(result.destination) sent"
                }
                DiagnosticLog.note("wake \(host.name): \(lines.joined(separator: ", "))")
            }.value
        }, probe: LiveServerInfoProbe(uniqueID: identity.uniqueID, clients: clients))
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

    /// Only for a host that answered; an offline one gets the list saved at its last load.
    func loadApps(for snapshot: HostSnapshot) async {
        if snapshot.status == .offline {
            catalog.restoreApps(for: snapshot.id)
            return
        }
        guard snapshot.status == .online || snapshot.status == .busy else { return }
        await catalog.loadApps(for: snapshot.host)
    }

    /// A click on a host card; focus alone only selects. A sleeping host that can be woken is.
    func hostCardClicked(_ snapshot: HostSnapshot) {
        select(snapshot.id)
        if Self.shouldWake(snapshot) {
            wakeAndLaunch(host: snapshot.host, app: nil)
        }
    }

    /// Home polls serverinfo every 5 s while visible and no stream runs (spec 4.1), and browses for
    /// unpaired Sunshine hosts over Bonjour at the same time.
    func homeAppeared() {
        homeVisible = true
        if activeStream == nil, !isStarting { startWatchingHosts() }
    }

    func homeDisappeared() {
        homeVisible = false
        directory.stopPolling()
        discovery.stop()
    }

    private func startWatchingHosts() {
        directory.startPolling()
        discovery.start()
    }

    func makeAddHostModel(for request: AddHostRequest) -> AddHostModel {
        let clients = self.clients
        let flow = PairingFlow(identity: identity, store: hostStore,
                               makeTransport: { clients.make(pinnedCertificate: $0) })
        switch request {
        case .new: return AddHostModel(flow: flow)
        case .pairAgain(let host): return AddHostModel(flow: flow, pairAgainAddress: host.address)
        case .discovered(let host): return AddHostModel(flow: flow, discoveredAddress: host.address)
        }
    }

    /// The add-host panel closes itself; the host appears in the row, selected.
    func hostAdded(_ host: PairedHost) {
        directory.reload()
        discovery.storeChanged()
        settings.setSelectedHostID(host.id)
        addHostRequest = nil
        Task { await directory.refresh() }
    }

    func setWakeOnLAN(_ host: PairedHost, enabled: Bool) {
        var updated = host
        updated.wakeOnLAN = enabled
        hostStore.update(updated)
        directory.reload()
    }

    func removeHost(_ host: PairedHost) {
        pendingRemoval = nil
        directory.remove(id: host.id)
        discovery.storeChanged()
        catalog.forget(hostID: host.id)
        recents.removeAll(hostID: host.id)
        if settings.selectedHostID == host.id {
            settings.setSelectedHostID(directory.hosts.first?.id)
        }
    }

    // MARK: Streams

    /// An app tile was chosen. The running app resumes; another app running on the host would be
    /// quit by the launch (LaunchPlan.quitThenLaunch), so that asks first.
    func appSelected(_ app: AppEntry) {
        guard let snapshot = selectedHost else { return }
        if Self.shouldWake(snapshot) {
            wakeAndLaunch(host: snapshot.host, app: app)
            return
        }
        launchOrAskToSwitch(snapshot: snapshot, app: app)
    }

    /// A recent entry: the game on its own host, woken first when it sleeps. An offline host that
    /// cannot be woken is only selected, so Home shows why nothing starts.
    func recentSelected(_ entry: RecentEntry) {
        guard let snapshot = directory.snapshot(id: entry.hostID) else { return }
        if Self.shouldWake(snapshot) {
            wakeAndLaunch(host: snapshot.host, app: entry.app)
        } else if snapshot.status == .offline {
            select(snapshot.id)
        } else {
            launchOrAskToSwitch(snapshot: snapshot, app: entry.app)
        }
    }

    private func launchOrAskToSwitch(snapshot: HostSnapshot, app: AppEntry) {
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

    /// Runs the same switch check as a tile, against the host as it is now: the host may be
    /// running another game by the time "Try again" is chosen.
    func retryLastLaunch() {
        if case .hostDidNotWake = errorPanel?.failure {
            queuedWakeRetry = lastWakeTarget
        } else {
            queuedRetry = lastLaunch
        }
        errorPanel = nil
    }

    /// `onDismiss` of the switch prompt and the error panel: start what they queued, or, for a
    /// retry, ask first when it would quit another game.
    func presentationDismissed() {
        if let wake = queuedWakeRetry {
            queuedWakeRetry = nil
            wakeAndLaunch(host: wake.host, app: wake.app)
            return
        }
        if let retry = queuedRetry {
            queuedRetry = nil
            if let snapshot = directory.snapshot(id: retry.host.id) {
                if Self.shouldWake(snapshot) {
                    wakeAndLaunch(host: snapshot.host, app: retry.app)
                    return
                }
                launchOrAskToSwitch(snapshot: snapshot, app: retry.app)
            } else {
                startStream(host: retry.host, app: retry.app)
            }
            return
        }
        guard let launch = queuedLaunch else { return }
        queuedLaunch = nil
        startStream(host: launch.host, app: launch.app)
    }

    // MARK: Waking

    /// Unknown counts as asleep: on a cold launch or a resume nothing has answered yet, and an
    /// awake host answers the waker's first probe in milliseconds.
    private static func shouldWake(_ snapshot: HostSnapshot) -> Bool {
        (snapshot.status == .offline || snapshot.status == .unknown) && HostWaker.canWake(snapshot.host)
    }

    /// A sleeping host with a known MAC is woken first; the launch (or just the refresh, for a
    /// host card) continues once it answers (M1-C spec, section 4).
    func wakeAndLaunch(host: PairedHost, app: AppEntry?) {
        guard HostWaker.canWake(host), activeStream == nil, !isStarting else { return }
        wakeTarget = (host, app)
        wakingHostName = host.name
        isWakingForGame = app != nil
        lastWakeTarget = (host, app)
        lastLaunch = app.map { (host, $0) }
        isShowingWake = true
        waker.wake(host) { [weak self] outcome in self?.wakeEnded(outcome) }
    }

    func cancelWake() {
        waker.cancel()
    }

    private func wakeEnded(_ outcome: WakeOutcome) {
        guard let target = wakeTarget else { return }
        wakeTarget = nil
        DiagnosticLog.note("wake \(target.host.name): \(outcome)")
        // Menu already closed the panel: a late answer starts nothing.
        guard isShowingWake else { return }
        switch outcome {
        case .awake:
            if let app = target.app { queuedWakeLaunch = (target.host, app) }
            Task { await directory.refresh() }
        case .timedOut:
            queuedWakeFailure = .hostDidNotWake(target.host.name)
        case .cancelled:
            break
        }
        isShowingWake = false
    }

    /// `onDismiss` of the wake panel: presentations never replace each other directly.
    func wakePanelDismissed() {
        waker.cancel()
        if let failure = queuedWakeFailure {
            queuedWakeFailure = nil
            errorPanel = ErrorPanelModel(failure: failure, canRetry: lastWakeTarget != nil)
            return
        }
        guard let launch = queuedWakeLaunch else { return }
        queuedWakeLaunch = nil
        Task {
            await directory.refresh()
            if let snapshot = directory.snapshot(id: launch.host.id) {
                launchOrAskToSwitch(snapshot: snapshot, app: launch.app)
            } else {
                startStream(host: launch.host, app: launch.app)
            }
        }
    }

    func startStream(host: PairedHost, app: AppEntry) {
        guard activeStream == nil, !isStarting else { return }
        isStarting = true
        lastLaunch = (host, app)
        directory.stopPolling()
        discovery.stop()
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
                + " audio \(streamSettings.audio), pacing \(streamSettings.pacing.rawValue),"
                + " direct present \(streamSettings.directPresent ? "on" : "off"), display \(display.width)x\(display.height) at \(display.refreshRate) Hz")
            do {
                let session = try StreamSession(host: host, appID: app.id, settings: streamSettings,
                                                identity: identity, clientIdentity: secIdentity)
                let controller = StreamController(
                    host: host, app: app, settings: streamSettings, session: session,
                    input: ControllerInput(),
                    commands: LiveHostCommands(uniqueID: identity.uniqueID, clients: clients),
                    onRunning: { self.recents.record(hostID: host.id, app: app) },
                    // Strong: AppModel lives as long as the app, and streamEnded clears activeStream,
                    // which drops the controller and this closure with it.
                    onEnded: { failure in self.streamEnded(failure) })
                // Unreachable by construction: no await since the check above, so the scene phase
                // cannot have changed. An await inserted before this line would have to stop the
                // session here, or the slot it claimed leaks.
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
        endBackgroundTeardown()
        if homeVisible, !isBackgrounded {
            startWatchingHosts()
        } else {
            Task { await directory.refresh() }
        }
    }

    func streamCoverDismissed() {
        guard let failure = failureAfterCover else { return }
        failureAfterCover = nil
        errorPanel = ErrorPanelModel(failure: failure, canRetry: lastLaunch != nil && failure.offersRetry)
    }

    /// A start that failed before any cover was shown.
    private func showFailure(_ failure: StreamFailure) {
        DiagnosticLog.note("stream start failed: \(String(describing: failure))")
        errorPanel = ErrorPanelModel(failure: failure, canRetry: lastLaunch != nil && failure.offersRetry)
        if homeVisible, !isBackgrounded { startWatchingHosts() }
    }

    /// Backgrounding or sleep disconnects cleanly; the game keeps running on the host and shows as
    /// Running on Home afterwards (spec 4.5).
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isBackgrounded = true
            waker.cancel()
            directory.stopPolling()
            directory.forgetStatus()
            discovery.stop()
            if let stream = activeStream {
                beginBackgroundTeardown()
                stream.disconnect()
            }
        case .active:
            isBackgrounded = false
            if homeVisible, activeStream == nil, !isStarting { startWatchingHosts() }
        default:
            break
        }
    }

    /// Keeps the app running in the background until the stream's stop has returned; ended in
    /// `streamEnded`, or by the system when the time runs out.
    private func beginBackgroundTeardown() {
        guard backgroundTeardown == .invalid else { return }
        backgroundTeardown = UIApplication.shared.beginBackgroundTask(withName: "stream teardown") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTeardown() }
        }
    }

    private func endBackgroundTeardown() {
        guard backgroundTeardown != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTeardown)
        backgroundTeardown = .invalid
    }
}
