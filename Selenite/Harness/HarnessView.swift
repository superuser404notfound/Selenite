import HostKit
import SwiftUI

struct HarnessView: View {
    @Environment(HarnessModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.isStreaming {
            StreamStageView()
        } else {
            NavigationStack {
                Form {
                    Section("Add host") {
                        TextField("IP address", text: $model.newAddress)
                        Button("Pair") { Task { await model.pair() } }
                            .disabled(model.isPairing)
                        if let pin = model.pairingPIN { Text("PIN \(pin)").font(.system(size: 80, weight: .bold)) }
                    }
                    Section("Layout") {
                        // tvOS Form rows focus as a whole: a Picker opens nothing and buttons inside an
                        // HStack are unreachable, so every control here is its own Button row.
                        ForEach(SplitLayout.allCases) { layout in
                            Button(layout.rawValue + (model.layout == layout ? "  (selected)" : "")) {
                                model.layout = layout
                            }
                        }
                        Button("Bitrate \(model.bitrateMbps) Mbps: +10") { model.bitrateMbps = min(500, model.bitrateMbps + 10) }
                        Button("Bitrate \(model.bitrateMbps) Mbps: -10") { model.bitrateMbps = max(10, model.bitrateMbps - 10) }
                        Toggle("HDR (solo only)", isOn: $model.hdr)
                    }
                    SidePicker(title: "Side A", choice: $model.sideA)
                    if model.layout != .solo { SidePicker(title: "Side B", choice: $model.sideB) }
                    Section {
                        Button("Start") { Task { await model.start() } }
                        Text(model.status).font(.caption)
                    }
                }
                .navigationTitle("Selenite M0 harness")
            }
        }
    }
}

private struct SidePicker: View {
    @Environment(HarnessModel.self) private var model
    let title: String
    @Binding var choice: SideChoice

    var body: some View {
        Section(title) {
            ForEach(model.hosts) { host in
                Button(host.name + (choice.hostID == host.id ? "  (selected)" : "")) {
                    choice.hostID = host.id
                    Task { await model.loadApps(for: host) }
                }
            }
            if let hostID = choice.hostID {
                ForEach(model.apps[hostID] ?? []) { app in
                    Button(app.title + (choice.appID == app.id ? "  (selected)" : "")) { choice.appID = app.id }
                }
            }
        }
    }
}
