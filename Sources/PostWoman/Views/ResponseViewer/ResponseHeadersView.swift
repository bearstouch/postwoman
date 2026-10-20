import SwiftUI

struct ResponseHeadersView: View {
    let headers: [KeyValuePair]

    @State private var searchText: String = ""

    private var filteredHeaders: [KeyValuePair] {
        if searchText.isEmpty {
            return headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
        }
        return headers.filter {
            $0.key.localizedCaseInsensitiveContains(searchText) || $0.value.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.key.lowercased() < $1.key.lowercased() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search headers...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Spacer()

                Text("\(headers.count) headers")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    copyAllHeaders()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy all headers")
            }
            .padding()

            Divider()

            if headers.isEmpty {
                VStack {
                    Text("No response headers")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredHeaders) { header in
                        HeaderRowView(header: header)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func copyAllHeaders() {
        let headerString =
            headers
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(headerString, forType: .string)
    }
}

struct HeaderRowView: View {
    let header: KeyValuePair

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(header.key)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.postWomanPink)
                .frame(minWidth: 150, alignment: .trailing)

            Text(header.value)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(header.value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#Preview {
    ResponseHeadersView(headers: [
        KeyValuePair(key: "Content-Type", value: "application/json; charset=utf-8"),
        KeyValuePair(key: "Content-Length", value: "1234"),
        KeyValuePair(key: "Cache-Control", value: "no-cache"),
        KeyValuePair(key: "X-Request-Id", value: "abc123def456")
    ])
    .frame(width: 600, height: 400)
}
