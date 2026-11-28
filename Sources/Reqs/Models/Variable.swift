import Foundation

/// A variable in a collection's environment, used in a request as `{{key}}`.
struct Variable: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()

    /// The name a request uses, as in `{{baseUrl}}`.
    var key: String

    /// The value it resolves to. It may use other variables.
    var value: String

    /// Disabled variables are kept but never resolved.
    var isEnabled: Bool = true

    /// Secret values are masked in the editor and generated code, redacted in History, exported empty,
    /// and write-only for agents.
    var isSecret: Bool = false

    init(key: String = "", value: String = "", isEnabled: Bool = true, isSecret: Bool = false) {
        self.id = UUID()
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.isSecret = isSecret
    }
}
