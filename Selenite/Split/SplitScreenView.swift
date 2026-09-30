import AppCore
import InputKit
import StreamKit
import SwiftUI

/// Everything over the two videos: per-half status at the bottom of each half, the join screen,
/// the new-controller prompt and the split overlay. Input lives in `SplitContainerController`.
struct SplitScreenView: View {
    @Environment(AppModel.self) private var model
    let split: SplitController

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                ForEach(SplitSide.allCases, id: \.self) { side in
                    let frame = SplitGeometry.frame(of: side, in: bounds, layout: split.plan.layout,
                                                    swapped: split.isSwapped)
                    SplitHalfView(split: split, side: side, hostName: hostName(side), isJoining: isJoining)
                        .padding(.bottom, isJoining && frame.maxY >= bounds.maxY ? 140 : 0)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                if isJoining {
                    JoinFooter(isStacked: isStacked, isReady: split.seats.isReady)
                }
                if split.seatPrompt != nil, !isJoining {
                    SeatPromptPanel(isStacked: isStacked)
                        .transition(.opacity)
                }
                if split.isOverlayOpen {
                    SplitOverlayView(split: split, hostName: hostName)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: split.states)
        .animation(.easeOut(duration: 0.3), value: split.stage)
        .animation(.easeOut(duration: 0.3), value: split.isReassigning)
        .animation(.easeInOut(duration: 0.2), value: split.seatPrompt)
        .animation(.easeInOut(duration: 0.2), value: split.isOverlayOpen)
    }

    private var isJoining: Bool { split.stage == .joining || split.isReassigning }
    private var isStacked: Bool { split.plan.layout == .topBottom }

    private func hostName(_ side: SplitSide) -> String {
        if let stream = split.streams[side] { return stream.host.name }
        let hostID = split.plan[side].hostID
        return model.directory.hosts.first { $0.host.id == hostID }?.host.name ?? ""
    }
}

private struct SplitHalfView: View {
    let split: SplitController
    let side: SplitSide
    let hostName: String
    let isJoining: Bool

    var body: some View {
        ZStack {
            if isJoining {
                joinCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: split.stage == .joining ? .center : .bottom)
            } else {
                status
            }
        }
        .padding(48)
    }

    private var seated: Int { split.seats.count(on: side) }

    private var joinCard: some View {
        VStack(spacing: 16) {
            Text(split.plan[side].app.title)
                .font(.headline)
            Text(hostName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Press A to join")
            if seated > 0 {
                HStack(spacing: 12) {
                    ForEach(0..<seated, id: \.self) { _ in
                        Image(systemName: "gamecontroller.fill")
                    }
                }
                .foregroundStyle(.tint)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 36))
    }

    @ViewBuilder private var status: some View {
        switch split.states[side] ?? .idle {
        case .idle:
            bottom { capsule(progress: true) { Text("Connecting…") } }
        case .waking:
            bottom { capsule(progress: true) { Text("Waking \(hostName)…") } }
        case .streaming:
            if let stream = split.streams[side] {
                if stream.phase == .running, stream.ending == nil {
                    running(stream)
                } else {
                    bottom { capsule(progress: true) { Text(stream.loadingLine) } }
                }
            }
        case .ended(let end):
            bottom { capsule(progress: false) { ended(end) } }
        }
    }

    private func running(_ stream: StreamController) -> some View {
        ZStack {
            if stream.isPoorConnection {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(Color.Theme.warning)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if seated == 0 {
                bottom { capsule(progress: false) { Text("Press A to join") } }
            }
        }
    }

    @ViewBuilder private func ended(_ end: SideEnd) -> some View {
        switch end {
        case .disconnected:
            Text("Disconnected. Press A to reconnect.")
        case .quit:
            Text("Game quit. Press A to restart.")
        case .suspended:
            Text("Paused. Press A to resume.")
        case .failed(let failure):
            VStack(spacing: 8) {
                Text(failure.message)
                if failure == .gameClosed {
                    Text("Press A to restart")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Press A to reconnect")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bottom(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func capsule(progress: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 16) {
            if progress { ProgressView() }
            content()
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct JoinFooter: View {
    let isStacked: Bool
    let isReady: Bool

    var body: some View {
        VStack(spacing: 12) {
            if isReady {
                Text("Press Start to play")
                    .font(.headline)
            }
            Text(hint)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 48)
    }

    private var hint: LocalizedStringKey {
        isStacked ? "Point up or down and press A. Start begins." : "Point left or right and press A. Start begins."
    }
}

private struct SeatPromptPanel: View {
    let isStacked: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Text("Press B to cancel")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.Theme.panelEdge))
    }

    private var title: LocalizedStringKey {
        isStacked ? "New controller: point up or down and press A" : "New controller: point left or right and press A"
    }
}
