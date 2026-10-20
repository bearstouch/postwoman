import SwiftUI

struct KeyValueRowView: View {
    @Binding var pair: KeyValuePair
    var keyPlaceholder: String = "Key"
    var valuePlaceholder: String = "Value"
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $pair.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            TextField(keyPlaceholder, text: $pair.key)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100)

            TextField(valuePlaceholder, text: $pair.value)
                .textFieldStyle(.roundedBorder)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .opacity(pair.isEnabled ? 1.0 : 0.5)
    }
}

struct KeyValueEditorView: View {
    @Binding var pairs: [KeyValuePair]
    var keyPlaceholder: String = "Key"
    var valuePlaceholder: String = "Value"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($pairs) { $pair in
                KeyValueRowView(
                    pair: $pair,
                    keyPlaceholder: keyPlaceholder,
                    valuePlaceholder: valuePlaceholder
                ) {
                    if let index = pairs.firstIndex(where: { $0.id == pair.id }) {
                        pairs.remove(at: index)
                    }
                }
            }

            Button(action: addNewPair) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
    }

    private func addNewPair() {
        pairs.append(KeyValuePair(key: "", value: ""))
    }
}

#Preview {
    @Previewable @State var pairs: [KeyValuePair] = [
        KeyValuePair(key: "Content-Type", value: "application/json"),
        KeyValuePair(key: "Authorization", value: "Bearer token123", isEnabled: false)
    ]

    KeyValueEditorView(pairs: $pairs)
        .frame(width: 500)
}
