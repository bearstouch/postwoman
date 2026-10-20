import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RequestHistory.timestamp, order: .reverse) private var history: [RequestHistory]

    @Binding var selectedRequest: APIRequest?

    @State private var searchText: String = ""

    private var groupedHistory: [(String, [RequestHistory])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredHistory) { item -> String in
            if calendar.isDateInToday(item.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(item.timestamp) {
                return "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return formatter.string(from: item.timestamp)
            }
        }
        return grouped.sorted { $0.value.first?.timestamp ?? Date() > $1.value.first?.timestamp ?? Date() }
    }

    private var filteredHistory: [RequestHistory] {
        if searchText.isEmpty {
            return history
        }
        return history.filter { item in
            item.url.localizedCaseInsensitiveContains(searchText) || item.method.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            ForEach(groupedHistory, id: \.0) { date, items in
                Section(date) {
                    ForEach(items) { item in
                        HistoryRowView(item: item)
                            .contextMenu {
                                Button("Restore to New Request") {
                                    restoreRequest(from: item)
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deleteHistoryItem(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.listBackground)
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search history")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: clearHistory) {
                    Image(systemName: "trash")
                }
                .help("Clear History")
                .disabled(history.isEmpty)
            }
        }
        .overlay {
            if history.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("Your request history will appear here")
                )
            }
        }
    }

    private func restoreRequest(from historyItem: RequestHistory) {
        let request = APIRequest(
            name: "Restored: \(historyItem.url)",
            url: historyItem.url,
            method: historyItem.method
        )
        request.headers = historyItem.requestHeaders
        if let body = historyItem.requestBody {
            request.bodyContent = body
            request.bodyType = .json
        }
        modelContext.insert(request)
        selectedRequest = request
    }

    private func deleteHistoryItem(_ item: RequestHistory) {
        modelContext.delete(item)
    }

    private func clearHistory() {
        for item in history {
            modelContext.delete(item)
        }
    }
}

struct HistoryRowView: View {
    let item: RequestHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.method.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(item.method.color)

                if let statusCode = item.statusCode {
                    Text("\(statusCode)")
                        .font(.caption)
                        .foregroundColor(Theme.status(statusCode))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.status(statusCode).opacity(0.15))
                        .cornerRadius(3)
                }

                Spacer()

                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(item.url)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

}
