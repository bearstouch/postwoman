import AppKit
import SwiftUI

/// Which window a menu command is for. Commands reach views as notifications, which every open window hears, so each
/// view asks here before acting: only the frontmost main window does, or ⌘↩ would send a request from every window.
@MainActor
enum CommandTarget {
    /// The windows showing a `ContentView`.
    private static let contentWindows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) { contentWindows.add(window) }

    /// Whether a view in `window` handles a command: its window is the frontmost main window. A view that isn't in a
    /// main window at all (a preview, a test host) has no other window to defer to, and handles it.
    static func accepts(_ window: NSWindow?) -> Bool {
        guard let window, contentWindows.contains(window) else { return true }
        guard let front = frontmost(of: NSApp.orderedWindows, where: { contentWindows.contains($0) }) else { return true }
        return front === window
    }

    /// The first of `ordered` (front to back) that is a main window: a sheet or the Settings window in front is skipped.
    static func frontmost(of ordered: [NSWindow], where isContent: (NSWindow) -> Bool) -> NSWindow? { ordered.first(where: isContent) }
}

/// The window a view is in, held weakly (a view's state must not keep its window alive).
@MainActor
final class CommandWindow {
    weak var window: NSWindow? {
        didSet { if window != nil { wasInAWindow = true } }
    }
    private var wasInAWindow = false

    /// A view whose window has closed handles nothing more; one that never had a window is on its own and does.
    var acceptsCommands: Bool { window == nil && wasInAWindow ? false : CommandTarget.accepts(window) }
}

/// Finds the window of the view it is the background of; with `registers`, that window becomes a command target.
struct CommandWindowReader: NSViewRepresentable {
    let holder: CommandWindow
    var registers = false

    func makeNSView(context: Context) -> NSView { ReaderView(holder: holder, registers: registers) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        private let holder: CommandWindow
        private let registers: Bool

        init(holder: CommandWindow, registers: Bool) {
            self.holder = holder; self.registers = registers
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            holder.window = window
            if registers, let window { CommandTarget.register(window) }
        }
    }
}
