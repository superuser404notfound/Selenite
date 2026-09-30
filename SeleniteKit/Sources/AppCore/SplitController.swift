import Foundation
import HostKit
import InputKit
import Observation
import StreamKit

@MainActor
public protocol SplitInputHandle: AnyObject {
    var onEvent: (@MainActor (PadID, LobbyEvent) -> Void)? { get set }
    var onPadsChanged: (@MainActor (Set<PadID>) -> Void)? { get set }
    /// The controllers of one side, handed to that side's StreamController.
    func input(for side: SplitSide) -> any StreamInput
    func apply(_ seats: SeatMap)
    /// Reassigning: seated pads report lobby presses too, and nothing reaches the hosts.
    func setReassigning(_ reassigning: Bool)
    func start()
    func stop()
}

public struct SplitDependencies {
    public var host: @MainActor (String) -> PairedHost?
    public var needsWake: @MainActor (String) -> Bool
    public var wake: @MainActor (PairedHost) async -> WakeOutcome
    public var makeSession: @MainActor (PairedHost, AppEntry, SplitLayout, SplitFormat) async throws
        -> (any StreamSessionHandle, StreamSettings)
    public var input: any SplitInputHandle
    public var commands: any HostCommands
    public var store: SplitStore
    public var recordRecent: @MainActor (String, AppEntry) -> Void
    /// No session is running any more (background teardown can end).
    public var onStreamsIdle: @MainActor () -> Void
    /// A side asked for "Choose game"; the app shows the one-side wizard and calls `replaceSide`.
    public var chooseGame: @MainActor (SplitSide, SplitPlan) -> Void

    public init(host: @escaping @MainActor (String) -> PairedHost?,
                needsWake: @escaping @MainActor (String) -> Bool,
                wake: @escaping @MainActor (PairedHost) async -> WakeOutcome,
                makeSession: @escaping @MainActor (PairedHost, AppEntry, SplitLayout, SplitFormat) async throws
                    -> (any StreamSessionHandle, StreamSettings),
                input: any SplitInputHandle,
                commands: any HostCommands,
                store: SplitStore,
                recordRecent: @escaping @MainActor (String, AppEntry) -> Void,
                onStreamsIdle: @escaping @MainActor () -> Void,
                chooseGame: @escaping @MainActor (SplitSide, SplitPlan) -> Void) {
        self.host = host
        self.needsWake = needsWake
        self.wake = wake
        self.makeSession = makeSession
        self.input = input
        self.commands = commands
        self.store = store
        self.recordRecent = recordRecent
        self.onStreamsIdle = onStreamsIdle
        self.chooseGame = chooseGame
    }
}

public enum SplitStage: Equatable, Sendable { case joining, running }
public enum SideEnd: Equatable, Sendable { case disconnected, quit, suspended, failed(StreamFailure) }
public enum SideState: Equatable, Sendable { case idle, waking, streaming, ended(SideEnd) }
public enum SplitFinish: Equatable, Sendable { case ended, cancelledJoin }

/// A wake and connect in flight for one side; a result whose token no longer matches is dropped.
private struct StartTask {
    let token: UUID
    let task: Task<Void, Never>
}

/// Two solo streams side by side (M2 spec, sections 3 and 4): join, start in parallel, per-side
/// errors, the central overlay, reassigning, end and background. Each side's phase, failure and
/// stats stay inside its own `StreamController`.
@MainActor @Observable
public final class SplitController: Identifiable {
    public let id = UUID()
    public private(set) var plan: SplitPlan
    public private(set) var stage: SplitStage = .joining
    public private(set) var seats = SeatMap()
    public private(set) var states: [SplitSide: SideState] = [.first: .idle, .second: .idle]
    public private(set) var streams: [SplitSide: StreamController] = [:]
    public private(set) var volumes: [SplitSide: Float] = [.first: 1, .second: 1]
    public private(set) var isSwapped = false
    public private(set) var isOverlayOpen = false
    public private(set) var isReassigning = false
    public private(set) var seatPrompt: PadID?
    public private(set) var cursor = OverlayCursor()
    public private(set) var quitArmed: SplitSide?
    public private(set) var isChoosingGame = false

