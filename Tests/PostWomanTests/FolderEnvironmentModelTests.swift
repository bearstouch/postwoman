import SwiftData
import XCTest

@testable import PostWoman

@MainActor
final class FolderEnvironmentModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
    }

    private func makeFolder(_ name: String = "Users API", sortOrder: Int = 0) -> Folder {
        let folder = Folder(name: name, sortOrder: sortOrder)
        context.insert(folder)
        return folder
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int { try context.fetchCount(FetchDescriptor<T>()) }

    // MARK: Folder and requests

    func testNewFolderStartsEmpty() {
        let folder = makeFolder("Billing", sortOrder: 4)
        XCTAssertEqual(folder.name, "Billing")
        XCTAssertEqual(folder.sortOrder, 4)
        XCTAssertEqual(folder.requests ?? [], [])
        XCTAssertEqual(folder.environments ?? [], [])
        XCTAssertNil(folder.selectedEnvironmentID)
        XCTAssertNil(folder.defaultEnvironment)
        XCTAssertEqual(folder.defaultEnvironmentName, "Default", "Named Default before it is made")
        XCTAssertEqual(folder.activeEnvironmentName, "Default")
        XCTAssertEqual(folder.variableResolver, VariableResolver(defaults: [], selected: nil), "Resolves nothing until it has variables")
    }

    func testRequestsJoinTheirFolderAndCanMove() throws {
        let users = makeFolder("Users")
        let billing = makeFolder("Billing")
        let request = APIRequest(name: "List", url: "https://x", folder: users)
        context.insert(request)
        try context.save()
        XCTAssertEqual(users.requests?.map(\.name), ["List"])

        request.folder = billing
        try context.save()
        XCTAssertEqual(users.requests?.count, 0)
        XCTAssertEqual(billing.requests?.map(\.name), ["List"])
    }

    func testDeletingAFolderDeletesItsRequestsAndEnvironmentsButNotOthers() throws {
        let users = makeFolder("Users")
        users.addEnvironment(named: "Staging", color: .orange)
        context.insert(APIRequest(name: "A", folder: users))
        context.insert(APIRequest(name: "B", folder: users))
        let billing = makeFolder("Billing")
        billing.ensureDefaultEnvironment()
        context.insert(APIRequest(name: "Invoice", folder: billing))
        try context.save()
        XCTAssertEqual(try count(APIRequest.self), 3)
        XCTAssertEqual(try count(CollectionEnvironment.self), 3)

        context.delete(users)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>()).map(\.name), ["Billing"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<APIRequest>()).map(\.name), ["Invoice"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<CollectionEnvironment>()).map(\.name), ["Default"])
        XCTAssertNotNil(billing.defaultEnvironment)
    }

    func testDeletingAFolderKeepsItsHistory() throws {
        let folder = makeFolder()
        let request = APIRequest(name: "Me", url: "https://x/me", folder: folder)
        context.insert(request)
        context.insert(RequestHistory(request: request, environmentName: "Default"))
        try context.save()

        context.delete(folder)
        try context.save()
        let history = try context.fetch(FetchDescriptor<RequestHistory>())
        XCTAssertEqual(history.map(\.url), ["https://x/me"], "History outlives what it was sent from")
        XCTAssertEqual(history.first?.savedRequestID, request.id)
        XCTAssertEqual(history.first?.requestName, "Me")
    }

    func testDeletingARequestKeepsItsFolderAndSiblings() throws {
        let folder = makeFolder()
        let a = APIRequest(name: "A", folder: folder)
        let b = APIRequest(name: "B", folder: folder)
        context.insert(a)
        context.insert(b)
        try context.save()
        context.delete(a)
        try context.save()
        XCTAssertEqual(try count(Folder.self), 1)
        XCTAssertEqual(folder.requests?.map(\.name), ["B"])
    }

    // MARK: Default environment

    func testEnsureDefaultEnvironmentInsertsOneDefaultIntoTheStore() throws {
        let folder = makeFolder()
        let environment = folder.ensureDefaultEnvironment()
        try context.save()
        XCTAssertEqual(environment.name, "Default")
        XCTAssertTrue(environment.isDefault)
        XCTAssertEqual(environment.color, .blue)
        XCTAssertEqual(environment.variables, [])
        XCTAssertIdentical(environment.folder, folder)
        XCTAssertEqual(try count(CollectionEnvironment.self), 1)
        for _ in 0..<3 { folder.ensureDefaultEnvironment() }
        try context.save()
        XCTAssertEqual(try count(CollectionEnvironment.self), 1, "Calling it again never adds a second Default")
        XCTAssertEqual(folder.environments?.count, 1)
    }

    func testEnsureDefaultEnvironmentKeepsAnExistingDefaultsVariables() {
        let folder = makeFolder()
        let first = folder.ensureDefaultEnvironment()
        first.variables = [Variable(key: "a", value: "1")]
        first.name = "Local"
        XCTAssertIdentical(folder.ensureDefaultEnvironment(), first)
        XCTAssertEqual(folder.defaultEnvironment?.variables.map(\.value), ["1"])
        XCTAssertEqual(folder.defaultEnvironment?.name, "Local")
    }

    func testDefaultEnvironmentNameIsTrimmedAndFallsBack() {
        let folder = makeFolder()
        let environment = folder.ensureDefaultEnvironment()
        let cases: [(String, String)] = [("Local", "Local"), ("  Local  ", "Local"), ("", "Default"), (" \n\t", "Default"), ("Prod 🚀", "Prod 🚀")]
        for (name, expected) in cases {
            environment.name = name
            XCTAssertEqual(folder.defaultEnvironmentName, expected, name)
            XCTAssertEqual(folder.variableResolver.defaultName, expected, name)
        }
    }

    // MARK: Override environments

    func testAddEnvironmentMakesDefaultFirstAndAppendsInOrder() throws {
        let folder = makeFolder()
        let staging = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "a", value: "s")])
        XCTAssertNotNil(folder.defaultEnvironment, "Adding an environment makes Default too")
        let production = folder.addEnvironment(named: "Production", color: .red)
        let local = folder.addEnvironment(named: "Local", color: .green)
        try context.save()
        XCTAssertEqual([staging, production, local].map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(folder.overrideEnvironments.map(\.name), ["Staging", "Production", "Local"], "Display order, not alphabetical")
        XCTAssertFalse(staging.isDefault)
        XCTAssertEqual(staging.variables.map(\.value), ["s"])
        XCTAssertEqual(try count(CollectionEnvironment.self), 4)
        XCTAssertNil(folder.selectedEnvironmentID, "Adding doesn't select it")
    }

    func testNewEnvironmentsGoAfterTheHighestSortOrderEvenAfterDeletes() throws {
        let folder = makeFolder()
        let a = folder.addEnvironment(named: "A", color: .green)
        let b = folder.addEnvironment(named: "B", color: .green)
        folder.addEnvironment(named: "C", color: .green)
        context.delete(b)
        try context.save()
        let d = folder.addEnvironment(named: "D", color: .green)
        XCTAssertEqual(d.sortOrder, 3)
        a.sortOrder = 10
        XCTAssertEqual(folder.overrideEnvironments.map(\.name), ["C", "D", "A"])
        XCTAssertEqual(folder.addEnvironment(named: "E", color: .green).sortOrder, 11)
    }

    func testOverrideEnvironmentsWithTheSameSortOrderAreOrderedByCreation() {
        let folder = makeFolder()
        let late = folder.addEnvironment(named: "Late", color: .gray)
        let early = folder.addEnvironment(named: "Early", color: .gray)
        late.sortOrder = 0
        early.sortOrder = 0
        late.createdAt = Date(timeIntervalSince1970: 200)
        early.createdAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(folder.overrideEnvironments.map(\.name), ["Early", "Late"])
    }

    func testEnvironmentColorRoundTripsAndUnknownNamesFallBackToBlue() {
        let environment = CollectionEnvironment(name: "X", color: .pink)
        XCTAssertEqual(environment.colorName, "pink")
        environment.color = .red
        XCTAssertEqual(environment.colorName, "red")
        environment.colorName = "chartreuse"
        XCTAssertEqual(environment.color, .blue)
        XCTAssertEqual(EnvironmentColor.allCases.map(\.title), ["Green", "Orange", "Red", "Blue", "Pink", "Gray"])
        XCTAssertEqual(EnvironmentColor.allCases.map(\.id), EnvironmentColor.allCases.map(\.rawValue))
    }

    // MARK: Selection

    func testSelectingAnEnvironmentOverridesDefaultForItsVariablesOnly() {
        let folder = makeFolder()
        folder.ensureDefaultEnvironment().variables = [Variable(key: "host", value: "local"), Variable(key: "user", value: "ada")]
        let staging = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "host", value: "staging")])
        folder.selectedEnvironment = staging
        XCTAssertEqual(folder.selectedEnvironmentID, staging.id)
        XCTAssertEqual(folder.variableResolver.resolve("{{host}}/{{user}}"), "staging/ada")
        XCTAssertEqual(folder.variableResolver.selectedName, "Staging")
        XCTAssertEqual(folder.activeEnvironmentName, "Staging")
    }

    func testSelectionFallsBackToDefaultWhenTheSelectedEnvironmentIsDeleted() throws {
        let folder = makeFolder()
        folder.ensureDefaultEnvironment().variables = [Variable(key: "host", value: "local")]
        let staging = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "host", value: "staging")])
        folder.selectedEnvironment = staging
        try context.save()

        context.delete(staging)
        try context.save()
        XCTAssertNil(folder.selectedEnvironment, "A stale id selects nothing")
        XCTAssertEqual(folder.activeEnvironmentName, "Default")
        XCTAssertEqual(folder.variableResolver.resolve("{{host}}"), "local")
        XCTAssertNil(folder.variableResolver.selectedName)
        XCTAssertEqual(folder.overrideEnvironments, [])
    }

    func testAnUnknownSelectedIDMeansDefaultOnly() {
        let folder = makeFolder()
        folder.ensureDefaultEnvironment().variables = [Variable(key: "host", value: "local")]
        folder.selectedEnvironmentID = UUID()
        XCTAssertNil(folder.selectedEnvironment)
        XCTAssertEqual(folder.activeEnvironmentName, "Default")
        XCTAssertEqual(folder.variableResolver.resolve("{{host}}"), "local")
    }

    func testSelectingDefaultByIDStillMeansDefaultOnly() {
        let folder = makeFolder()
        let defaultEnvironment = folder.ensureDefaultEnvironment()
        folder.selectedEnvironmentID = defaultEnvironment.id
        XCTAssertNil(folder.selectedEnvironment, "Default is never the selected override")
        XCTAssertNil(folder.variableResolver.selectedName)
    }

    func testClearingTheSelection() {
        let folder = makeFolder()
        folder.selectedEnvironment = folder.addEnvironment(named: "Staging", color: .orange)
        folder.selectedEnvironment = nil
        XCTAssertNil(folder.selectedEnvironmentID)
        XCTAssertEqual(folder.activeEnvironmentName, "Default")
    }

    func testResolverWithAnEnvironmentDoesNotChangeTheSelection() {
        let folder = makeFolder()
        folder.ensureDefaultEnvironment().variables = [Variable(key: "host", value: "local")]
        let production = folder.addEnvironment(named: "Production", color: .red, variables: [Variable(key: "host", value: "prod")])
        XCTAssertEqual(folder.resolver(with: production).resolve("{{host}}"), "prod")
        XCTAssertEqual(folder.resolver(with: production).selectedName, "Production")
        XCTAssertEqual(folder.resolver(with: folder.defaultEnvironment).resolve("{{host}}"), "local", "Default means Default only")
        XCTAssertNil(folder.resolver(with: folder.defaultEnvironment).selectedName)
        XCTAssertEqual(folder.resolver(with: nil).resolve("{{host}}"), "local")
        XCTAssertNil(folder.selectedEnvironmentID)
    }

    func testDisabledVariablesInTheSelectedEnvironmentFallBackToDefault() {
        let folder = makeFolder()
        folder.ensureDefaultEnvironment().variables = [Variable(key: "host", value: "local")]
        folder.selectedEnvironment = folder.addEnvironment(named: "Staging", color: .orange, variables: [Variable(key: "host", value: "staging", isEnabled: false)])
        XCTAssertEqual(folder.variableResolver.resolve("{{host}}"), "local")
        XCTAssertEqual(folder.variableResolver.entry("host")?.source, .default)
    }

    func testEnvironmentsPersistTheirVariablesAndSelection() throws {
        let folder = makeFolder()
        let host = Variable(key: "host", value: "🌍 local")
        let secret = Variable(key: "token", value: "abc", isEnabled: false, isSecret: true)
        folder.ensureDefaultEnvironment().variables = [host, secret]
        let staging = folder.addEnvironment(named: "Staging", color: .orange)
        folder.selectedEnvironment = staging
        try context.save()

        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Folder>()).first)
        XCTAssertEqual(stored.defaultEnvironment?.variables, [host, secret], "Order, ids, values and flags are kept")
        XCTAssertEqual(stored.defaultEnvironment?.variables.last?.isSecret, true)
        XCTAssertEqual(stored.defaultEnvironment?.variables.last?.isEnabled, false)
        XCTAssertEqual(stored.selectedEnvironment?.name, "Staging")
        XCTAssertEqual(stored.selectedEnvironment?.color, .orange)
    }

    // MARK: Migration

    func testMigrationOnAnEmptyStoreDoesNothing() throws {
        AppSchema.migrate(context)
        XCTAssertEqual(try count(Folder.self), 0)
        XCTAssertEqual(try count(CollectionEnvironment.self), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testMigrationOnlyAddsDefaultsWhereMissingAndSaves() throws {
        let old = makeFolder("Old")
        let current = makeFolder("Current")
        let existing = current.ensureDefaultEnvironment()
        existing.name = "Local"
        existing.variables = [Variable(key: "host", value: "kept")]
        current.addEnvironment(named: "Staging", color: .orange)
        try context.save()

        AppSchema.migrate(context)
        XCTAssertFalse(context.hasChanges, "Migration saves what it adds")
        XCTAssertEqual(old.defaultEnvironment?.name, "Default")
        XCTAssertEqual(old.defaultEnvironment?.variables, [])
        XCTAssertIdentical(current.defaultEnvironment, existing)
        XCTAssertEqual(current.defaultEnvironment?.variables.map(\.value), ["kept"])
        XCTAssertEqual(current.overrideEnvironments.map(\.name), ["Staging"])
        XCTAssertEqual(try count(CollectionEnvironment.self), 3)

        let fresh = ModelContext(container)
        let defaults = try fresh.fetch(FetchDescriptor<CollectionEnvironment>()).filter(\.isDefault)
        XCTAssertEqual(defaults.map(\.name).sorted(), ["Default", "Local"], "The new Default was saved")
    }

    func testMigrationIsIdempotentAndCatchesUpLaterFolders() throws {
        _ = makeFolder("A")
        try context.save()
        for _ in 0..<3 { AppSchema.migrate(context) }
        XCTAssertEqual(try count(CollectionEnvironment.self), 1)

        _ = makeFolder("B")
        AppSchema.migrate(context)
        AppSchema.migrate(context)
        XCTAssertEqual(try count(CollectionEnvironment.self), 2)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Folder>()).allSatisfy { $0.defaultEnvironment != nil && $0.environments?.count == 1 })
    }

    func testSchemaListsEveryModel() {
        let names = Set(AppSchema.models.map { String(describing: $0) })
        XCTAssertEqual(names, ["Folder", "APIRequest", "RequestHistory", "CollectionEnvironment"])
    }
}
