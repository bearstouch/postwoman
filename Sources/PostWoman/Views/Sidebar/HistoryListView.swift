import SwiftUI
import SwiftData

struct HistoryListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RequestHistory.timestamp, order: .reverse) private var history: [RequestHistory]

    /// The entry shown in the detail column.
    @Binding var selectedHistory: RequestHistory?
    /// Opens an entry's request in the editor as a new request.
    let onRestore: (RequestHistory) -> Void

    @State private var searchText: String = ""
    @State private var selectionID: UUID?

    private var groupedHistory: [(String, [RequestHistory])] { SidebarActions.groupedByDay(filteredHistory) }

    private var filteredHistory: [RequestHistory] { SidebarActions.history(history, matching: searchText) }

    var body: some View {
        List(selection: $selectionID) {
            ForEach(groupedHistory, id: \.0) { date, items in
                Section(date) {
                    ForEach(items) { item in
                        HistoryRowView(item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("Open as New Request") {
                                    onRestore(item)
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
        .onAppear { selectionID = selectedHistory?.id }
        .onChange(of: selectionID) { _, id in
            guard id != selectedHistory?.id else { return }
            selectedHistory = history.first { $0.id == id }
        }
        .onChange(of: selectedHistory?.id) { _, id in
            if selectionID != id { selectionID = id }
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

    private func deleteHistoryItem(_ item: RequestHistory) {
        selectedHistory = SidebarActions.deleteHistory(item, selected: selectedHistory, context: modelContext)
    }

    private func clearHistory() {
        selectedHistory = nil
        SidebarActions.clearHistory(history, context: modelContext)
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
