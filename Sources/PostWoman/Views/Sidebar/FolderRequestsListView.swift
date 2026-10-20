import SwiftUI
import SwiftData

struct FolderRequestsListView: View {
    @Environment(\.modelContext) private var modelContext
    let folder: Folder
    @Binding var selectedRequest: APIRequest?

    @State private var searchText: String = ""

    private var filteredRequests: [APIRequest] {
        let requests = folder.requests?.sorted(by: { $0.sortOrder < $1.sortOrder }) ?? []
        if searchText.isEmpty {
            return requests
        }
        return requests.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.url.localizedCaseInsensitiveContains(searchText) }
    }

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
        .background(.white)
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
        let request = APIRequest(name: "New Request", folder: folder)
        request.sortOrder = folder.requests?.count ?? 0
        modelContext.insert(request)
        selectedRequest = request
    }

    private func duplicateRequest(_ request: APIRequest) {
        let newRequest = APIRequest(
            name: "\(request.name) Copy",
            url: request.url,
            method: request.method,
            folder: folder
        )
        newRequest.headers = request.headers
        newRequest.queryParams = request.queryParams
        newRequest.bodyType = request.bodyType
        newRequest.bodyContent = request.bodyContent
        newRequest.authenticationType = request.authenticationType
        newRequest.sortOrder = (folder.requests?.count ?? 0)

        modelContext.insert(newRequest)
        selectedRequest = newRequest
    }

    private func deleteRequest(_ request: APIRequest) {
        modelContext.delete(request)
        if selectedRequest?.id == request.id {
            selectedRequest = nil
        }
    }
}
