import XCTest

@testable import PostWoman

final class VariableResolverEdgeCaseTests: XCTestCase {
    private func resolver(_ defaults: [String: String], selected: [String: String]? = nil, secrets: Set<String> = []) -> VariableResolver {
        func variables(_ values: [String: String]) -> [Variable] {
            values.sorted { $0.key < $1.key }.map { Variable(key: $0.key, value: $0.value, isSecret: secrets.contains($0.key)) }
        }
        return VariableResolver(defaults: variables(defaults), selected: selected.map(variables), selectedName: selected == nil ? nil : "Staging")
    }

    func testReferenceSyntaxBoundaries() {
        let names = { (text: String) in VariableResolver.references(in: text).map(\.1) }
        XCTAssertEqual(names("{{a}}"), ["a"])
        XCTAssertEqual(names("{{ a }}"), ["a"], "Spaces inside the braces are trimmed")
        XCTAssertEqual(names("{{\ta\t}}"), ["a"], "Tabs too")
        XCTAssertEqual(names("{{ my var }}"), ["my var"], "Inner spaces are part of the name")
        XCTAssertEqual(names("{{}}"), [])
        XCTAssertEqual(names("{{   }}"), [], "A blank name is not a reference")
        XCTAssertEqual(names("{{a\n}}"), [], "A name can't span lines")
        XCTAssertEqual(names("{{\na}}"), [])
        XCTAssertEqual(names("{{a}b}}"), [], "A name can't contain a closing brace")
        XCTAssertEqual(names("{{a"), [], "Unterminated")
        XCTAssertEqual(names("a}}"), [])
        XCTAssertEqual(names("}}{{a}}"), ["a"])
        XCTAssertEqual(names("{{a}}}"), ["a"])
        XCTAssertEqual(names("{a}"), [], "Single braces are text")
        XCTAssertEqual(names("{{a}}{{b}}{{a}}"), ["a", "b", "a"], "Every occurrence, in order")
        XCTAssertEqual(names("{{a {{b}} {{c}}"), ["b", "c"])
        XCTAssertEqual(names(""), [])
    }

    func testReferenceRangesCoverTheWholeBracesAsWritten() {
        let text = "x{{ host }}/y/{{id}}z"
        let found = VariableResolver.references(in: text)
        XCTAssertEqual(found.map { String(text[$0.0]) }, ["{{ host }}", "{{id}}"])
        let tokens = resolver(["host": "h"]).tokens(in: text)
        XCTAssertEqual(tokens.map { String(text[$0.range]) }, ["{{ host }}", "{{id}}"])
        XCTAssertEqual(tokens.map(\.source), [.default, .missing])
        XCTAssertEqual(tokens.map(\.isSecret), [false, false], "A missing variable is never secret")
    }

    func testUnterminatedAndStrayBracesAreKeptAsWritten() {
        let vars = resolver(["a": "1", "b": "2"])
        let cases: [(String, String)] = [
            ("{{a", "{{a"),
            ("{{a}} {{b", "1 {{b"),
            ("{{a}}}", "1}"),
            ("}}{{a}}{{", "}}1{{"),
            ("{a}", "{a}"),
            ("{{a}b}}", "{{a}b}}"),
            ("{{ a b", "{{ a b"),
            ("{{a {{b}}", "{{a 2"),
            ("", "")
        ]
        for (text, expected) in cases { XCTAssertEqual(vars.resolve(text), expected, text) }
    }

    func testUnknownNamesAreLeftExactlyAsWritten() {
        let vars = resolver(["baseUrl": "http://x"])
        XCTAssertEqual(vars.resolve("{{ unknown }}/{{baseUrl}}"), "{{ unknown }}/http://x", "Including the spaces the user typed")
        XCTAssertEqual(vars.resolve("{{BaseUrl}}"), "{{BaseUrl}}", "Names are case sensitive")
        XCTAssertEqual(vars.missingVariables(in: "{{BaseUrl}} {{ unknown }} {{BaseUrl}}"), ["BaseUrl", "unknown"], "Each missing name once")
        XCTAssertEqual(VariableResolver.empty.resolve("{{a}} {{b}}"), "{{a}} {{b}}")
        XCTAssertEqual(VariableResolver.empty.missingVariables(in: "{{a}} {{b}}"), ["a", "b"])
        XCTAssertNil(VariableResolver.empty.entry("a"))
    }

