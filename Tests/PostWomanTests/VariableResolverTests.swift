import SwiftData
import XCTest

@testable import PostWoman

final class VariableResolverTests: XCTestCase {
    private let defaults = [
        Variable(key: "baseUrl", value: "http://localhost:8080"),
        Variable(key: "userId", value: "42"),
        Variable(key: "off", value: "nope", isEnabled: false)
    ]
    private let staging = [
        Variable(key: "baseUrl", value: "https://staging.example.com"),
        Variable(key: "token", value: "s3cret", isSecret: true),
        Variable(key: "users", value: "{{baseUrl}}/users")
    ]

    func testSelectedEnvironmentOverridesDefaultAndInheritsTheRest() {
        let resolver = VariableResolver(defaults: defaults, selected: staging, selectedName: "Staging")
        XCTAssertEqual(resolver.resolve("{{baseUrl}}/users/{{ userId }}"), "https://staging.example.com/users/42")
        XCTAssertEqual(resolver.entry("baseUrl")?.source, .selected)
        XCTAssertEqual(resolver.entry("userId")?.source, .default)
        XCTAssertEqual(resolver.selectedName, "Staging")

        let defaultOnly = VariableResolver(defaults: defaults, selected: nil, selectedName: "Staging")
        XCTAssertEqual(defaultOnly.resolve("{{baseUrl}}"), "http://localhost:8080")
        XCTAssertNil(defaultOnly.selectedName)
    }

    func testMissingAndDisabledVariablesAreLeftAsWritten() {
        let resolver = VariableResolver(defaults: defaults, selected: nil)
        XCTAssertEqual(resolver.resolve("{{off}} {{missing}} {{}} {{ a b"), "{{off}} {{missing}} {{}} {{ a b")
        XCTAssertEqual(resolver.missingVariables(in: "{{missing}}/{{userId}}/{{off}}/{{missing}}"), ["missing", "off"])
        XCTAssertEqual(resolver.tokens(in: "{{userId}}-{{x}}").map(\.source), [.default, .missing])
    }

    func testNestedVariablesResolveAndCyclesStop() {
        let resolver = VariableResolver(defaults: defaults, selected: staging)
        XCTAssertEqual(resolver.resolve("{{users}}"), "https://staging.example.com/users")

        let cycle = VariableResolver(defaults: [Variable(key: "a", value: "{{b}}"), Variable(key: "b", value: "{{a}}")], selected: nil)
        XCTAssertEqual(cycle.resolve("{{a}}"), "{{b}}", "A cycle stops after a few levels instead of looping")
        XCTAssertEqual(cycle.missingVariables(in: "{{a}}"), [])

        let nestedMissing = VariableResolver(defaults: [Variable(key: "url", value: "{{host}}/x")], selected: nil)
        XCTAssertEqual(nestedMissing.missingVariables(in: "{{url}}"), ["host"])
    }

    func testSecretsCanBeRedacted() {
        let resolver = VariableResolver(defaults: [], selected: staging)
        XCTAssertEqual(resolver.resolve("Bearer {{token}}"), "Bearer s3cret")
        XCTAssertEqual(resolver.resolve("Bearer {{ token }}", redactSecrets: true), "Bearer {{token}}")
        XCTAssertTrue(resolver.tokens(in: "{{token}}")[0].isSecret)
    }

    func testReferencesUseTheInnermostBraces() {
        let text = "{{a {{b}} c}}"
        XCTAssertEqual(VariableResolver.references(in: text).map(\.1), ["b"])
        XCTAssertEqual(VariableResolver.references(in: "{{x}}{{y}}").map(\.1), ["x", "y"])
    }