    @ObservationIgnored private let dependencies: SplitDependencies
    @ObservationIgnored private let onFinished: @MainActor (SplitFinish) -> Void
    @ObservationIgnored private var startTasks: [SplitSide: StartTask] = [:]
    @ObservationIgnored private var pendingEnd: [SplitSide: SideEnd] = [:]
    @ObservationIgnored private var lastMenuPress = -Double.infinity
    @ObservationIgnored private var isEnding = false
    @ObservationIgnored private var finished = false

    public init(plan: SplitPlan, dependencies: SplitDependencies,
                onFinished: @escaping @MainActor (SplitFinish) -> Void) {
        self.plan = plan
        self.dependencies = dependencies
        self.onFinished = onFinished
    }

    public func begin() {
        let input = dependencies.input
        input.onEvent = { [weak self] pad, event in self?.handle(pad: pad, event: event) }
        input.onPadsChanged = { [weak self] live in self?.padsChanged(live) }
        for side in SplitSide.allCases { volumes[side] = dependencies.store.volume(for: side) }
        input.start()
    }

    // MARK: Menu and overlay

    public func menuPressed(now: Double) {
        guard !isChoosingGame, !finished else { return }
        guard now - lastMenuPress >= StreamController.menuDebounceSeconds else { return }
        lastMenuPress = now
        if stage == .joining {
            finish(.cancelledJoin)
        } else if isReassigning {
            isReassigning = false
            dependencies.input.setReassigning(false)
        } else if seatPrompt != nil {
            seatPrompt = nil
        } else if isOverlayOpen {
            closeOverlay()
        } else if !isEnding {
            cursor = OverlayCursor()
            quitArmed = nil
            isOverlayOpen = true
        }
    }

    public func overlayMove(_ direction: OverlayDirection) {
        guard isOverlayOpen else { return }
        cursor.move(direction)
        quitArmed = nil
    }

    public func overlaySelect() {
        guard isOverlayOpen else { return }
        switch cursor.item {
        case .volumeDown(let side): setVolume((volumes[side] ?? 1) - 0.1, for: side)
        case .volumeUp(let side): setVolume((volumes[side] ?? 1) + 0.1, for: side)
        case .primary(let side): primaryAction(side)
        case .secondary(let side): secondaryAction(side)
        case .swap: swapSides()
        case .reassign: reassignControllers()
        case .endSplit: endSplit()
        case .resume: closeOverlay()
        }
    }

    public func closeOverlay() {
        isOverlayOpen = false
        quitArmed = nil
    }

    // MARK: Side actions

    /// Disconnect while streaming, cancel while waking, reconnect once ended.
    public func primaryAction(_ side: SplitSide) {
        guard stage == .running, !isEnding else { return }
        switch states[side] ?? .idle {
        case .streaming:
            pendingEnd[side] = .disconnected
            streams[side]?.disconnect()
        case .waking:
            cancelStart(side, end: .disconnected)
        case .ended, .idle:
            startSide(side)
        }
    }

    /// Quit game while streaming (armed by the first press), Choose game once ended or while waking.
    public func secondaryAction(_ side: SplitSide) {
        guard stage == .running, !isEnding else { return }
        switch states[side] ?? .idle {
        case .streaming:
            guard quitArmed == side else {
                quitArmed = side
                return
            }
            quitArmed = nil
            guard let stream = streams[side] else { return }
            stream.quitGame()
            if stream.ending == .quittingGame { pendingEnd[side] = .quit }
        case .ended, .waking:
            isChoosingGame = true
            closeOverlay()
            dependencies.chooseGame(side, plan)
        case .idle:
            break
        }
    }

