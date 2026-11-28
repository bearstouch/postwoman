import SwiftUI
import XCTest

@testable import PostWoman

/// Checks `ViewHosting` itself, so a view test that finds nothing fails for the view, not the helper.
@MainActor
final class ViewHostingTests: XCTestCase {
    func testHostedViewsExposeTheirAccessibilityTree() {
        let view = VStack {
            Text("Hello row")
            Button {
            } label: {
                Image(systemName: "trash")
            }.help("Delete it").accessibilityLabel("Delete")
            Button("Plain") {}
            Text("Picked").accessibilityAddTraits(.isSelected)
        }
        let hosting = ViewHosting.host(view, size: CGSize(width: 300, height: 200))
        defer { ViewHosting.close(hosting) }
        let elements = ViewHosting.elements(in: hosting)
        XCTAssertEqual(ViewHosting.buttonLabels(in: hosting), ["Delete", "Plain"])
        XCTAssertEqual(elements.first { $0.label == "Delete" }?.help, "Delete it")
        XCTAssertTrue(ViewHosting.text(in: hosting).contains("Hello row"))
        XCTAssertEqual(elements.first { $0.label == "Picked" }?.isSelected, true)
        XCTAssertEqual(elements.first { $0.label == "Hello row" }?.isSelected ?? false, false)
    }

    func testHostsViewsThatUseTheStore() throws {
        let container = try ViewHosting.container()
        let request = APIRequest(name: "Get Users", url: "https://x")
        container.mainContext.insert(request)
        let hosting = ViewHosting.host(RequestRowView(request: request), size: CGSize(width: 250, height: 30), appearance: .darkAqua, container: container)
        defer { ViewHosting.close(hosting) }
        XCTAssertEqual(ViewHosting.text(in: hosting), ["GET", "Get Users"])
    }
}
