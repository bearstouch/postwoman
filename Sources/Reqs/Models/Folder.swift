import SwiftData
import Foundation

/// A container for organizing API requests in collections.
/// Folders maintain a sorted order for display.
/// When a folder is deleted, all its requests are cascade-deleted.
@Model
final class Folder {
    /// Unique identifier for the folder.
    var id: UUID

    /// The display name of the folder as shown in the UI.
    var name: String

    /// Timestamp when the folder was first created.
    var createdAt: Date

    /// Timestamp when the folder was last modified.
    var updatedAt: Date

    /// Sort order for displaying folders in a consistent sequence.
    var sortOrder: Int

    /// API requests contained within this folder.
    /// Deleting this folder will cascade-delete all contained requests.
    @Relationship(deleteRule: .cascade, inverse: \APIRequest.folder)
    var requests: [APIRequest]?

    /// The collection's environments: its Default one and those that override it.
    /// Deleting this folder deletes them too.
    @Relationship(deleteRule: .cascade, inverse: \CollectionEnvironment.folder)
    var environments: [CollectionEnvironment]?

    /// Where a request added to this collection goes: after the last one, so it never ties with another, even after
    /// deletions. `request` (one that already joined, or is moving in) is left out of the count.
    func nextRequestSortOrder(excluding request: APIRequest? = nil) -> Int {
        let orders = (requests ?? []).filter { $0 !== request }.map(\.sortOrder)
        return (orders.max() ?? -1) + 1
    }

    /// Where a new collection goes: after the last of `folders`, so it never lands above or ties with another, even after
    /// deletions (a count would).
    static func nextSortOrder(after folders: [Folder]) -> Int { (folders.map(\.sortOrder).max() ?? -1) + 1 }

    /// The environment requests resolve `{{variables}}` with, on top of Default. Nil means Default only.
    var selectedEnvironmentID: UUID?

    /// Creates a new folder with the specified name.
    /// - Parameters:
    ///   - name: The display name for the folder
    ///   - sortOrder: Display order (defaults to 0)
    init(name: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sortOrder = sortOrder
        self.requests = []
        self.environments = []
    }
}
