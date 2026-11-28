import Foundation

/// What a file turned out to be, once read; the Import sheet shows it next to the file.
enum ImportFormat: String, CaseIterable, Sendable {
    case reqsCollection, reqsCollections
    case postmanCollection, postmanEnvironment
    case hoppscotchCollection, hoppscotchEnvironment
    case insomniaCollection, insomniaEnvironment
    case openAPI, swagger

    /// As messages name it: "a Postman environment".
    var title: String {
        switch self {
        case .reqsCollection: "Reqs collection"
        case .reqsCollections: "Reqs collections file"
        case .postmanCollection: "Postman collection"
        case .postmanEnvironment: "Postman environment"
        case .hoppscotchCollection: "Hoppscotch collection"
        case .hoppscotchEnvironment: "Hoppscotch environment"
        case .insomniaCollection: "Insomnia collection"
        case .insomniaEnvironment: "Insomnia environment"
        case .openAPI: "OpenAPI spec"
        case .swagger: "Swagger 2.0 spec"
        }
    }

    /// "a Postman collection", "an OpenAPI spec", "an Insomnia environment".
    var withArticle: String { ("AEIOU".contains(title.prefix(1)) ? "an " : "a ") + title }
}

extension ImportFormat {
    /// The apps whose files Import reads, as the Import sheet lists them.
    static let supportedApps = ["Reqs", "Postman", "Hoppscotch", "Insomnia", "OpenAPI", "Swagger"]
}