    public func replaceSide(_ side: SplitSide, with choice: SplitSideChoice) {
        isChoosingGame = false
        guard !isEnding, states[side] != .streaming, choice.hostID != plan[side.other].hostID else { return }
        if let running = startTasks.removeValue(forKey: side) { running.task.cancel() }
        pendingEnd[side] = nil
        plan[side] = choice
        dependencies.store.save(plan)
        startSide(side)
    }

    public func chooseGameCancelled() {
        isChoosingGame = false
    }

    public func setVolume(_ volume: Float, for side: SplitSide) {
        let clamped = min(max(volume, 0), 1)
        volumes[side] = clamped
        dependencies.store.setVolume(clamped, for: side)
        streams[side]?.session.setVolume(clamped)
    }

    public func swapSides() {
        isSwapped.toggle()
    }

    /// The join screen over running streams; Start on a seated pad with both sides filled finishes it.
    public func reassignControllers() {
        guard stage == .running, !isEnding else { return }
        closeOverlay()
        seatPrompt = nil
        isReassigning = true
        dependencies.input.setReassigning(true)
    }

    /// Disconnects both sides (the games keep running) and finishes once nothing is left.
    public func endSplit() {
        guard !isEnding, !finished else { return }
        isEnding = true
        closeOverlay()
        stopAll(as: .disconnected)
        finishIfDone()
    }

    /// App backgrounded: both sides stop cleanly and wait for "Resume". `onStreamsIdle` follows
    /// exactly once, at once when nothing was live.
    public func suspend() {
        guard !finished else { return }
        guard !streams.isEmpty || !startTasks.isEmpty else {
            dependencies.onStreamsIdle()
            return
        }
        stopAll(as: .suspended)
    }

    // MARK: Controllers

    func handle(pad: PadID, event: LobbyEvent) {
        guard !finished else { return }
        if stage == .joining || isReassigning {
            handleJoining(pad: pad, event: event)
        } else {
            handleRunning(pad: pad, event: event)
        }
    }

    func padsChanged(_ live: Set<PadID>) {
        seats.keep(only: live)
        if let prompt = seatPrompt, !live.contains(prompt) { seatPrompt = nil }
        dependencies.input.apply(seats)
    }

    private func handleJoining(pad: PadID, event: LobbyEvent) {
        switch event {
        case .a(let direction):
            if let current = seats.side(of: pad) {
                guard let target = explicitSide(direction), target != current else { return }
                seat(pad, on: target)
            } else {
                seat(pad, on: seats.joinSide(for: direction, stacked: isStacked))
            }
        case .b:
            guard seats.side(of: pad) != nil else { return }
            seats.unseat(pad)
            dependencies.input.apply(seats)
        case .start:
            guard seats.side(of: pad) != nil, seats.isReady else { return }
            if stage == .joining {
                startBoth()
            } else {
                isReassigning = false
                dependencies.input.setReassigning(false)
                dependencies.input.apply(seats)
            }
        }
    }

    private func handleRunning(pad: PadID, event: LobbyEvent) {
        if let side = seats.side(of: pad) {
            if case .a = event, case .ended = states[side] ?? .idle { primaryAction(side) }
            return
        }
        switch event {
        case .a(let direction):
            if seatPrompt == pad {
                seatPrompt = nil
                seat(pad, on: seats.joinSide(for: direction, stacked: isStacked))
            } else {
                seatPrompt = pad
            }
        case .b:
            if seatPrompt == pad { seatPrompt = nil }
        case .start:
            break
        }
    }

    private var isStacked: Bool { plan.layout == .topBottom }

    /// A direction along the layout's axis names a side; anything else leaves a seated pad where it is.
    private func explicitSide(_ direction: StickDirection) -> SplitSide? {
        switch (direction, isStacked) {
        case (.left, false), (.up, true): .first
        case (.right, false), (.down, true): .second
        default: nil
        }
    }