    func testSnapshotResolvesEveryFieldThatIsSent() {
        let request = APIRequest(name: "Get user", url: "{{baseUrl}}/users/{{userId}}")
        request.headers = [KeyValuePair(key: "X-{{userId}}", value: "{{missing}}"), KeyValuePair(key: "Off", value: "{{alsoMissing}}", isEnabled: false)]
        request.queryParams = [KeyValuePair(key: "id", value: "{{userId}}")]
        request.bodyType = .json
        request.bodyContent = #"{"url":"{{users}}"}"#
        request.authenticationType = .bearer
        request.authBearerToken = "{{token}}"

        let resolver = VariableResolver(defaults: defaults, selected: staging)
        let template = RequestSnapshot(request)
        let sent = template.resolved(with: resolver)
        XCTAssertEqual(sent.url, "https://staging.example.com/users/42")
        XCTAssertEqual(sent.headers.first?.key, "X-42")
        XCTAssertEqual(sent.queryParams.first?.value, "42")
        XCTAssertEqual(sent.bodyContent, #"{"url":"https://staging.example.com/users"}"#)
        XCTAssertEqual(sent.authBearerToken, "s3cret")
        XCTAssertEqual(template.resolved(with: resolver, redactSecrets: true).authBearerToken, "{{token}}")
        XCTAssertEqual(template.missingVariables(with: resolver), ["missing"], "Disabled headers are not sent, so they don't count")
    }

    func testCodeGenerationUsesTheResolvedRequest() {
        let request = APIRequest(name: "Me", url: "{{baseUrl}}/me")
        request.authenticationType = .bearer
        request.authBearerToken = "{{token}}"
        let resolver = VariableResolver(defaults: defaults, selected: staging)
        let code = CURLGenerator().generate(from: RequestSnapshot(request).resolved(with: resolver, redactSecrets: true))
        XCTAssertTrue(code.contains("'https://staging.example.com/me'"), code)
        XCTAssertTrue(code.contains("Bearer {{token}}"), "Secrets stay as variables: \(code)")
        XCTAssertTrue(CURLGenerator().generate(from: request).contains("{{baseUrl}}/me"))
    }
}

@MainActor
final class CollectionEnvironmentTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    private func makeFolder(_ name: String = "Users API") -> Folder {
        let folder = Folder(name: name)
        context.insert(folder)
        return folder
    }