    func testVariableKeysAreTrimmedAndBlankKeysIgnored() {
        let vars = VariableResolver(
            defaults: [Variable(key: "  host ", value: "h"), Variable(key: "", value: "empty"), Variable(key: "   ", value: "blank")], selected: nil)
        XCTAssertEqual(vars.resolve("{{host}}"), "h")
        XCTAssertEqual(vars.entries.keys.sorted(), ["host"])
    }

    func testLaterDuplicateKeysWinUnlessDisabled() {
        let vars = VariableResolver(
            defaults: [Variable(key: "a", value: "first"), Variable(key: "a", value: "second"), Variable(key: "a", value: "off", isEnabled: false)], selected: nil)
        XCTAssertEqual(vars.resolve("{{a}}"), "second")
    }

    func testOverridePrecedence() {
        let defaults = [Variable(key: "host", value: "local"), Variable(key: "port", value: "80"), Variable(key: "path", value: "/v1")]
        let selected = [
            Variable(key: "host", value: "staging"), Variable(key: "port", value: "8443", isEnabled: false), Variable(key: "path", value: ""),
            Variable(key: "extra", value: "only-staging")
        ]
        let vars = VariableResolver(defaults: defaults, selected: selected, selectedName: "Staging")
        XCTAssertEqual(vars.resolve("{{host}}:{{port}}{{path}}|{{extra}}"), "staging:80|only-staging")
        XCTAssertEqual(vars.entry("host")?.source, .selected)
        XCTAssertEqual(vars.entry("port")?.source, .default, "A disabled override falls back to Default")
        XCTAssertEqual(vars.entry("path")?.value, "", "An empty override still overrides")
        XCTAssertEqual(vars.entry("extra")?.source, .selected)

        let emptySelection = VariableResolver(defaults: defaults, selected: [], selectedName: "Empty")
        XCTAssertEqual(emptySelection.resolve("{{host}}"), "local")
        XCTAssertEqual(emptySelection.selectedName, "Empty", "An empty environment is still the selected one")
    }

    func testDisabledVariablesNeverResolveAnywhere() {
        let vars = VariableResolver(defaults: [Variable(key: "a", value: "1", isEnabled: false)], selected: [Variable(key: "b", value: "2", isEnabled: false)])
        XCTAssertEqual(vars.resolve("{{a}}{{b}}"), "{{a}}{{b}}")
        XCTAssertNil(vars.entry("a"))
        XCTAssertEqual(vars.missingVariables(in: "{{a}}{{b}}"), ["a", "b"])
        XCTAssertEqual(vars.tokens(in: "{{a}}").map(\.source), [.missing])
    }

    func testEmptyValuesResolveToNothing() {
        let vars = resolver(["empty": ""])
        XCTAssertEqual(vars.resolve("a{{empty}}b"), "ab")
        XCTAssertEqual(vars.missingVariables(in: "{{empty}}"), [], "Empty is defined, not missing")
    }

    func testNestedReferencesResolveUpToTheMaximumDepth() {
        XCTAssertEqual(VariableResolver.maximumDepth, 5)
        let five = resolver(["a": "{{b}}", "b": "{{c}}", "c": "{{d}}", "d": "{{e}}", "e": "end"])
        XCTAssertEqual(five.resolve("{{a}}"), "end", "Five variables deep resolve fully")
        let six = resolver(["a": "{{b}}", "b": "{{c}}", "c": "{{d}}", "d": "{{e}}", "e": "{{f}}", "f": "end"])
        XCTAssertEqual(six.resolve("{{a}}"), "{{f}}", "The sixth level is left as written")
        XCTAssertEqual(six.resolve("{{c}}"), "end", "Depth counts from where the text starts")
    }