    private func seat(_ pad: PadID, on side: SplitSide) {
        seats.seat(pad, on: side)
        dependencies.input.apply(seats)
    }

    // MARK: Sides

    private func startBoth() {
        stage = .running
        dependencies.store.save(plan)
        for side in SplitSide.allCases { startSide(side) }
    }

    private func startSide(_ side: SplitSide) {
        guard startTasks[side] == nil, streams[side] == nil else { return }
        let choice = plan[side]
        guard let host = dependencies.host(choice.hostID) else {
            states[side] = .ended(.failed(.unknown("host removed")))
            return
        }
        let wakes = dependencies.needsWake(choice.hostID)
        states[side] = wakes ? .waking : .idle
        let token = UUID()
        let task = Task { [weak self] () -> Void in
            await self?.runStart(side: side, host: host, app: choice.app, wakes: wakes, token: token)
        }
        startTasks[side] = StartTask(token: token, task: task)
    }

    private func runStart(side: SplitSide, host: PairedHost, app: AppEntry, wakes: Bool, token: UUID) async {
        if wakes {
            let outcome = await dependencies.wake(host)
            guard startTasks[side]?.token == token else { return }
            switch outcome {
            case .awake: break
            case .timedOut:
                settle(side, .failed(.hostDidNotWake(host.name)))
                return
            case .cancelled:
                settle(side, pendingEnd[side] ?? .disconnected)
                return
            }
        }
        let made: (any StreamSessionHandle, StreamSettings)
        do {
            made = try await dependencies.makeSession(host, app, plan.layout, plan.format)
        } catch {
            guard startTasks[side]?.token == token else { return }
            settle(side, .failed(StreamFailure.from(error: error)))
            return
        }
        let (session, settings) = made
        guard startTasks[side]?.token == token else {
            await session.stop()
            return
        }
        startTasks[side] = nil
        let hostID = host.id
        let recordRecent = dependencies.recordRecent
        var controllerID: UUID?
        let controller = StreamController(
            host: host, app: app, settings: settings, session: session,
            input: dependencies.input.input(for: side), commands: dependencies.commands,
            onRunning: { recordRecent(hostID, app) },
            onEnded: { [weak self] failure in
                guard let self, let controllerID else { return }
                self.sideEnded(side, controllerID: controllerID, failure: failure)
            })
        controllerID = controller.id
        streams[side] = controller
        states[side] = .streaming
        session.setVolume(volumes[side] ?? 1)
        controller.start()
    }

    private func sideEnded(_ side: SplitSide, controllerID: UUID, failure: StreamFailure?) {
        guard streams[side]?.id == controllerID else { return }
        streams[side] = nil
        settle(side, failure.map(SideEnd.failed) ?? pendingEnd[side] ?? .disconnected)
    }

    /// A wake or a connect in flight stops now; its result, whenever it comes, is ignored.
    private func cancelStart(_ side: SplitSide, end: SideEnd) {
        guard let running = startTasks[side] else { return }
        running.task.cancel()
        settle(side, end)
    }

    private func settle(_ side: SplitSide, _ end: SideEnd) {
        startTasks[side] = nil
        states[side] = .ended(end)
        pendingEnd[side] = nil
        if quitArmed == side { quitArmed = nil }
        if streams.isEmpty, startTasks.isEmpty { dependencies.onStreamsIdle() }
        finishIfDone()
    }

    private func stopAll(as end: SideEnd) {
        for side in SplitSide.allCases {
            if let stream = streams[side] {
                pendingEnd[side] = end
                stream.disconnect()
            } else if startTasks[side] != nil {
                cancelStart(side, end: end)
            }
        }
    }

    private func finishIfDone() {
        guard isEnding, streams.isEmpty, startTasks.isEmpty else { return }
        finish(.ended)
    }

    private func finish(_ result: SplitFinish) {
        guard !finished else { return }
        finished = true
        dependencies.input.stop()
        onFinished(result)
    }
}
