import SwiftUI

struct KeyValueRowView: View {
    @Binding var pair: KeyValuePair
    var keyPlaceholder: String = "Key"
    var valuePlaceholder: String = "Value"
    /// When set, a mark after the value says what its `{{variables}}` resolve to.
    var resolver: VariableResolver?
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $pair.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            TextField(keyPlaceholder, text: $pair.key)
                .textFieldStyle(.themed)
                .frame(minWidth: 100)

            TextField(valuePlaceholder, text: $pair.value)
                .textFieldStyle(.themed)

            if let resolver {
                VariableStatusMark(texts: [pair.key, pair.value], resolver: resolver)
            }

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
    var resolver: VariableResolver?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($pairs) { $pair in
                KeyValueRowView(
                    pair: $pair,
                    keyPlaceholder: keyPlaceholder,
                    valuePlaceholder: valuePlaceholder,
                    resolver: resolver
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

/// A small mark for a field that uses `{{variables}}`: what they resolve to, or which are not defined.
/// Shows nothing when the text uses none.
struct VariableStatusMark: View {
    let texts: [String]
    let resolver: VariableResolver

    var body: some View {
        let tokens = texts.flatMap { resolver.tokens(in: $0) }
        if !tokens.isEmpty {
            let missing = texts.flatMap { resolver.missingVariables(in: $0) }
            Image(systemName: missing.isEmpty ? "curlybraces" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(missing.isEmpty ? Theme.info : Theme.warning)
                .frame(width: 16)
                .help(VariableDescription.help(for: tokens, resolver: resolver))
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
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