    func testSelfReferencesAndCyclesTerminate() {
        let selfRef = resolver(["a": "x{{a}}"])
        XCTAssertEqual(selfRef.resolve("{{a}}"), "xxxxx{{a}}")
        XCTAssertEqual(selfRef.missingVariables(in: "{{a}}"), [])
        let triangle = resolver(["a": "{{b}}", "b": "{{c}}", "c": "{{a}}"])
        XCTAssertEqual(triangle.resolve("{{a}}"), "{{c}}")
        XCTAssertEqual(triangle.missingVariables(in: "{{a}}"), [])
    }

    func testNestedValuesMixLiteralTextAndSeveralReferences() {
        let vars = resolver(["base": "{{scheme}}://{{host}}:{{port}}", "scheme": "https", "host": "api.example.com", "port": "443", "users": "{{base}}/users"])
        XCTAssertEqual(vars.resolve("{{users}}?id=1"), "https://api.example.com:443/users?id=1")
    }

    func testMissingVariablesListTopLevelNamesFirstThenNestedOnesSorted() {
        let vars = resolver(["url": "{{host}}{{alpha}}"])
        XCTAssertEqual(vars.missingVariables(in: "{{url}} {{zeta}}"), ["zeta", "alpha", "host"])
        XCTAssertEqual(vars.missingVariables(in: "no variables"), [])
    }

    func testResolvedValuesAreNotReparsedWithTheSurroundingText() {
        let vars = resolver(["open": "{{", "b": "SHOULD-NOT-APPEAR"])
        XCTAssertEqual(vars.resolve("{{open}}b}}"), "{{b}}", "A value can't build a new reference with the text after it")
    }

