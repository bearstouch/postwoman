import SwiftUI

struct ResponseBodyView: View {
    let responseBody: String?
    let contentType: String?

    @State private var viewMode: ViewMode = .pretty
    @State private var formattedBody: String = ""

    enum ViewMode: String, CaseIterable {
        case pretty = "Pretty"
        case raw = "Raw"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View Mode", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                Spacer()

                if let ct = contentType {
                    Text(ct)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }

                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy to clipboard")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if let bodyContent = responseBody, !bodyContent.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(viewMode == .pretty ? formattedBody : bodyContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack {
                    Text("No response body")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            formatBody()
        }
        .onChange(of: responseBody) { _, _ in
            formatBody()
        }
    }

    private func formatBody() {
        guard let body = responseBody else {
            formattedBody = ""
            return
        }

        if contentType?.contains("json") == true {
            formattedBody = JSONFormatter.format(body) ?? body
        } else {
            formattedBody = body
        }
    }

    private func copyToClipboard() {
        let content = viewMode == .pretty ? formattedBody : (responseBody ?? "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}

#Preview {
    ResponseBodyView(
        responseBody: """
            {"id": 1, "name": "John Doe", "email": "john@example.com", "nested": {"key": "value"}}
            """,
        contentType: "application/json"
    )
    .frame(width: 600, height: 400)
}
