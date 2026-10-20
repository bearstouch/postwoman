import SwiftUI

struct ParamsTabView: View {
    @Binding var params: [KeyValuePair]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Query Parameters")
                        .font(.headline)
                    Spacer()
                    Text("\(params.filter { $0.isEnabled && !$0.key.isEmpty }.count) active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()

                Divider()

                KeyValueEditorView(
                    pairs: $params,
                    keyPlaceholder: "Parameter name",
                    valuePlaceholder: "Value"
                )
            }
        }
    }
}

#Preview {
    @Previewable @State var params: [KeyValuePair] = [
        KeyValuePair(key: "page", value: "1"),
        KeyValuePair(key: "limit", value: "10")
    ]

    ParamsTabView(params: $params)
        .frame(width: 600, height: 300)
}
