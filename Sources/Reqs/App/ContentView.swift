import SwiftUI
import SwiftData

/// The root view of Reqs that provides the main 3-column interface.
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

    /// The window this view is in: menu commands are handled by the front window only.
    @State private var commandWindow = CommandWindow()

    /// Whether the Import sheet is open (File → Import…, or + → Import… in the sidebar).
    @State private var showingImport = false

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
                        Button {
                            showingImport = true
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New Folder or Import")
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
            ContentDetailView(selection: selection, onRestore: restore)
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
        .background(CommandWindowReader(holder: commandWindow, registers: true))
        .frame(minWidth: 1100, minHeight: 700)
        .onReceive(NotificationCenter.default.publisher(for: .createNewFolder)) { _ in
            guard commandWindow.acceptsCommands else { return }
            createFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .importCollections)) { _ in
            guard commandWindow.acceptsCommands else { return }
            showingImport = true
        }
        .sheet(isPresented: $showingImport) {
            ImportView(selectedCollection: currentFolder) { folder in
                if let folder { selection.sidebar = .folder(folder.id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportAllCollections)) { _ in
            guard commandWindow.acceptsCommands else { return }
            ExportImportService.exportAllWithDialog(folders)
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewRequest)) { _ in
            guard commandWindow.acceptsCommands else { return }
            createRequest()
        }
        .sheet(item: $selection.managedFolder) { folder in
            ManageEnvironmentsView(folder: folder)
        }
        .sheet(item: $selection.newEnvironmentFolder) { folder in
            NewEnvironmentView(folder: folder)
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageEnvironments)) { notification in
            guard commandWindow.acceptsCommands else { return }
            selection.managedFolder = selection.folder(for: notification.userInfo, in: folders)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEnvironment)) { notification in
            guard commandWindow.acceptsCommands else { return }
            selection.newEnvironmentFolder = selection.folder(for: notification.userInfo, in: folders)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectEnvironment)) { notification in
            guard commandWindow.acceptsCommands else { return }
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
}

/// The detail column: the selected History entry, else the request being edited, else the empty state.
struct ContentDetailView: View {
    let selection: ContentSelection
    let onRestore: (RequestHistory) -> Void

    var body: some View {
        switch selection.detail {
        case .history(let history):
            // One view per entry, so each opens on its own tab (Body for a body without params).
            HistoryDetailView(history: history, onRestore: onRestore)
                .id(history.id)
        case .request(let request):
            // One editor per request: without the identity, selecting another request would keep the first one's response,
            // send in flight, open tab and form fields, and an edit would then write those fields into the other request.
            RequestEditorView(request: request)
                .id(request.id)
        case .empty:
            EmptyStateView()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: AppSchema.models, inMemory: true)
}
