import SwiftUI
import SwiftData

/// The root view of PostWoman that provides the main 3-column interface.
/// Implements a NavigationSplitView with sidebar navigation for Collections
/// and History, with request editing and response viewing in the detail area.
struct ContentView: View {
    /// Access to the SwiftData model context for database operations.
    @Environment(\.modelContext) private var modelContext

    /// Query for all folders sorted by their display order.
    @Query(sort: \Folder.sortOrder)
    private var folders: [Folder]

    /// The currently selected API request being edited or viewed.
    @State private var selectedRequest: APIRequest?

    /// Enumeration representing the different sections available in the sidebar navigation.
    /// Each case corresponds to a different view that can be displayed in the content column.
    enum SidebarItem: Hashable {
        /// Shows the request history view with previously executed requests.
        case history
        /// Shows a specific folder and its requests.
        case folder(UUID)
    }

    /// The currently selected item in the sidebar navigation.
    @State private var sidebarSelection: SidebarItem? = .history

    /// Controls the visibility of the NavigationSplitView columns.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The main view body implementing a 3-column NavigationSplitView layout.
    /// - Sidebar: Navigation between Collections and History
    /// - Content: Context-specific view based on sidebar selection
    /// - Detail: Request editor and response viewer for selected requests
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Primary sidebar column with workspace navigation
            List(selection: $sidebarSelection) {
                Section("General") {
                    Label("History", systemImage: "clock")
                        .tag(SidebarItem.history)
                }

                Section("Collections") {
                    ForEach(folders) { folder in
                        FolderRowView(folder: folder)
                            .tag(SidebarItem.folder(folder.id))
                    }
                    .onDelete(perform: deleteFolders)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: createFolder) {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button(action: importCollection) {
                            Label("Import Collection...", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        } content: {
            // Content column that changes based on sidebar selection
            Group {
                switch sidebarSelection {
                case .history:
                    HistoryListView(selectedRequest: $selectedRequest)
                case .folder(let folderID):
                    if let folder = folders.first(where: { $0.id == folderID }) {
                        FolderRequestsListView(folder: folder, selectedRequest: $selectedRequest)
                    } else {
                        ContentUnavailableView("Folder not found", systemImage: "folder.badge.questionmark")
                    }
                case .none:
                    Text("Select a collection")
                        .foregroundColor(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 300)
        } detail: {
            // Detail column showing request editor or empty state
            Group {
                if let request = selectedRequest {
                    RequestEditorView(request: request)
                } else {
                    EmptyStateView()
                }
            }
            .frame(minWidth: 600, idealWidth: 600)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 700)
        .onReceive(NotificationCenter.default.publisher(for: .createNewFolder)) { _ in
            createFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewRequest)) { _ in
            createRequest()
        }
    }

    /// Creates a new folder/collection at the root level.
    private func createFolder() {
        let folder = Folder(name: "New Collection", sortOrder: folders.count)
        modelContext.insert(folder)
        sidebarSelection = .folder(folder.id)
    }

    /// Creates a new request in the currently selected folder, or the first folder, or a new folder.
    private func createRequest() {
        let folder: Folder
        if case .folder(let folderID) = sidebarSelection,
            let selectedFolder = folders.first(where: { $0.id == folderID })
        {
            folder = selectedFolder
        } else if let firstFolder = folders.first {
            folder = firstFolder
            sidebarSelection = .folder(folder.id)
        } else {
            folder = Folder(name: "Default Collection")
            modelContext.insert(folder)
            sidebarSelection = .folder(folder.id)
        }

        let request = APIRequest(name: "New Request", folder: folder)
        request.sortOrder = folder.requests?.count ?? 0
        modelContext.insert(request)
        selectedRequest = request
    }

    /// Deletes the folders at the specified indices.
    private func deleteFolders(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(folders[index])
        }
    }

    /// Imports a collection from a JSON file.
    private func importCollection() {
        ExportImportService.importFolderWithDialog(
            context: modelContext,
            existingFolderCount: folders.count
        ) { importedFolder in
            if let folder = importedFolder {
                sidebarSelection = .folder(folder.id)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                Folder.self,
                APIRequest.self,
                RequestHistory.self
            ], inMemory: true)
}
