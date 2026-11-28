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

    /// The sidebar item, the request or History entry shown, and the collection an environment sheet is open for.
    @State private var selection = ContentSelection()

    /// Enumeration representing the different sections available in the sidebar navigation.
    /// Each case corresponds to a different view that can be displayed in the content column.
    enum SidebarItem: Hashable {
        /// Shows the request history view with previously executed requests.
        case history
        /// Shows a specific folder and its requests.
        case folder(UUID)
    }

    /// Controls the visibility of the NavigationSplitView columns.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The main view body implementing a 3-column NavigationSplitView layout.
    /// - Sidebar: Navigation between Collections and History
    /// - Content: Context-specific view based on sidebar selection
    /// - Detail: Request editor and response viewer for selected requests
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Primary sidebar column with workspace navigation
            List(selection: $selection.sidebar) {
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
                    .help("New Folder or Import Collection")
                    .accessibilityLabel("Add Collection")
                }
            }
        } content: {
            // Content column that changes based on sidebar selection
            Group {
                switch selection.sidebar {
                case .history:
                    HistoryListView(selectedHistory: $selection.history, onRestore: restore)
                case .folder(let folderID):
                    if let folder = folders.first(where: { $0.id == folderID }) {
                        FolderRequestsListView(folder: folder, selectedRequest: $selection.request)
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
                if selection.sidebar == .history, let history = selection.history, !history.isDeleted {
                    HistoryDetailView(history: history, onRestore: restore)
                } else if let request = selection.request, !request.isDeleted {
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
        .sheet(item: $selection.managedFolder) { folder in
            ManageEnvironmentsView(folder: folder)
        }
        .sheet(item: $selection.newEnvironmentFolder) { folder in
            NewEnvironmentView(folder: folder)
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageEnvironments)) { notification in
            selection.managedFolder = selection.folder(for: notification.userInfo, in: folders)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEnvironment)) { notification in
            selection.newEnvironmentFolder = selection.folder(for: notification.userInfo, in: folders)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectEnvironment)) { notification in
            selection.selectEnvironment(notification.userInfo, in: folders)
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteAgentWillDelete)) { notification in
            // An agent is deleting models over MCP: never keep showing one that is gone.
            guard let ids = notification.userInfo?["ids"] as? Set<UUID> else { return }
            selection.dropSelections(of: ids)
        }
    }

    /// The collection whose environment the toolbar shows and the Environment menu changes.
    private var currentFolder: Folder? { selection.currentFolder(in: folders) }

    /// Creates a new folder/collection at the root level.
    private func createFolder() { selection.createFolder(in: folders, context: modelContext) }

    /// Creates a new request in the currently selected folder, or the first folder, or a new folder.
    private func createRequest() { selection.createRequest(in: folders, context: modelContext) }

    /// Opens a history entry's request in the editor as a new request.
    private func restore(_ history: RequestHistory) { selection.restore(history, in: folders, context: modelContext) }

    /// Deletes the folders at the specified indices.
    private func deleteFolders(at offsets: IndexSet) {
        for folder in offsets.map({ folders[$0] }) { SidebarActions.deleteFolder(folder, context: modelContext) }
    }

    /// Imports a collection from a JSON file.
    private func importCollection() {
        ExportImportService.importFolderWithDialog(
            context: modelContext,
            existingFolderCount: folders.count
        ) { importedFolder in
            if let folder = importedFolder {
                selection.sidebar = .folder(folder.id)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: AppSchema.models, inMemory: true)
}
