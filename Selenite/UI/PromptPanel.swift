import SwiftUI

/// A small centered prompt inside `.menuPresentation`: title, message, and its buttons stacked
/// vertically (buttons side by side in an HStack are unreliable to reach on tvOS).
struct PromptPanel<Buttons: View>: View {
    let title: Text
    let message: Text
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 28) {
            title
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            message
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 16) {
                buttons()
            }
            .padding(.top, 12)
        }
        .padding(60)
        .frame(width: 900)
    }
}
