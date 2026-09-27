import CoreMedia
import Foundation
import HostKit
import Observation
import StreamKit

/// What `StreamController` needs from a session; `StreamSession` in the app, a fake in tests.
public protocol StreamSessionHandle: AnyObject, Sendable {
    var events: AsyncStream<StreamEvent> { get }
    var pacer: FramePacer<CMSampleBuffer> { get }
    func start() async throws
    func stop() async
    func stats() -> StreamStats
}

extension StreamSession: StreamSessionHandle {}

/// Controller input for one stream: `ControllerManager` plus host feedback in the app.
@MainActor
public protocol StreamInput: AnyObject {
    func begin(session: any StreamSessionHandle)
    /// The session is connected: re-send controller arrivals the host dropped before.
    func sessionConnected()
    func setForwarding(_ forwarding: Bool)
    func end()
}

public enum StreamPhase: Equatable, Sendable {
    case connecting
    case startingGame
    case waitingForPicture
    case running
    case ended
}

/// One solo stream from the moment an app is chosen until the cover closes (M1-B spec, 4.4 and
/// 4.5): loading phases, the overlay, disconnect, quit, and every way it can end. Every ending runs
/// through `finish`, which stops input, stops the session and reports exactly once.
@MainActor @Observable
public final class StreamController: Identifiable {
    /// The Siri Remote's Menu can reach the controller through GameController and through UIKit
    /// for one press; a second report inside this window is the same press.
    public static let menuDebounceSeconds = 0.3

    public let id = UUID()
    public let host: PairedHost
    public let app: AppEntry
    public let settings: StreamSettings
    public private(set) var phase: StreamPhase = .connecting
    public private(set) var isOverlayOpen = false
    public private(set) var isConfirmingQuit = false
    public private(set) var isPoorConnection = false
    public private(set) var liveStats: StreamStatsSummary?
    public private(set) var failure: StreamFailure?

    public let session: any StreamSessionHandle
    private let input: any StreamInput
    private let commands: any HostCommands
    private let onEnded: @MainActor (StreamFailure?) -> Void
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var lastMenuPress = -Double.infinity
    @ObservationIgnored private var previousStats: StreamStats?
    @ObservationIgnored private var stageFailure: StreamFailure?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ending = false
    @ObservationIgnored private(set) var endTask: Task<Void, Never>?

    public init(host: PairedHost, app: AppEntry, settings: StreamSettings, session: any StreamSessionHandle,
                input: any StreamInput, commands: any HostCommands,
                onEnded: @escaping @MainActor (StreamFailure?) -> Void) {
        self.host = host
        self.app = app
        self.settings = settings
        self.session = session
        self.input = input
        self.commands = commands
        self.onEnded = onEnded
    }

    public func start() {
        guard !started else { return }
        started = true
        input.begin(session: session)
        loops.append(Task { [weak self] in await self?.consumeEvents() })
        Task { await self.runStart() }
    }

    /// Siri Remote Menu, from any path. While loading it cancels; while running it opens or closes
    /// the overlay, and backs out of the quit confirmation first.
    public func menuPressed(now: Double) {
        guard now - lastMenuPress >= Self.menuDebounceSeconds else { return }
        lastMenuPress = now
        switch phase {
        case .connecting, .startingGame, .waitingForPicture:
            cancel()
        case .running:
            if isConfirmingQuit {
                isConfirmingQuit = false
            } else {
                setOverlay(open: !isOverlayOpen)
            }
        case .ended:
            break
        }
    }

    /// The overlay's "Resume".
    public func closeOverlay() {
        setOverlay(open: false)
    }

    /// Menu while loading. A game this attempt launched is cancelled on the host by the session.
    public func cancel() {
        finish(failure: nil)
    }

    /// The game keeps running on the host.
    public func disconnect() {
        finish(failure: nil)
    }

    public func requestQuit() {
        guard isOverlayOpen, !ending else { return }
        isConfirmingQuit = true
    }

    public func cancelQuit() {
        isConfirmingQuit = false
    }

    /// Stops the stream, then quits the game on the host.
    public func confirmQuit() {
        guard isConfirmingQuit else { return }
        finish(failure: nil, quitGame: true)
    }

    func handle(_ event: StreamEvent) {
        guard !ending else { return }
        switch event {
        case .launching:
            if phase == .connecting { phase = .startingGame }
        case .started:
            if phase == .connecting || phase == .startingGame {
                phase = .waitingForPicture
                watchForFirstFrame()
            }
            input.sessionConnected()
        case .stageFailed(let stage, let code):
            stageFailure = .stageFailed(stage, code)
        case .terminated(let code):
            finish(failure: StreamFailure.from(terminationCode: code))
        case .poorConnection(let poor):
            isPoorConnection = poor
        case .hostHDR:
            break
        }
    }

    /// The first presented frame ends the loading view.
    func checkFirstFrame() {
        guard phase == .waitingForPicture, !ending, session.stats().pacer.presented > 0 else { return }
        phase = .running
        sampleStats()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.sampleStats()
            }
        })
    }

    func sampleStats() {
        let current = session.stats()
        liveStats = StreamStatsSummary(current: current, previous: previousStats, settings: settings)
        previousStats = current
    }

    private func consumeEvents() async {
        for await event in session.events {
            handle(event)
        }
    }

    private func runStart() async {
        do {
            try await session.start()
        } catch StreamSessionError.cancelled {
            // A stop ended the start: cancel, disconnect or background already own the ending.
        } catch {
            finish(failure: stageFailure ?? StreamFailure.from(error: error))
        }
    }

    private func watchForFirstFrame() {
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .waitingForPicture else { return }
                self.checkFirstFrame()
                try? await Task.sleep(for: .milliseconds(50))
            }
        })
    }

    private func setOverlay(open: Bool) {
        guard phase == .running, !ending, open != isOverlayOpen else { return }
        isOverlayOpen = open
        if !open { isConfirmingQuit = false }
        input.setForwarding(!open)
    }

    private func finish(failure: StreamFailure?, quitGame: Bool = false) {
        guard !ending else { return }
        ending = true
        isOverlayOpen = false
        isConfirmingQuit = false
        input.end()
        loops.forEach { $0.cancel() }
        loops.removeAll()
        let session = self.session
        let commands = self.commands
        let host = self.host
        endTask = Task {
            await session.stop()
            var result = failure
            if quitGame {
                do {
                    try await commands.quitApp(on: host)
                } catch {
                    result = .quitFailed
                }
            }
            self.phase = .ended
            self.failure = result
            self.onEnded(result)
        }
    }
}
