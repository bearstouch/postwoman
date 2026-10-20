import SwiftUI

struct ResponseStatusView: View {
    let response: HTTPResponse

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("\(response.statusCode)")
                    .font(.system(.headline, design: .monospaced))
                Text(response.statusText)
                    .foregroundColor(.secondary)
            }

            Divider()
                .frame(height: 16)

            Label("\(Int(response.responseTime)) ms", systemImage: "clock")
                .font(.caption)
                .foregroundColor(.secondary)

            if let body = response.body {
                let size = body.data(using: .utf8)?.count ?? 0
                Label(formatBytes(size), systemImage: "doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                if let body = response.body {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy response body")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(statusColor.opacity(0.08))
    }

    private var statusColor: Color {
        switch response.statusCode {
        case 200..<300: return .green
        case 300..<400: return .orange
        case 400..<500: return .red
        case 500..<600: return .red
        default: return .gray
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}
