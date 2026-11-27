import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import PostWoman

/// Puts SwiftUI views on screen for tests: in a borderless window, laid out at a size and appearance, so their
/// AppKit-backed accessibility tree is real. Use it to check a view renders with given data and what VoiceOver gets.
@MainActor
enum ViewHosting {
    /// An in-memory store with the app's schema; a container that's never written to disk.
    static func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Hosts `view` (with `container` as its model container) in a window of `size`, lays it out, and returns the hosting view.
    /// Keep the returned value alive while inspecting it; the window is closed by `close(_:)` or when it is released.
    @discardableResult
    static func host<Content: View>(
        _ view: Content, size: CGSize = CGSize(width: 900, height: 600), appearance: NSAppearance.Name = .aqua, container: ModelContainer? = nil
    ) -> NSHostingView<AnyView> {
        // SwiftUI builds its accessibility tree only once an assistive app asks for it; this asks on the tests' behalf.
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let root: AnyView = container.map { AnyView(view.modelContainer($0)) } ?? AnyView(view)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        settle()
        return hosting
    }

    /// Runs the main run loop briefly so SwiftUI applies state changes, `.task`s and `onAppear`.
    static func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func close(_ hosting: NSView) { hosting.window?.close() }

    /// One element of the accessibility tree: its role, label (or title/value) and help, as VoiceOver reads them.
    struct Element: CustomStringConvertible {
        let role: NSAccessibility.Role?
        let label: String
        let help: String
        let isSelected: Bool?
        var description: String { "\(role?.rawValue ?? "?") '\(label)'" + (help.isEmpty ? "" : " help '\(help)'") }
    }

    /// Every accessibility element under `root`, depth first.
    static func elements(in root: NSView) -> [Element] {
        var found: [Element] = []
        var seen = Set<ObjectIdentifier>()
        // SwiftUI's nodes are NSObjects that answer the NSAccessibility getters but don't conform in Swift, so read them by selector
        // (object-returning getters only).
        func read(_ node: NSObject, _ getter: String) -> Any? {
            node.responds(to: NSSelectorFromString(getter)) ? node.perform(NSSelectorFromString(getter))?.takeUnretainedValue() : nil
        }
        func visit(_ object: Any, depth: Int) {
            guard depth < 60, let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return }
            let role = (read(node, "accessibilityRole") as? String).map { NSAccessibility.Role(rawValue: $0) }
            let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].map { read(node, $0) as? String }
            let label = texts.compactMap { $0 }.first { !$0.isEmpty } ?? ""
            // A Bool getter can't go through `perform`; KVC boxes it.
            let selected = node.responds(to: NSSelectorFromString("isAccessibilitySelected")) ? node.value(forKey: "accessibilitySelected") as? Bool : nil
            found.append(Element(role: role, label: label, help: read(node, "accessibilityHelp") as? String ?? "", isSelected: selected))
            for child in read(node, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    /// The labels of every button under `root`.
    static func buttonLabels(in root: NSView) -> [String] { elements(in: root).filter { $0.role == .button }.map(\.label) }

    /// Every bit of text an element exposes under `root` (labels, titles, string values), for "is this shown?" checks.
    static func text(in root: NSView) -> [String] { elements(in: root).map(\.label).filter { !$0.isEmpty } }
}
