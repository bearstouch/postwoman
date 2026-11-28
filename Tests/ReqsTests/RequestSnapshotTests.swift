import Foundation
import SwiftData
import XCTest

@testable import Reqs

private let defaults = [
    Variable(key: "host", value: "http://localhost:8080"), Variable(key: "user", value: "42"), Variable(key: "name", value: "ada"),
    Variable(key: "password", value: "default-pw", isSecret: true), Variable(key: "only", value: "from-default")
]
private let staging = [
    Variable(key: "host", value: "https://staging.example.com"), Variable(key: "token", value: "s3cret", isSecret: true),
    Variable(key: "password", value: "staging-pw", isSecret: true), Variable(key: "only", value: "disabled", isEnabled: false)
]
private let resolver = VariableResolver(defaults: defaults, selected: staging, selectedName: "Staging")

/// A request that uses variables in every field that can hold them.
private func templated() -> APIRequest {
    let request = APIRequest(name: "t", url: "{{host}}/users/{{user}}", method: .put)
    request.headers = [KeyValuePair(key: "X-{{name}}", value: "{{user}}-{{missing}}"), KeyValuePair(key: "X-Off", value: "{{off}}", isEnabled: false)]
    request.queryParams = [KeyValuePair(key: "{{name}}", value: "{{ user }}")]
    request.bodyType = .json
    request.bodyContent = #"{"who":"{{name}}","token":"{{token}}"}"#
    request.authenticationType = .bearer
    request.authBearerToken = "{{token}}"
    request.authBasicUsername = "{{name}}"
    request.authBasicPassword = "{{password}}"
    return request
}

final class RequestSnapshotTests: XCTestCase {
    func testSnapshotCopiesEveryField() {
        let request = templated()
        let snapshot = RequestSnapshot(request)
        XCTAssertEqual(snapshot.url, request.url)
        XCTAssertEqual(snapshot.method, .put)
        XCTAssertEqual(snapshot.headers, request.headers)
        XCTAssertEqual(snapshot.queryParams, request.queryParams)
        XCTAssertEqual(snapshot.bodyType, .json)
        XCTAssertEqual(snapshot.bodyContent, request.bodyContent)
        XCTAssertEqual(snapshot.authenticationType, .bearer)
        XCTAssertEqual(snapshot.authBearerToken, "{{token}}")
        XCTAssertEqual(snapshot.authBasicUsername, "{{name}}")
        XCTAssertEqual(snapshot.authBasicPassword, "{{password}}")
        XCTAssertEqual(RequestSnapshot(snapshot), snapshot, "A snapshot of a snapshot is the same")
    }

    func testSnapshotIsIndependentOfLaterEdits() {
        let request = templated()
        let snapshot = RequestSnapshot(request)
        request.url = "https://changed"
        request.headers.append(KeyValuePair(key: "New", value: "1"))
        request.authBearerToken = nil
        XCTAssertEqual(snapshot.url, "{{host}}/users/{{user}}")
        XCTAssertEqual(snapshot.headers.count, 2)
        XCTAssertEqual(snapshot.authBearerToken, "{{token}}")
    }

