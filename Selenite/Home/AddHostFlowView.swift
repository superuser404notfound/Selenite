import AppCore
import HostKit
import SwiftUI

/// Add host and pairing in one panel (spec 4.2). Closes itself when the host is saved.
struct AddHostFlowView: View {
    @Environment(AppModel.self) private var appModel
    let request: AddHostRequest

    @State private var model: AddHostModel?

    var body: some View {
        Group {
            if let model {
                AddHostContent(model: model)
            }
        }
        .frame(width: 1000)
        .padding(60)
        .onAppear {
            guard model == nil else { return }
            let created = appModel.makeAddHostModel(for: request)
            model = created
            created.begin()
        }
        .onDisappear { model?.cancel() }
        .onChange(of: model?.phase) { _, phase in
            if case .finished(let host)? = phase { appModel.hostAdded(host) }
        }
    }
}

private struct AddHostContent: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: AddHostModel

    var body: some View {
        switch model.phase {
        case .enterAddress:
            addressStep
        case .checking:
            progress(Text("Contacting the host…"))
        case .showingPIN(let pin):
            pinStep(pin)
        case .failed(let failure):
            failureStep(failure)
        case .finished:
            progress(Text("Paired."))
        }
    }

    private var addressStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Add host")
                .font(.title2)
                .fontWeight(.bold)
            Text("Enter the IP address or hostname of the PC running Sunshine.")
                .foregroundStyle(.secondary)
            TextField("Address", text: $model.address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { model.submit() }
            VStack(spacing: 16) {
                Button("Continue") { model.submit() }
                Button("Cancel") { appModel.addHostRequest = nil }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func progress(_ text: Text) -> some View {
        VStack(spacing: 28) {
            ProgressView()
            text.foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func pinStep(_ pin: String) -> some View {
        VStack(spacing: 32) {
            Text("Enter this PIN in Sunshine's web UI (PIN tab)")
                .font(.title3)
                .multilineTextAlignment(.center)
            Text(verbatim: pin)
                .font(.system(size: 160, weight: .bold, design: .rounded))
                .monospacedDigit()
            ProgressView()
            Button("Cancel") { appModel.addHostRequest = nil }
        }
        .frame(maxWidth: .infinity)
    }

    private func failureStep(_ failure: PairingFailure) -> some View {
        VStack(spacing: 28) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.Theme.warning)
            Text(verbatim: failure.message)
                .multilineTextAlignment(.center)
            VStack(spacing: 16) {
                Button("Try again") { model.retry() }
                Button("Cancel") { appModel.addHostRequest = nil }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
