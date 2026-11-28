import AppKit

/// The standard macOS About panel, laid out like Trellis's: name, icon and version, then credits that link the
/// license and the owner.
enum AboutPanel {
    static let licenseURL = URL(string: "https://github.com/bearstouch/postwoman/blob/master/LICENSE")!
    static let ownerURL = URL(string: "https://github.com/bearstouch")!

    /// The credits text. The standard Copyright option is plain text, so the linked copyright line lives here.
    static func credits() -> NSAttributedString {
        let license = "MIT License"
        let owner = "bearstouch"
        let credits = NSMutableAttributedString(
            string: "Released under the \(license).\n\n© 2026 \(owner) and Reqs contributors. All rights reserved.",
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        for (name, link) in [(license, licenseURL), (owner, ownerURL)] {
            let range = (credits.string as NSString).range(of: name)
            if range.location != NSNotFound { credits.addAttribute(.link, value: link, range: range) }
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        return credits
    }

    @MainActor static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Reqs",
            .applicationIcon: NSApp.applicationIconImage as Any,
            .applicationVersion: AppVersion.current,
            .version: "",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "",
            .credits: credits()
        ])
        NSApp.activate()
    }
}
