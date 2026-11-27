import AppKit
import SwiftUI

/// The response headers as a two-column table: names in a fixed column, values beside them.
/// Comma-separated lists of tokens (`Access-Control-Expose-Headers`, `Vary`, `Allow`) show as chips
/// so they wrap between items instead of in the middle of a name.
struct ResponseHeadersView: View {
    let headers: [KeyValuePair]

    @State private var searchText: String = ""

    private static let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

    private var sortedHeaders: [KeyValuePair] {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
    }

    private var filteredHeaders: [KeyValuePair] {
        guard !searchText.isEmpty else { return sortedHeaders }
        return sortedHeaders.filter {
            $0.key.localizedCaseInsensitiveContains(searchText) || $0.value.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Wide enough for the longest name, between 120 and 260 points; longer names are truncated.
    private var keyColumnWidth: CGFloat {
        let longest = headers.map { ($0.key as NSString).size(withAttributes: [.font: Self.keyFont]).width }.max() ?? 0
        return min(max(ceil(longest) + 4, 120), 260)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if headers.isEmpty {
                placeholder("No response headers")
            } else if filteredHeaders.isEmpty {
                placeholder("No headers match \u{201C}\(searchText)\u{201D}")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredHeaders) { header in
                            HeaderRowView(header: header, keyWidth: keyColumnWidth)
                            Rectangle()
                                .fill(Theme.hairline.opacity(0.6))
                                .frame(height: 1)
                                .padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Theme.field)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter headers", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 240, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))

            Spacer()

            Text(searchText.isEmpty ? "\(headers.count) headers" : "\(filteredHeaders.count) of \(headers.count)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)

            ResponseIconButton(systemImage: "doc.on.doc", help: "Copy all headers") {
                copy(sortedHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
            }
            .disabled(headers.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.field)
    }

    /// The items of a header value that is a comma-separated list of tokens, or nil when it isn't
    /// one (a date, a single value, or anything with spaces inside an item).
    static func listItems(in value: String) -> [String]? {
        guard value.contains(",") else { return nil }
        let items = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.count >= 3, items.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        return items
    }
}

private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

struct HeaderRowView: View {
    let header: KeyValuePair
    let keyWidth: CGFloat

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(header.key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: CodePalette.key))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: keyWidth, alignment: .leading)
                .help(header.key)

            value
                .frame(maxWidth: .infinity, alignment: .leading)

            ResponseIconButton(systemImage: "doc.on.doc", help: "Copy value") {
                copy(header.value)
            }
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(isHovering ? Theme.chip.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Name") { copy(header.key) }
            Button("Copy Value") { copy(header.value) }
            Button("Copy Header") { copy("\(header.key): \(header.value)") }
        }
    }

    @ViewBuilder
    private var value: some View {
        if let items = ResponseHeadersView.listItems(in: header.value) {
            FlowLayout(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                }
            }
        } else {
            Text(header.value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Lays its children out in rows, wrapping to a new row when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > maxWidth, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

#Preview {
    ResponseHeadersView(headers: [
        KeyValuePair(key: "Content-Type", value: "application/json; charset=utf-8"),
        KeyValuePair(key: "access-control-expose-headers", value: "X-Request-Id,X-RateLimit-Limit,X-RateLimit-Remaining,X-RateLimit-Reset,Retry-After"),
        KeyValuePair(key: "Date", value: "Fri, 27 Nov 2026 17:24:32 GMT"),
        KeyValuePair(key: "X-Request-Id", value: "abc123def456")
    ])
    .frame(width: 600, height: 400)
}
