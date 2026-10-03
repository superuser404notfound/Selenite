import SwiftUI

// Adapted from Sodalite Components/ValuePickerRow.swift. Sodalite's row cycles its options in place;
// the M1-B spec (4.3) asks for a row that shows its value and opens a list of buttons, so Select
// opens a panel here. Never a Form Picker, which opens nothing on tvOS.

struct ValuePickerRow<Value: Hashable>: View {
    let icon: String
    let title: LocalizedStringKey
    let options: [Value]
    let selection: Value
    let label: (Value) -> LocalizedStringKey
    var isHighlighted = false
    let onSelect: (Value) -> Void

    @State private var isPicking = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 36) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .frame(width: 64)
                .foregroundStyle(.tint)
            Text(title)
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(label(selection))
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(focused ? .primary : .secondary))
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 16).fill(focused ? Color.Theme.focusFill : Color.Theme.restFillFaint))
        .focusStroke(cornerRadius: 16, isFocused: focused)
        .focusResponse(.row, isFocused: focused)
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused) { isPicking = true }
        .menuPresentation(isPresented: $isPicking) {
            ValueOptionList(title: title, options: options, selection: selection, label: label) { value in
                onSelect(value)
                isPicking = false
            }
        }
    }
}

/// The list a row opens: one button per option, stacked, the current one checked and focused first.
private struct ValueOptionList<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [Value]
    let selection: Value
    let label: (Value) -> LocalizedStringKey
    let choose: (Value) -> Void

    @FocusState private var focusedOption: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            choose(option)
                        } label: {
                            HStack {
                                Text(label(option))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if option == selection {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .focused($focusedOption, equals: option)
                    }
                }
                .padding(24)
            }
            .scrollClipDisabled()
        }
        .padding(48)
        .frame(width: 900)
        .frame(maxHeight: 820)
        .defaultFocus($focusedOption, selection)
    }
}
