import SwiftUI

/// A read-only view of a history entry: the request as it was sent above, the response it got below.
struct HistoryDetailView: View {
    let history: RequestHistory
    /// Opens the entry's request in the editor as a new request.
    let onRestore: (RequestHistory) -> Void

    /// Starts on `RequestTab.initial(for:)`; the view's identity is the entry, so each entry opens on its own.
    @State private var selectedTab: RequestTab

    init(history: RequestHistory, onRestore: @escaping (RequestHistory) -> Void) {
        self.history = history
        self.onRestore = onRestore
        _selectedTab = State(initialValue: RequestTab.initial(for: history))
    }

    private var enabledParams: [KeyValuePair] {
        (history.queryParams ?? []).filter { $0.isEnabled && !$0.key.isEmpty }
    }

    private var enabledHeaders: [KeyValuePair] {
        history.requestHeaders.filter { $0.isEnabled && !$0.key.isEmpty }
    }

    private var authenticationType: AuthenticationType {
        history.authenticationType ?? .none
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Theme.bar)

                HairlineDivider()

                tabBar

                HairlineDivider()

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 260)
            .background(Theme.canvas)

            ResponseViewerView(response: history.response, isLoading: false)
                .frame(minHeight: 200)
                .themedSplitDividers()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onRestore(history)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Open as New Request")
                .accessibilityLabel("Open as New Request")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(history.requestName ?? "History")
                    .font(.headline)
                Spacer()
                Text(history.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text(history.method.rawValue)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(history.method.color)
                    .frame(width: 70, alignment: .leading)

                Text(history.url)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(history.url)

                Button("Open as Request") {
                    onRestore(history)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(RequestTab.allCases) { tab in
                TabButton(title: tab.rawValue, isSelected: selectedTab == tab, badge: badge(for: tab)) {
                    selectedTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.bar)
    }

    private func badge(for tab: RequestTab) -> Int? {
        switch tab {
        case .params: return enabledParams.isEmpty ? nil : enabledParams.count
        case .headers: return enabledHeaders.isEmpty ? nil : enabledHeaders.count
        case .body: return history.requestBody == nil && history.bodyType != .file ? nil : 1
        case .auth: return authenticationType == .none ? nil : 1
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .params:
            KeyValueListView(pairs: enabledParams, emptyMessage: "No query parameters")
        case .headers:
            KeyValueListView(pairs: enabledHeaders, emptyMessage: "No request headers")
        case .body:
            if let file = Self.fileSummary(of: history) {
                VStack(spacing: 6) {
                    Label(file, systemImage: "doc")
                        .font(.body.monospaced())
                    Text("History keeps a file's name and size, not its contents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ResponseBodyView(
                    responseBody: history.requestBody,
                    contentType: history.bodyType?.mimeType,
                    emptyMessage: "No request body"
                )
            }
        case .auth:
            KeyValueListView(pairs: authPairs, emptyMessage: "No authentication")
        }
    }

    /// The file a File body sent, as "name · size · type", or nil for another body.
    static func fileSummary(of history: RequestHistory) -> String? {
        guard history.bodyType == .file else { return nil }
        let name = history.requestBodyFileName ?? "Unnamed file"
        var parts = [name]
        if let size = history.requestBodyFileSize { parts.append(FileBody.formattedSize(size)) }
        // The type it went out as: the request's own Content-Type header, else the one its name gives.
        let header = history.requestHeaders.last { $0.isEnabled && $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        parts.append(header ?? FileBody.mimeType(forFileName: history.requestBodyFileName))
        return parts.joined(separator: " · ")
    }

    /// A credential as History shows it: one dot per character, as the editor's secure fields hide it. One written only as
    /// `{{variables}}` holds no secret (History keeps secret variables as their names), so it stays readable.
    static func masked(_ credential: String) -> String {
        let literal = credential.replacing(/\{\{[^{}]+\}\}/, with: "").trimmingCharacters(in: .whitespaces)
        return literal.isEmpty ? credential : String(repeating: "•", count: credential.count)
    }

    private var authPairs: [KeyValuePair] {
        switch authenticationType {
        case .none:
            return []
        case .bearer:
            return [
                KeyValuePair(key: "Type", value: authenticationType.rawValue),
                KeyValuePair(key: "Token", value: Self.masked(history.authBearerToken ?? ""))
            ]
        case .basic:
            return [
                KeyValuePair(key: "Type", value: authenticationType.rawValue),
                KeyValuePair(key: "Username", value: history.authBasicUsername ?? ""),
                KeyValuePair(key: "Password", value: Self.masked(history.authBasicPassword ?? ""))
            ]
        case .oauth2:
            return [KeyValuePair(key: "Type", value: authenticationType.rawValue)]
        }
    }
}

/// A read-only two-column list of key-value pairs, in the style of the response headers.
private struct KeyValueListView: View {
    let pairs: [KeyValuePair]
    let emptyMessage: String

    var body: some View {
        if pairs.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.field)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pairs) { pair in
                        HeaderRowView(header: pair, keyWidth: 160)
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
