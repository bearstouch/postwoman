import SwiftUI

struct HeadersTabView: View {
    @Binding var headers: [KeyValuePair]

    private let commonHeaders = [
        "Content-Type",
        "Accept",
        "Authorization",
        "Cache-Control",
        "User-Agent",
        "X-API-Key"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Request Headers")
                        .font(.headline)
                    Spacer()

                    Menu {
                        ForEach(commonHeaders, id: \.self) { header in
                            Button(header) {
                                addHeader(key: header)
                            }
                        }
                    } label: {
                        Label("Common Headers", systemImage: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 150)
                }
                .padding()

                Divider()

                KeyValueEditorView(
                    pairs: $headers,
                    keyPlaceholder: "Header name",
                    valuePlaceholder: "Value"
                )
            }
        }
    }

    private func addHeader(key: String) {
        headers.append(KeyValuePair(key: key, value: ""))
    }
}

#Preview {
    @Previewable @State var headers: [KeyValuePair] = [
        KeyValuePair(key: "Content-Type", value: "application/json"),
        KeyValuePair(key: "Accept", value: "application/json")
    ]

    HeadersTabView(headers: $headers)
        .frame(width: 600, height: 300)
}
