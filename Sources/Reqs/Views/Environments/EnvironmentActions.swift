import Foundation
import SwiftData

/// What the environment views do to a collection's environments (add, copy, delete, pick by shortcut), kept out of the
/// views so it can be tested on a store.
@MainActor
enum EnvironmentActions {
    /// `base`, or `base 2`, `base 3`… : the first name no environment of `folder` has (exact, case-sensitive match).
    static func uniqueName(_ base: String, in folder: Folder) -> String {
        let names = Set((folder.environments ?? []).map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// The color of an environment added with +: green, orange or red, whichever no other environment has yet, else gray.
    static func colorForAdded(in folder: Folder) -> EnvironmentColor {
        let unused = Set(EnvironmentColor.allCases.prefix(3)).subtracting(folder.overrideEnvironments.map(\.color))
        return unused.sorted { $0.rawValue < $1.rawValue }.first ?? .gray
    }

    /// The color the New Environment sheet starts with: the first of green, orange, red, pink no other environment has, else gray.
    static func colorForNew(in folder: Folder) -> EnvironmentColor {
        let taken = Set(folder.overrideEnvironments.map(\.color))
        return [EnvironmentColor.green, .orange, .red, .pink, .gray].first { !taken.contains($0) } ?? .gray
    }

    /// Adds an empty environment named "New Environment" (made unique).
    static func add(to folder: Folder) -> CollectionEnvironment {
        folder.addEnvironment(named: uniqueName("New Environment", in: folder), color: colorForAdded(in: folder))
    }

    /// Adds a copy of `environment`'s variables (secrets included) as "<name> Copy"; a copy of Default is a gray "New Environment".
    static func duplicate(_ environment: CollectionEnvironment, in folder: Folder) -> CollectionEnvironment {
        let name = environment.isDefault ? "New Environment" : "\(environment.name) Copy"
        return folder.addEnvironment(
            named: uniqueName(name, in: folder), color: environment.isDefault ? .gray : environment.color, variables: copies(of: environment.variables))
    }

    /// Deletes an override environment; Default is never deleted. Requests go back to Default only if they used it.
    /// - Returns: The environment to edit next (Default if `editingID` was the deleted one), or `editingID` unchanged.
    static func delete(_ environment: CollectionEnvironment, in folder: Folder, context: ModelContext, editingID: UUID?) -> UUID? {
        guard !environment.isDefault else { return editingID }
        var editingID = editingID
        if folder.selectedEnvironmentID == environment.id { folder.selectedEnvironmentID = nil }
        if editingID == environment.id { editingID = folder.defaultEnvironment?.id }
        context.delete(environment)
        return editingID
    }

    /// What the New Environment sheet can copy: Default, then the overrides.
    static func copySources(in folder: Folder) -> [CollectionEnvironment] {
        (folder.defaultEnvironment.map { [$0] } ?? []) + folder.overrideEnvironments
    }

    /// The New Environment sheet's Create: an environment named `name` (trimmed), empty or with a copy of `copyFrom`'s
    /// variables, selected for requests when `selectsNow`. Nil (and nothing changes) when the name is blank.
    static func create(named name: String, color: EnvironmentColor, copyFrom: UUID?, in folder: Folder, selectsNow: Bool) -> CollectionEnvironment? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let variables = copyFrom.flatMap { id in copySources(in: folder).first { $0.id == id } }.map { copies(of: $0.variables) } ?? []
        let environment = folder.addEnvironment(named: name, color: color, variables: variables)
        if selectsNow { folder.selectedEnvironment = environment }
        return environment
    }

    /// The Environment menu's ⌃0…⌃9: 0 is Default only, 1… the overrides in order. An index past the last changes nothing.
    static func select(index: Int, in folder: Folder) {
        let environments = folder.overrideEnvironments
        if index == 0 {
            folder.selectedEnvironmentID = nil
        } else if index <= environments.count {
            folder.selectedEnvironment = environments[index - 1]
        }
    }

    /// The same variables with new identities, so editing a copy never touches the original.
    private static func copies(of variables: [Variable]) -> [Variable] {
        variables.map { Variable(key: $0.key, value: $0.value, isEnabled: $0.isEnabled, isSecret: $0.isSecret) }
    }
}