    func testDefaultIsMadeOnceAndAlwaysApplies() throws {
        let folder = makeFolder()
        XCTAssertNil(folder.defaultEnvironment)
        let first = folder.ensureDefaultEnvironment()
        XCTAssertIdentical(folder.ensureDefaultEnvironment(), first)
        XCTAssertTrue(first.isDefault)
        first.variables = [Variable(key: "baseUrl", value: "http://localhost")]

        XCTAssertEqual(folder.activeEnvironmentName, "Default")
        XCTAssertEqual(folder.variableResolver.resolve("{{baseUrl}}"), "http://localhost")

        let staging = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "baseUrl", value: "https://staging")])
        folder.selectedEnvironment = staging
        XCTAssertEqual(folder.activeEnvironmentName, "Staging")
        XCTAssertEqual(folder.variableResolver.resolve("{{baseUrl}}"), "https://staging")
        XCTAssertEqual(folder.overrideEnvironments.map(\.name), ["Staging"])

        // Default can be renamed and still always applies.
        first.name = "Local"
        folder.selectedEnvironment = nil
        XCTAssertEqual(folder.activeEnvironmentName, "Local")
        XCTAssertEqual(folder.variableResolver.defaultName, "Local")
        XCTAssertEqual(folder.variableResolver.resolve("{{baseUrl}}"), "http://localhost")
        first.name = "  "
        XCTAssertEqual(folder.defaultEnvironmentName, "Default", "A blank name falls back to Default")
        folder.selectedEnvironment = staging

        // Selecting Default means Default only.
        folder.selectedEnvironment = first
        XCTAssertNil(folder.selectedEnvironmentID)
    }

    func testEnvironmentsBelongToTheirCollection() throws {
        let users = makeFolder("Users API")
        let billing = makeFolder("Billing")
        let staging = users.addEnvironment(named: "Staging", color: .orange)
        users.selectedEnvironment = staging
        billing.addEnvironment(named: "Production", color: .red)
        try context.save()

        XCTAssertEqual(users.overrideEnvironments.map(\.name), ["Staging"])
        XCTAssertEqual(billing.overrideEnvironments.map(\.name), ["Production"])
        XCTAssertNil(billing.selectedEnvironment, "Each collection keeps its own choice")

        // A selection that points at another collection's environment is ignored.
        billing.selectedEnvironmentID = staging.id
        XCTAssertNil(billing.selectedEnvironment)

        context.delete(users)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<CollectionEnvironment>()).map(\.name).sorted(), ["Default", "Production"])
    }

    func testMigrationGivesEveryCollectionADefault() throws {
        _ = makeFolder("Old")
        _ = makeFolder("Older")
        try context.save()
        AppSchema.migrate(context)
        let folders = try context.fetch(FetchDescriptor<Folder>())
        XCTAssertTrue(folders.allSatisfy { $0.defaultEnvironment != nil })
        AppSchema.migrate(context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionEnvironment>()), 2)
    }

    func testHistoryKeepsWhatWasSentWithSecretsRedacted() {
        let folder = makeFolder()
        folder.ensureDefaultEnvironment().variables = [Variable(key: "host", value: "https://api.example.com"), Variable(key: "token", value: "abc", isSecret: true)]
        let request = APIRequest(name: "Me", url: "{{host}}/me", folder: folder)
        request.authenticationType = .bearer
        request.authBearerToken = "{{token}}"
        context.insert(request)

        let template = RequestSnapshot(request)
        let history = RequestHistory(
            request: request, sent: template.resolved(with: folder.variableResolver, redactSecrets: true), environmentName: folder.activeEnvironmentName)
        XCTAssertEqual(history.url, "https://api.example.com/me")
        XCTAssertEqual(history.authBearerToken, "{{token}}")
        XCTAssertEqual(history.environmentName, "Default")
        XCTAssertEqual(history.savedRequestID, request.id)
    }

    func testEnvironmentsAreExportedWithoutSecretValuesAndImported() throws {
        let folder = makeFolder()
        folder.ensureDefaultEnvironment().variables = [Variable(key: "baseUrl", value: "http://localhost"), Variable(key: "token", value: "abc", isSecret: true)]
        let staging = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "baseUrl", value: "https://staging")])
        folder.addEnvironment(named: "Production", color: .red)
        folder.selectedEnvironment = staging
        let request = APIRequest(name: "Me", url: "{{baseUrl}}/me", folder: folder)
        context.insert(request)

        let data = try ExportImportService.exportFolder(folder)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("abc"), "Secret values are not exported")

        let imported = try ExportImportService.importFolder(from: data, context: context, existingFolderCount: 1)
        XCTAssertEqual(imported.defaultEnvironment?.variables.map(\.key), ["baseUrl", "token"])
        XCTAssertEqual(imported.defaultEnvironment?.variables.last?.value, "")
        XCTAssertEqual(imported.defaultEnvironment?.variables.last?.isSecret, true)
        XCTAssertEqual(imported.overrideEnvironments.map(\.name), ["Staging", "Production"])
        XCTAssertEqual(imported.overrideEnvironments.map(\.color), [.orange, .red])
        XCTAssertEqual(imported.selectedEnvironment?.name, "Staging")
        XCTAssertEqual(imported.variableResolver.resolve("{{baseUrl}}"), "https://staging")
    }

    func testFilesFromBeforeEnvironmentsImportWithAnEmptyDefault() throws {
        let old = #"{"version":"1.0","exportDate":"2026-01-01T00:00:00Z","folder":{"name":"Legacy","requests":[]}}"#
        let imported = try ExportImportService.importFolder(from: Data(old.utf8), context: context, existingFolderCount: 0)
        XCTAssertEqual(imported.defaultEnvironment?.variables, [])
        XCTAssertTrue(imported.overrideEnvironments.isEmpty)
        XCTAssertNil(imported.selectedEnvironment)
    }
}