    func testValuesAreInsertedLiterally() {
        let vars = resolver(["re": #"$1 \n \\ & %@ .*"#])
        XCTAssertEqual(vars.resolve("[{{re}}]"), #"[$1 \n \\ & %@ .*]"#)
    }

    func testUnicodeNamesAndValues() {
        let vars = resolver(["ключ": "значение", "emoji": "🚀👩‍💻", "café": "crème"])
        XCTAssertEqual(vars.resolve("{{ключ}}/{{emoji}}/{{café}}"), "значение/🚀👩‍💻/crème")
        XCTAssertEqual(vars.resolve("👋{{emoji}}👋"), "👋🚀👩‍💻👋", "Grapheme clusters around references stay intact")
        XCTAssertEqual(vars.resolve("{{cafe\u{301}}}"), "crème", "Names match by canonical equivalence, like Swift strings")
        let text = "é{{ключ}}"
        XCTAssertEqual(vars.tokens(in: text).map { String(text[$0.range]) }, ["{{ключ}}"])
    }

    func testSecretsAreRedactedWhereverTheyAppear() {
        let vars = resolver(["token": "s3cret", "auth": "Bearer {{token}}", "host": "h"], secrets: ["token"])
        XCTAssertEqual(vars.resolve("{{auth}}", redactSecrets: true), "Bearer {{token}}", "A secret nested in a plain variable stays a variable")
        XCTAssertEqual(vars.resolve("{{auth}}"), "Bearer s3cret")
        XCTAssertEqual(vars.resolve("{{ token }}|{{token}}|{{host}}", redactSecrets: true), "{{token}}|{{token}}|h")
        XCTAssertFalse(vars.resolve("{{token}}{{auth}}", redactSecrets: true).contains("s3cret"))
    }

    func testASecretValueIsNeverResolvedFurtherWhenRedacted() {
        let vars = resolver(["key": "{{inner}}", "inner": "plain"], secrets: ["key"])
        XCTAssertEqual(vars.resolve("{{key}}", redactSecrets: true), "{{key}}")
        XCTAssertEqual(vars.resolve("{{key}}"), "plain")
    }

    func testASecretOverrideIsRedactedEvenWhenDefaultsValueIsNot() {
        let vars = VariableResolver(
            defaults: [Variable(key: "token", value: "dev-token")], selected: [Variable(key: "token", value: "prod-token", isSecret: true)])
        XCTAssertEqual(vars.resolve("{{token}}", redactSecrets: true), "{{token}}")
        XCTAssertTrue(vars.tokens(in: "{{token}}")[0].isSecret)
        XCTAssertEqual(vars.tokens(in: "{{token}}")[0].source, .selected)
    }

    func testResolversAreEqualWhenTheyResolveTheSame() {
        let a = VariableResolver(defaults: [Variable(key: "a", value: "1")], selected: nil)
        let b = VariableResolver(defaults: [Variable(key: "a", value: "1")], selected: nil)
        let c = VariableResolver(defaults: [Variable(key: "a", value: "2")], selected: nil)
        XCTAssertEqual(a, b, "Variable ids don't matter, only what resolves")
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.defaultName, "Default")
    }
}

final class RequestSnapshotVariableTests: XCTestCase {
    private let resolver = VariableResolver(
        defaults: [Variable(key: "host", value: "https://api.example.com"), Variable(key: "user", value: "ada"), Variable(key: "pass", value: "pw", isSecret: true)],
        selected: nil)

    private func request() -> APIRequest {
        let request = APIRequest(name: "R", url: "{{host}}/x", method: .post)
        request.headers = [KeyValuePair(key: "X-User", value: "{{user}}"), KeyValuePair(key: "X-Off-{{user}}", value: "{{offMissing}}", isEnabled: false)]
        request.queryParams = [KeyValuePair(key: "{{user}}", value: "{{queryMissing}}")]
        request.bodyType = .none
        request.bodyContent = "{{bodyMissing}}"
        request.authenticationType = .basic
        request.authBasicUsername = "{{user}}"
        request.authBasicPassword = "{{pass}}"
        request.authBearerToken = "{{bearerMissing}}"
        return request
    }

    func testDisabledPairsAreResolvedButKeepTheirState() {
        let sent = RequestSnapshot(request()).resolved(with: resolver)
        XCTAssertEqual(sent.headers.map(\.key), ["X-User", "X-Off-ada"])
        XCTAssertEqual(sent.headers.map(\.isEnabled), [true, false])
        XCTAssertEqual(sent.queryParams.first?.key, "ada")
    }

    func testEveryCredentialIsResolvedAndSecretsRedacted() {
        let template = RequestSnapshot(request())
        XCTAssertEqual(template.resolved(with: resolver).authBasicPassword, "pw")
        let recorded = template.resolved(with: resolver, redactSecrets: true)
        XCTAssertEqual(recorded.authBasicUsername, "ada")
        XCTAssertEqual(recorded.authBasicPassword, "{{pass}}")
        XCTAssertEqual(recorded.url, "https://api.example.com/x")
    }

    func testNilCredentialsStayNil() {
        let plain = APIRequest(name: "R", url: "{{host}}")
        let sent = RequestSnapshot(plain).resolved(with: resolver)
        XCTAssertNil(sent.authBearerToken)
        XCTAssertNil(sent.authBasicUsername)
        XCTAssertNil(sent.authBasicPassword)
    }

    func testOnlySentTextCountsAsMissing() {
        let template = RequestSnapshot(request())
        XCTAssertEqual(template.missingVariables(with: resolver), ["queryMissing"], "No body, a disabled header and the unused bearer token are not sent")

        var withBody = template
        withBody.bodyType = .text
        withBody.authenticationType = .bearer
        XCTAssertEqual(withBody.missingVariables(with: resolver), ["queryMissing", "bodyMissing", "bearerMissing"])

        var oauth = template
        oauth.authenticationType = .oauth2
        XCTAssertEqual(oauth.sentText, ["{{host}}/x", "X-User", "{{user}}", "{{user}}", "{{queryMissing}}"])
    }

    func testSnapshotIsACopyThatResolvingDoesNotChange() {
        let model = request()
        let template = RequestSnapshot(model)
        _ = template.resolved(with: resolver)
        XCTAssertEqual(template, RequestSnapshot(model))
        XCTAssertEqual(model.url, "{{host}}/x", "The saved request keeps its variables")
    }
}