    func testResolvesURLParamsHeadersBodyAndCredentials() {
        let sent = RequestSnapshot(templated()).resolved(with: resolver)
        XCTAssertEqual(sent.url, "https://staging.example.com/users/42", "The selected environment overrides Default; the rest comes from Default")
        XCTAssertEqual(sent.headers.map(\.key), ["X-ada", "X-Off"])
        XCTAssertEqual(sent.headers.map(\.value), ["42-{{missing}}", "{{off}}"], "Unknown names are sent as written")
        XCTAssertEqual(sent.queryParams.map(\.key), ["ada"])
        XCTAssertEqual(sent.queryParams.map(\.value), ["42"], "Spaces inside the braces are allowed")
        XCTAssertEqual(sent.bodyContent, #"{"who":"ada","token":"s3cret"}"#)
        XCTAssertEqual(sent.authBearerToken, "s3cret")
        XCTAssertEqual(sent.authBasicUsername, "ada")
        XCTAssertEqual(sent.authBasicPassword, "staging-pw")
    }

    func testResolvingKeepsStructureAndTheTemplate() {
        let template = RequestSnapshot(templated())
        let sent = template.resolved(with: resolver)
        XCTAssertEqual(sent.method, template.method)
        XCTAssertEqual(sent.bodyType, template.bodyType)
        XCTAssertEqual(sent.authenticationType, template.authenticationType)
        XCTAssertEqual(sent.headers.map(\.id), template.headers.map(\.id), "Rows keep their identity")
        XCTAssertEqual(sent.headers.map(\.isEnabled), [true, false])
        XCTAssertEqual(template.url, "{{host}}/users/{{user}}", "The template itself is not changed")
        XCTAssertEqual(template.authBearerToken, "{{token}}")
    }

    func testNilCredentialsStayNil() {
        let request = APIRequest(name: "n", url: "{{host}}")
        let sent = RequestSnapshot(request).resolved(with: resolver)
        XCTAssertNil(sent.authBearerToken)
        XCTAssertNil(sent.authBasicUsername)
        XCTAssertNil(sent.authBasicPassword)
    }

    func testRedactingKeepsOnlySecretsAsVariables() {
        let sent = RequestSnapshot(templated()).resolved(with: resolver, redactSecrets: true)
        XCTAssertEqual(sent.url, "https://staging.example.com/users/42")
        XCTAssertEqual(sent.bodyContent, #"{"who":"ada","token":"{{token}}"}"#)
        XCTAssertEqual(sent.authBearerToken, "{{token}}")
        XCTAssertEqual(sent.authBasicUsername, "ada")
        XCTAssertEqual(sent.authBasicPassword, "{{password}}")
        let spaced = APIRequest(name: "s", url: "https://h")
        spaced.authenticationType = .bearer
        spaced.authBearerToken = "{{  token  }}"
        XCTAssertEqual(RequestSnapshot(spaced).resolved(with: resolver, redactSecrets: true).authBearerToken, "{{token}}", "Redacted names are written tidily")
    }

    func testDisabledSelectedVariableFallsBackToDefault() {
        let request = APIRequest(name: "d", url: "https://h/{{only}}")
        XCTAssertEqual(RequestSnapshot(request).resolved(with: resolver).url, "https://h/from-default")
    }

    func testEmptyResolverLeavesEverythingAsWritten() {
        let template = RequestSnapshot(templated())
        XCTAssertEqual(template.resolved(with: .empty), template)
        XCTAssertEqual(template.resolved(with: .empty, redactSecrets: true), template)
    }

    func testTextWithoutVariablesIsUntouched() {
        let request = APIRequest(name: "p", url: "https://h/{a}/{{}}/}}{{")
        request.bodyType = .text
        request.bodyContent = "{ \"braces\": {} } {{ not closed"
        let sent = RequestSnapshot(request).resolved(with: resolver)
        XCTAssertEqual(sent.url, "https://h/{a}/{{}}/}}{{")
        XCTAssertEqual(sent.bodyContent, "{ \"braces\": {} } {{ not closed")
    }

    func testSentTextHoldsOnlyWhatIsSent() {
        let request = APIRequest(name: "s", url: "u", method: .post)
        request.headers = [KeyValuePair(key: "hk", value: "hv"), KeyValuePair(key: "off", value: "offv", isEnabled: false)]
        request.queryParams = [KeyValuePair(key: "qk", value: "qv")]
        request.bodyContent = "body"
        request.authBearerToken = "tok"
        request.authBasicUsername = "user"
        request.authBasicPassword = "pass"
        let cases: [(ContentType, AuthenticationType, [String])] = [
            (.none, .none, ["u", "hk", "hv", "qk", "qv"]), (.json, .none, ["u", "hk", "hv", "qk", "qv", "body"]),
            (.none, .bearer, ["u", "hk", "hv", "qk", "qv", "tok"]), (.none, .basic, ["u", "hk", "hv", "qk", "qv", "user", "pass"]),
            (.text, .oauth2, ["u", "hk", "hv", "qk", "qv", "body"])
        ]
        for (body, auth, expected) in cases {
            request.bodyType = body
            request.authenticationType = auth
            XCTAssertEqual(RequestSnapshot(request).sentText, expected, "\(body.rawValue) / \(auth.rawValue)")
        }
    }

    func testAHeadRequestsBodyIsNotSentTextAndDoesNotAskForAStream() {
        let request = APIRequest(name: "h", url: "u", method: .head)
        request.bodyType = .json
        request.bodyContent = #"{"stream":true,"x":"{{bodyOnly}}"}"#
        XCTAssertEqual(RequestSnapshot(request).sentText, ["u"])
        XCTAssertEqual(RequestSnapshot(request).missingVariables(with: .empty), [], "Variables in a body that isn't sent are not reported")
        XCTAssertFalse(request.expectsStream)
        request.method = .patch
        XCTAssertTrue(request.expectsStream)
    }

    func testMissingVariablesAreOrderedDedupedAndOnlyFromSentText() {
        let request = APIRequest(name: "m", url: "https://h/{{b}}/{{a}}/{{b}}")
        request.headers = [KeyValuePair(key: "X", value: "{{c}}"), KeyValuePair(key: "Off", value: "{{offOnly}}", isEnabled: false)]
        request.bodyType = .none
        request.bodyContent = "{{bodyOnly}}"
        request.authenticationType = .bearer
        request.authBearerToken = "{{token}}"
        request.authBasicPassword = "{{basicOnly}}"
        let snapshot = RequestSnapshot(request)
        XCTAssertEqual(snapshot.missingVariables(with: resolver), ["b", "a", "c"])
        XCTAssertEqual(snapshot.missingVariables(with: .empty), ["b", "a", "c", "token"])
        let nested = VariableResolver(defaults: [Variable(key: "url", value: "{{scheme}}://{{host2}}")], selected: nil)
        XCTAssertEqual(
            RequestSnapshot(APIRequest(name: "n", url: "{{url}}/x")).missingVariables(with: nested), ["host2", "scheme"], "Names missing inside a variable's value come after, sorted")
    }

    func testGeneratorsTakeASnapshotLikeTheRequest() {
        let request = templated()
        let snapshot = RequestSnapshot(request)
        XCTAssertEqual(CURLGenerator().generate(from: snapshot), CURLGenerator().generate(from: request))
        XCTAssertEqual(SwiftGenerator().generate(from: snapshot), SwiftGenerator().generate(from: request))
        XCTAssertEqual(PythonGenerator().generate(from: snapshot), PythonGenerator().generate(from: request))
    }
}

@MainActor
final class CollectionResolutionTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws { container = nil }

    private func collection() -> (Folder, CollectionEnvironment) {
        let folder = Folder(name: "API")
        container.mainContext.insert(folder)
        folder.ensureDefaultEnvironment().variables = defaults
        let staging = folder.addEnvironment(named: "Staging", color: .orange, variables: staging)
        return (folder, staging)
    }

    func testFolderResolvesWithDefaultUntilAnEnvironmentIsSelected() {
        let (folder, staging) = collection()
        let template = RequestSnapshot(templated())
        XCTAssertEqual(template.resolved(with: folder.variableResolver).url, "http://localhost:8080/users/42")
        XCTAssertEqual(template.resolved(with: folder.variableResolver).authBearerToken, "{{token}}", "Default has no token, so it is sent as written")
        folder.selectedEnvironment = staging
        XCTAssertEqual(template.resolved(with: folder.variableResolver).url, "https://staging.example.com/users/42")
        XCTAssertEqual(template.resolved(with: folder.variableResolver).authBearerToken, "s3cret")
        XCTAssertEqual(folder.variableResolver.selectedName, "Staging")
    }

    func testSelectingDefaultMeansDefaultOnly() {
        let (folder, staging) = collection()
        folder.selectedEnvironment = staging
        folder.selectedEnvironment = folder.defaultEnvironment
        XCTAssertNil(folder.selectedEnvironmentID)
        XCTAssertEqual(RequestSnapshot(templated()).resolved(with: folder.variableResolver).url, "http://localhost:8080/users/42")
    }

    func testAnExplicitEnvironmentResolvesWithoutChangingTheSelection() {
        let (folder, staging) = collection()
        XCTAssertEqual(RequestSnapshot(templated()).resolved(with: folder.resolver(with: staging)).url, "https://staging.example.com/users/42")
        XCTAssertNil(folder.selectedEnvironmentID)
    }

    func testEditingAVariableChangesTheNextResolution() {
        let (folder, staging) = collection()
        folder.selectedEnvironment = staging
        staging.variables[0].value = "https://other.example.com"
        XCTAssertEqual(RequestSnapshot(templated()).resolved(with: folder.variableResolver).url, "https://other.example.com/users/42")
        staging.variables[0].isEnabled = false
        XCTAssertEqual(RequestSnapshot(templated()).resolved(with: folder.variableResolver).url, "http://localhost:8080/users/42", "Disabled: Default applies again")
    }
}
