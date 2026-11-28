import Foundation
import SwiftData
import SwiftUI

/// A set of variables for one collection, such as Local, Staging or Production.
///
/// Every collection has a Default environment that always applies. The collection's selected
/// environment (if any) overrides Default for the variables it sets; the rest still come from Default.
@Model
final class CollectionEnvironment {
    var id: UUID
    var name: String

    /// One of `EnvironmentColor`'s raw values.
    var colorName: String

    /// The collection's Default environment: always applied, never deleted.
    var isDefault: Bool

    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var variables: [Variable]

    /// The collection it belongs to.
    var folder: Folder?

    init(name: String, isDefault: Bool = false, color: EnvironmentColor = .blue, sortOrder: Int = 0, variables: [Variable] = []) {
        self.id = UUID()
        self.name = name
        self.colorName = color.rawValue
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
        self.variables = variables
    }

    var color: EnvironmentColor {
        get { EnvironmentColor(rawValue: colorName) ?? .blue }
        set { colorName = newValue.rawValue }
    }

    /// The name a collection's Default environment starts with. It can be renamed.
    static let defaultName = "Default"
}

/// The colors an environment can be marked with.
enum EnvironmentColor: String, CaseIterable, Identifiable, Sendable {
    case green, orange, red, blue, pink, gray

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    @MainActor var swatch: Color {
        switch self {
        case .green: Theme.success
        case .orange: Theme.warning
        case .red: Theme.failure
        case .blue: Theme.info
        case .pink: Theme.pink
        case .gray: Theme.neutral
        }
    }
}

extension Folder {
    /// The Default environment, if it has been made (see `ensureDefaultEnvironment()`).
    var defaultEnvironment: CollectionEnvironment? {
        environments?.first { $0.isDefault }
    }

    /// The environments other than Default, in display order.
    var overrideEnvironments: [CollectionEnvironment] {
        (environments ?? []).filter { !$0.isDefault }.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }

    /// The selected environment; nil means Default only.
    var selectedEnvironment: CollectionEnvironment? {
        get {
            guard let selectedEnvironmentID else { return nil }
            return environments?.first { $0.id == selectedEnvironmentID && !$0.isDefault }
        }
        set { selectedEnvironmentID = newValue?.isDefault == true ? nil : newValue?.id }
    }

    /// The Default environment's name, as the user called it.
    var defaultEnvironmentName: String {
        let name = defaultEnvironment?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? CollectionEnvironment.defaultName : name
    }

    /// The name of what requests in this collection resolve with: the selected environment, else Default.
    var activeEnvironmentName: String {
        selectedEnvironment?.name ?? defaultEnvironmentName
    }

    /// Gives the collection its Default environment when it has none (new collections, older stores).
    /// The folder must be in a model context.
    @discardableResult
    func ensureDefaultEnvironment() -> CollectionEnvironment {
        if let existing = defaultEnvironment { return existing }
        let environment = CollectionEnvironment(name: CollectionEnvironment.defaultName, isDefault: true, color: .blue)
        modelContext?.insert(environment)
        environment.folder = self
        if environments == nil { environments = [] }
        if !(environments ?? []).contains(where: { $0.id == environment.id }) { environments?.append(environment) }
        return environment
    }

    /// Adds an environment that overrides Default, at the end of the list.
    @discardableResult
    func addEnvironment(named name: String, color: EnvironmentColor, variables: [Variable] = []) -> CollectionEnvironment {
        ensureDefaultEnvironment()
        let order = (overrideEnvironments.map(\.sortOrder).max() ?? -1) + 1
        let environment = CollectionEnvironment(name: name, color: color, sortOrder: order, variables: variables)
        modelContext?.insert(environment)
        environment.folder = self
        if !(environments ?? []).contains(where: { $0.id == environment.id }) { environments?.append(environment) }
        return environment
    }

    /// What `{{variables}}` resolve to in this collection's requests: Default, overridden by the selected environment.
    var variableResolver: VariableResolver { resolver(with: selectedEnvironment) }

    /// Default's variables overridden by `environment`'s (nil or Default: Default only).
    func resolver(with environment: CollectionEnvironment?) -> VariableResolver {
        let selected = environment?.isDefault == true ? nil : environment
        return VariableResolver(
            defaults: defaultEnvironment?.variables ?? [], selected: selected?.variables, selectedName: selected?.name,
            defaultName: defaultEnvironmentName)
    }
}

/// The models the app stores. The app, previews and tests all build their container from this list.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [Folder.self, APIRequest.self, RequestHistory.self, CollectionEnvironment.self]

    /// Gives every collection a Default environment; run once at launch for stores made before environments.
    @MainActor
    static func migrate(_ context: ModelContext) {
        guard let folders = try? context.fetch(FetchDescriptor<Folder>()) else { return }
        for folder in folders where folder.defaultEnvironment == nil { folder.ensureDefaultEnvironment() }
        if context.hasChanges { try? context.save() }
    }
}
