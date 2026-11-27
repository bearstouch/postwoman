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

    /// The history entry shown in the detail column while History is selected.
    @State private var selectedHistory: RequestHistory?

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

    /// The collection whose environments the Manage Environments sheet shows.
    @State private var managedFolder: Folder?

    /// The collection the New Environment sheet adds to.
    @State private var newEnvironmentFolder: Folder?

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
                    HistoryListView(selectedHistory: $selectedHistory, onRestore: restore)
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
            .overlay(alignment: .top) { HairlineDivider() }
            .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 300)
        } detail: {
            // Detail column showing request editor or empty state
            Group {
                if sidebarSelection == .history, let history = selectedHistory, !history.isDeleted {
                    HistoryDetailView(history: history, onRestore: restore)
                } else if let request = selectedRequest, !request.isDeleted {
                    RequestEditorView(request: request)
                } else {
                    EmptyStateView()
                }
            }
            .overlay(alignment: .top) { HairlineDivider() }
            .themedSplitDividers()
            .frame(minWidth: 600, idealWidth: 600)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EnvironmentMenu(folder: currentFolder)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // The window draws no titlebar separator; each pane's top hairline (above) takes its place.
        .background(ThemedWindowChrome())
        .frame(minWidth: 1100, minHeight: 700)
        .onReceive(NotificationCenter.default.publisher(for: .createNewFolder)) { _ in
            createFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewRequest)) { _ in
            createRequest()
        }
        .sheet(item: $managedFolder) { folder in
            ManageEnvironmentsView(folder: folder)
        }
        .sheet(item: $newEnvironmentFolder) { folder in
            NewEnvironmentView(folder: folder)
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageEnvironments)) { notification in
            managedFolder = folder(for: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEnvironment)) { notification in
            newEnvironmentFolder = folder(for: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectEnvironment)) { notification in
            guard let folder = currentFolder, let index = notification.userInfo?["index"] as? Int else { return }
            let environments = folder.overrideEnvironments
            if index == 0 {
                folder.selectedEnvironmentID = nil
            } else if index <= environments.count {
                folder.selectedEnvironment = environments[index - 1]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteAgentWillDelete)) { notification in
            // An agent is deleting models over MCP: never keep showing one that is gone.
            guard let ids = notification.userInfo?["ids"] as? Set<UUID> else { return }
            if let request = selectedRequest, ids.contains(request.id) { selectedRequest = nil }
            if let history = selectedHistory, ids.contains(history.id) { selectedHistory = nil }
            if case .folder(let folderID) = sidebarSelection, ids.contains(folderID) { sidebarSelection = .history }
            if let folder = managedFolder, ids.contains(folder.id) { managedFolder = nil }
            if let folder = newEnvironmentFolder, ids.contains(folder.id) { newEnvironmentFolder = nil }
        }
    }

    /// The collection of the request being edited, else the selected collection. Its environment is the one the
    /// toolbar shows and the Environment menu changes.
    private var currentFolder: Folder? {
        if sidebarSelection != .history, let request = selectedRequest, !request.isDeleted, let folder = request.folder { return folder }
        if case .folder(let folderID) = sidebarSelection { return folders.first { $0.id == folderID } }
        return nil
    }

    /// The collection a notification names (`userInfo["folderID"]`), else the current one.
    private func folder(for notification: Notification) -> Folder? {
        guard let id = notification.userInfo?["folderID"] as? UUID else { return currentFolder }
        return folders.first { $0.id == id }
    }

    /// Creates a new folder/collection at the root level.
    private func createFolder() {
        let folder = Folder(name: "New Collection", sortOrder: folders.count)
        modelContext.insert(folder)
        folder.ensureDefaultEnvironment()
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
            folder.ensureDefaultEnvironment()
            sidebarSelection = .folder(folder.id)
        }

        let request = APIRequest(name: "New Request", folder: folder)
        request.sortOrder = folder.requests?.count ?? 0
        modelContext.insert(request)
        selectedRequest = request
    }

    /// Opens a history entry's request in the editor as a new request in the first collection
    /// (a new one when there is none), so it stays in the sidebar.
    private func restore(_ history: RequestHistory) {
        let folder: Folder
        if let firstFolder = folders.first {
            folder = firstFolder
        } else {
            folder = Folder(name: "Default Collection")
            modelContext.insert(folder)
            folder.ensureDefaultEnvironment()
        }
        let request = history.makeRequest(folder: folder)
        request.sortOrder = folder.requests?.count ?? 0
        modelContext.insert(request)
        selectedHistory = nil
        selectedRequest = request
        sidebarSelection = .folder(folder.id)
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
        .modelContainer(for: AppSchema.models, inMemory: true)
}
