import AppCore
import QuartzCore
import StreamKit
import SwiftUI

/// The in-stream overlay (spec 4.4): glass panel at the bottom, live stats, Resume, Disconnect and
/// Quit game with a confirmation. The stream keeps running behind it; controllers are paused.
struct StreamOverlayView: View {
    let controller: StreamController

    private enum Action: Hashable {
        case resume, disconnect, quit, confirmQuit, cancelQuit
    }

    @FocusState private var focused: Action?

    var body: some View {
        VStack {
            Spacer()
            panel
        }
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.app.title)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(controller.host.name)
                    .foregroundStyle(.secondary)
            }
            if let stats = controller.liveStats {
                OverlayStats(stats: stats, pacing: controller.settings.pacing)
            }
            if controller.isConfirmingQuit {
                Text("Quit \(controller.app.title) on \(controller.host.name)? Unsaved progress may be lost.")
                VStack(spacing: 16) {
                    Button("Quit game", role: .destructive) { controller.confirmQuit() }
                        .tint(Color.Theme.destructive)
                        .focused($focused, equals: .confirmQuit)
                    Button("Cancel") { controller.cancelQuit() }
                        .focused($focused, equals: .cancelQuit)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 16) {
                    Button("Resume") { controller.closeOverlay() }
                        .focused($focused, equals: .resume)
                    Button("Disconnect") { controller.disconnect() }
                        .tint(Color.Theme.destructive)
                        .focused($focused, equals: .disconnect)
                    Button("Quit game") { controller.requestQuit() }
                        .tint(Color.Theme.destructive)
                        .focused($focused, equals: .quit)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(48)
        .frame(width: 960)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(Color.Theme.panelEdge, lineWidth: 1))
        .defaultFocus($focused, .resume)
        .onAppear { focused = .resume }
        .onChange(of: controller.isConfirmingQuit) { _, confirming in
            focused = confirming ? .cancelQuit : .resume
        }
    }
}
