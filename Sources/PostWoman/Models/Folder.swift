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
    }
}
