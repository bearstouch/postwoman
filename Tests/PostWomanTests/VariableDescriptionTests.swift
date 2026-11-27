import SwiftUI
import XCTest

@testable import PostWoman

@MainActor
final class VariableDescriptionTests: XCTestCase {
    private let resolver = VariableResolver(
        defaults: [Variable(key: "host", value: "https://local"), Variable(key: "path", value: "/v1"), Variable(key: "users", value: "{{host}}{{path}}/users")],
        selected: [Variable(key: "host", value: "https://staging"), Variable(key: "token", value: "s3cret", isSecret: true)], selectedName: "Staging",
        defaultName: "Local")

    private func help(_ text: String, _ resolver: VariableResolver? = nil) -> String {
        let resolver = resolver ?? self.resolver
        return VariableDescription.help(for: resolver.tokens(in: text), resolver: resolver)
    }

    func testHelpSaysWhereEachValueComesFrom() {
        XCTAssertEqual(help("{{host}}"), "host = https://staging  (Staging)")
        XCTAssertEqual(help("{{path}}"), "path = /v1  (Local)", "Default's name as the user called it")
        XCTAssertEqual(help("{{users}}"), "users = https://staging/v1/users  (Local)", "Nested values are shown resolved")
        XCTAssertEqual(help("{{nope}}"), "nope is not defined, so it is sent as written.")
        XCTAssertEqual(help("{{token}}"), "token = \(VariableDescription.mask)  (Staging)", "Secrets are masked")
        XCTAssertFalse(help("{{token}}").contains("s3cret"))
    }

    func testHelpListsEachVariableOnceInOrder() {
        XCTAssertEqual(help("{{path}} {{host}} {{ path }} {{nope}} {{host}}").components(separatedBy: "\n").map { $0.components(separatedBy: " ").first ?? "" }, ["path", "host", "nope"])
        XCTAssertEqual(help("no variables"), "")
    }

    func testHelpWithoutASelectedNameSaysSelectedEnvironment() {
        let unnamed = VariableResolver(defaults: [], selected: [Variable(key: "a", value: "1")])
        XCTAssertEqual(help("{{a}}", unnamed), "a = 1  (selected environment)")
    }

    func testResolvedTextShowsWhatIsSentWithSecretsMasked() {
        let text = "{{host}}/x/{{token}}/{{nope}}/{{ path }}?"
        let resolved = VariableDescription.resolvedText(text, resolver: resolver)
        XCTAssertEqual(String(resolved.characters), "https://staging/x/\(VariableDescription.mask)/{{nope}}//v1?")
        XCTAssertFalse(String(resolved.characters).contains("s3cret"))
        XCTAssertEqual(String(VariableDescription.resolvedText("plain", resolver: resolver).characters), "plain")
        XCTAssertEqual(String(VariableDescription.resolvedText("", resolver: resolver).characters), "")
    }

    /// A color's sRGB components as drawn now; theme colors are dynamic, so two instances only compare by what they draw.
    private func rgba(_ color: Color?) -> [Double]? {
        guard let color, let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent].map { (Double($0) * 1000).rounded() }
    }

    func testResolvedTextColorsEachPieceByItsSource() {
        let resolved = VariableDescription.resolvedText("a{{host}}b{{path}}{{nope}}", resolver: resolver)
        let runs = resolved.runs.map { (String(resolved[$0.range].characters), $0.foregroundColor) }
        XCTAssertEqual(runs.map(\.0), ["a", "https://staging", "b", "/v1", "{{nope}}"])
        let expected: [Color] = [.secondary, VariableDescription.color(.selected), .secondary, VariableDescription.color(.default), VariableDescription.color(.missing)]
        XCTAssertEqual(runs.map { rgba($0.1) }, expected.map { rgba($0) })
    }

    func testEachSourceHasItsOwnColor() {
        let colors = [VariableResolver.Source.selected, .default, .missing].map { rgba(VariableDescription.color($0)) }
        XCTAssertFalse(colors.contains { $0 == nil })
        XCTAssertEqual(Set(colors.compactMap { $0 }).count, 3, "Selected, Default and missing are told apart (and named in the help text too)")
    }
}
