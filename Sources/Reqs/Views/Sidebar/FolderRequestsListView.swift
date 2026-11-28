import SwiftUI
import SwiftData

struct FolderRequestsListView: View {
    @Environment(\.modelContext) private var modelContext
    let folder: Folder
    @Binding var selectedRequest: APIRequest?

    @State private var searchText: String = ""

    private var filteredRequests: [APIRequest] { SidebarActions.requests(in: folder, matching: searchText) }

    var body: some View {
        List(selection: $selectedRequest) {
            ForEach(filteredRequests) { request in
                RequestRowView(request: request)
                    .tag(request)
                    .contextMenu {
                        Button(action: { duplicateRequest(request) }) {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Divider()
                        Button(role: .destructive, action: { deleteRequest(request) }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.listBackground)
        .navigationTitle(folder.name)
        .searchable(text: $searchText, prompt: "Search requests")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createRequest) {
                    Label("New Request", systemImage: "plus")
                }
            }
        }
        .overlay {
            if filteredRequests.isEmpty {
                ContentUnavailableView(
                    "No Requests",
                    systemImage: "plus.circle",
                    description: Text("Create a new request to get started")
                )
            }
        }
    }

    private func createRequest() {
        selectedRequest = SidebarActions.createRequest(in: folder, context: modelContext)
    }

    private func duplicateRequest(_ request: APIRequest) {
        selectedRequest = SidebarActions.duplicate(request, in: folder, context: modelContext)
    }

    private func deleteRequest(_ request: APIRequest) {
        selectedRequest = SidebarActions.delete(request, selected: selectedRequest, context: modelContext)
    }
}
