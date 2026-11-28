import Foundation
import SwiftData

/// What the request list and History list do to the store (create, copy, delete, search, group), kept out of the views so
/// it can be tested on a store. Each action that can remove the selected item returns the selection to keep.
@MainActor
enum SidebarActions {
    /// `folder`'s requests in their order, narrowed to those whose name or URL contains `searchText` (any case).
    static func requests(in folder: Folder, matching searchText: String) -> [APIRequest] {
        let requests = folder.requests?.sorted(by: { $0.sortOrder < $1.sortOrder }) ?? []
        if searchText.isEmpty { return requests }
        return requests.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.url.localizedCaseInsensitiveContains(searchText) }
    }

    /// A new "New Request" at the end of `folder`.
    static func createRequest(in folder: Folder, context: ModelContext) -> APIRequest {
        let request = APIRequest(name: "New Request", folder: folder)
        request.sortOrder = folder.nextRequestSortOrder(excluding: request)
        context.insert(request)
        return request
    }

    /// A copy of `request` (with its credentials) named "<name> Copy" at the end of `folder`.
    static func duplicate(_ request: APIRequest, in folder: Folder, context: ModelContext) -> APIRequest {
        let newRequest = APIRequest(name: "\(request.name) Copy", url: request.url, method: request.method, folder: folder)
        newRequest.headers = request.headers
        newRequest.queryParams = request.queryParams
        newRequest.bodyType = request.bodyType
        newRequest.bodyContent = request.bodyContent
        newRequest.bodyFile = request.bodyFile
        newRequest.bodyFileName = request.bodyFileName
        newRequest.bodyFileSize = request.bodyFileSize
        newRequest.authenticationType = request.authenticationType
        newRequest.authBearerToken = request.authBearerToken
        newRequest.authBasicUsername = request.authBasicUsername
        newRequest.authBasicPassword = request.authBasicPassword
        newRequest.authOAuthConfig = request.authOAuthConfig
        newRequest.sortOrder = folder.nextRequestSortOrder(excluding: newRequest)
        context.insert(newRequest)
        return newRequest
    }

    /// Deletes `request`. Returns the selection to keep: nil if `selected` was it.
    static func delete(_ request: APIRequest, selected: APIRequest?, context: ModelContext) -> APIRequest? {
        context.delete(request)
        return selected?.id == request.id ? nil : selected
    }

    /// Deletes a collection with its requests and environments. It is announced first (as an agent's deletions are),
    /// so the window stops showing the collection and the request open from it.
    static func deleteFolder(_ folder: Folder, context: ModelContext) {
        let ids = [folder.id] + (folder.requests ?? []).map(\.id) + (folder.environments ?? []).map(\.id)
        NotificationCenter.default.post(name: .remoteAgentWillDelete, object: nil, userInfo: ["ids": Set(ids)])
        context.delete(folder)
    }

    /// The entries whose URL or method contains `searchText` (any case); all of them when it is empty.
    static func history(_ history: [RequestHistory], matching searchText: String) -> [RequestHistory] {
        if searchText.isEmpty { return history }
        return history.filter { item in
            item.url.localizedCaseInsensitiveContains(searchText) || item.method.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// The entries in sections by day ("Today", "Yesterday", else the medium date), newest section first.
    static func groupedByDay(_ history: [RequestHistory], calendar: Calendar = .current) -> [(String, [RequestHistory])] {
        let grouped = Dictionary(grouping: history) { item -> String in
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

    /// Deletes one History entry. Returns the selection to keep: nil if `selected` was it.
    static func deleteHistory(_ item: RequestHistory, selected: RequestHistory?, context: ModelContext) -> RequestHistory? {
        let kept = selected?.id == item.id ? nil : selected
        context.delete(item)
        return kept
    }

    /// Deletes every entry in `history`.
    static func clearHistory(_ history: [RequestHistory], context: ModelContext) {
        for item in history { context.delete(item) }
    }
}
