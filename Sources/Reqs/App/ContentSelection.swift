import Foundation
import SwiftData

/// What the main window shows: the sidebar item, the request or History entry in the detail column, and the collection an
/// environment sheet is open for. `ContentView` keeps one and applies menu commands and agent deletions to it here, so
/// they can be tested on a store.
@MainActor
struct ContentSelection {
    /// The sidebar item: History or a collection.
    var sidebar: ContentView.SidebarItem? = .history

    /// The request being edited.
    var request: APIRequest?

    /// The history entry shown in the detail column while History is selected.
    var history: RequestHistory?

    /// The collection whose environments the Manage Environments sheet shows.
    var managedFolder: Folder?

    /// The collection the New Environment sheet adds to.
    var newEnvironmentFolder: Folder?

    /// What the detail column shows.
    enum Detail {
        case history(RequestHistory), request(APIRequest), empty
    }

    /// The chosen History entry while History is selected, else the request being edited, else nothing.
    var detail: Detail {
        if sidebar == .history, let history, !history.isDeleted { return .history(history) }
        if let request, !request.isDeleted { return .request(request) }
        return .empty
    }

    /// The collection of the request on screen, else the selected collection. Its environment is the one the toolbar
    /// shows and the Environment menu changes, so it must be the one that request is sent with: also in History, which
    /// keeps showing the editor until an entry is chosen.
    func currentFolder(in folders: [Folder]) -> Folder? {
        if case .request(let request) = detail, let folder = request.folder { return folder }
        if case .folder(let folderID) = sidebar { return folders.first { $0.id == folderID } }
        return nil
    }

    /// The collection a notification names (`userInfo["folderID"]`), else the current one.
    func folder(for userInfo: [AnyHashable: Any]?, in folders: [Folder]) -> Folder? {
        guard let id = userInfo?["folderID"] as? UUID else { return currentFolder(in: folders) }
        return folders.first { $0.id == id }
    }

    /// New Folder: a "New Collection" at the end, with its Default environment, selected.
    @discardableResult
    mutating func createFolder(in folders: [Folder], context: ModelContext) -> Folder {
        let folder = Folder(name: "New Collection", sortOrder: Folder.nextSortOrder(after: folders))
        context.insert(folder)
        folder.ensureDefaultEnvironment()
        sidebar = .folder(folder.id)
        return folder
    }

    /// New Request: a "New Request" in the selected collection, or the first one, or a new "Default Collection"; selected.
    @discardableResult
    mutating func createRequest(in folders: [Folder], context: ModelContext) -> APIRequest {
        let folder: Folder
        if case .folder(let folderID) = sidebar, let selectedFolder = folders.first(where: { $0.id == folderID }) {
            folder = selectedFolder
        } else if let firstFolder = folders.first {
            folder = firstFolder
            sidebar = .folder(folder.id)
        } else {
            folder = Folder(name: "Default Collection")
            context.insert(folder)
            folder.ensureDefaultEnvironment()
            sidebar = .folder(folder.id)
        }

        let request = APIRequest(name: "New Request", folder: folder)
        request.sortOrder = folder.nextRequestSortOrder(excluding: request)
        context.insert(request)
        self.request = request
        return request
    }

    /// Opens a history entry's request in the editor as a new request in the first collection
    /// (a new one when there is none), so it stays in the sidebar.
    @discardableResult
    mutating func restore(_ history: RequestHistory, in folders: [Folder], context: ModelContext) -> APIRequest {
        let folder: Folder
        if let firstFolder = folders.first {
            folder = firstFolder
        } else {
            folder = Folder(name: "Default Collection")
            context.insert(folder)
            folder.ensureDefaultEnvironment()
        }
        let request = history.makeRequest(folder: folder)
        request.sortOrder = folder.nextRequestSortOrder(excluding: request)
        context.insert(request)
        self.history = nil
        self.request = request
        sidebar = .folder(folder.id)
        return request
    }

    /// ⌃0…⌃9 (`userInfo["index"]`): picks the current collection's environment. Nothing happens without one.
    func selectEnvironment(_ userInfo: [AnyHashable: Any]?, in folders: [Folder]) {
        guard let folder = currentFolder(in: folders), let index = userInfo?["index"] as? Int else { return }
        EnvironmentActions.select(index: index, in: folder)
    }

    /// Models are about to be deleted (by an agent, or History trimming): never keep showing one that is gone.
    mutating func dropSelections(of ids: Set<UUID>) {
        if let request, ids.contains(request.id) { self.request = nil }
        if let history, ids.contains(history.id) { self.history = nil }
        if case .folder(let folderID) = sidebar, ids.contains(folderID) { sidebar = .history }
        if let folder = managedFolder, ids.contains(folder.id) { managedFolder = nil }
        if let folder = newEnvironmentFolder, ids.contains(folder.id) { newEnvironmentFolder = nil }
    }
}
