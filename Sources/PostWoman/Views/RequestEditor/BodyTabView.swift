import SwiftUI

struct BodyTabView: View {
    @Binding var bodyType: ContentType
    @Binding var bodyContent: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Request Body")
                    .font(.headline)

                Spacer()

                Picker("Body Type", selection: $bodyType) {
                    ForEach(ContentType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            .padding()

            Divider()

            if bodyType == .none {
                VStack {
                    Spacer()
                    Text("This request does not have a body")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bodyType == .formData || bodyType == .urlEncoded {
                FormDataEditorView(bodyContent: $bodyContent)
            } else {
                TextEditor(text: $bodyContent)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                    .padding()
            }
        }
    }
}

struct FormDataEditorView: View {
    @Binding var bodyContent: String
    @State private var formPairs: [KeyValuePair] = []

    var body: some View {
        ScrollView {
            KeyValueEditorView(
                pairs: $formPairs,
                keyPlaceholder: "Field name",
                valuePlaceholder: "Value"
            )
        }
        .onAppear {
            parseFormData()
        }
        .onChange(of: formPairs) { _, newValue in
            serializeFormData(newValue)
        }
    }

    private func parseFormData() {
        guard !bodyContent.isEmpty else { return }
        formPairs = bodyContent.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { return nil }
            let value = parts.count > 1 ? String(parts[1]) : ""
            return KeyValuePair(
                key: String(key).removingPercentEncoding ?? String(key),
                value: value.removingPercentEncoding ?? value
            )
        }
    }

    private func serializeFormData(_ pairs: [KeyValuePair]) {
        bodyContent =
            pairs
            .filter { $0.isEnabled && !$0.key.isEmpty }
            .map { pair in
                let key = pair.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pair.key
                let value = pair.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pair.value
                return "\(key)=\(value)"
            }
            .joined(separator: "&")
    }
}

#Preview {
    @Previewable @State var bodyType: ContentType = .json
    @Previewable @State var bodyContent = """
        {
            "name": "John Doe",
            "email": "john@example.com"
        }
        """

    BodyTabView(bodyType: $bodyType, bodyContent: $bodyContent)
        .frame(width: 600, height: 400)
}
