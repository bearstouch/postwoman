import SwiftUI
import UniformTypeIdentifiers

struct ResponseBodyView: View {
    let responseBody: String?
    let contentType: String?
    /// The reply a streamed LLM response assembles to; adds the Text view mode.
    var assembledText: String?
    /// Keep the end in view as the body grows (a stream arriving).
    var followsEnd = false
    var emptyMessage = "No response body"

    @State private var viewMode: ViewMode = .pretty
    @State private var formattedBody: String = ""
    @State private var isJSON = false
    @State private var findRequest = 0
    @AppStorage("responseWrapsLines") private var wrapsLines = true

    enum ViewMode: String, CaseIterable {
        case text = "Text"
        case pretty = "Pretty"
        case raw = "Raw"
    }

    private var modes: [ViewMode] {
        ResponseBodyFormat.modes(hasAssembledText: assembledText != nil)
    }

    private var mode: ViewMode {
        ResponseBodyFormat.mode(viewMode, among: modes)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HairlineDivider()

            if !displayedBody.isEmpty {
                ResponseTextView(
                    text: displayedBody,
                    highlightsJSON: isJSON && mode == .pretty,
                    wrapsLines: wrapsLines,
                    findRequest: findRequest,
                    followsEnd: followsEnd,
                    font: ThemeStore.shared.codeFont,
                    themeRevision: ThemeStore.shared.revision
                )
                .background(Theme.field)
            } else {
                Text(emptyMessage)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.field)
            }
        }
        .onAppear {
            formatBody()
            if assembledText != nil { viewMode = .text }
        }
        .onChange(of: assembledText == nil) { _, isNil in
            // A reply's text is what one wants to read, so show it once it appears.
            if !isNil { viewMode = .text }
        }
        .onChange(of: responseBody) { _, _ in formatBody() }
        .onChange(of: contentType) { _, _ in formatBody() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("View mode", selection: Binding(get: { mode }, set: { viewMode = $0 })) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            if let label = contentTypeLabel {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
                    .help(contentType ?? "")
            }

            Spacer()

            ResponseIconButton(systemImage: "arrow.turn.down.left", help: wrapsLines ? "Don't wrap lines" : "Wrap lines", isOn: wrapsLines) {
                wrapsLines.toggle()
            }
            ResponseIconButton(systemImage: "magnifyingglass", help: "Find in body (⌘F)") {
                findRequest += 1
            }
            .disabled(displayedBody.isEmpty)
            ResponseIconButton(systemImage: "square.and.arrow.down", help: "Save body to a file") {
                saveToFile()
            }
            .disabled(displayedBody.isEmpty)
            ResponseIconButton(systemImage: "doc.on.doc", help: "Copy body") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayedBody, forType: .string)
            }
            .disabled(displayedBody.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var displayedBody: String {
        ResponseBodyFormat.displayed(mode: mode, assembledText: assembledText, formatted: formattedBody, raw: responseBody)
    }

    private var contentTypeLabel: String? {
        ResponseBodyFormat.contentTypeLabel(contentType, isJSON: isJSON)
    }

    private func formatBody() {
        (formattedBody, isJSON) = ResponseBodyFormat.format(responseBody, contentType: contentType)
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        let fileExtension = ResponseBodyFormat.fileExtension(mode: mode, label: contentTypeLabel)
        panel.nameFieldStringValue = "response.\(fileExtension)"
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let content = displayedBody
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The body view's decisions: which view modes exist, what each shows, the media type's short name and the
/// saved file's extension. Plain functions of the response, so they can be tested without a window.
enum ResponseBodyFormat {
    typealias ViewMode = ResponseBodyView.ViewMode

    /// Text only when there is assembled text.
    static func modes(hasAssembledText: Bool) -> [ViewMode] {
        ViewMode.allCases.filter { $0 != .text || hasAssembledText }
    }

    /// The chosen mode, or Pretty when it isn't offered.
    static func mode(_ chosen: ViewMode, among modes: [ViewMode]) -> ViewMode {
        modes.contains(chosen) ? chosen : .pretty
    }

    /// The body pretty-printed when it is JSON (by content type or by its first character), else as received.
    static func format(_ body: String?, contentType: String?) -> (text: String, isJSON: Bool) {
        guard let body else { return ("", false) }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeJSON = contentType?.contains("json") == true || trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if looksLikeJSON, let pretty = JSONFormatter.prettify(body) { return (pretty, true) }
        return (body, false)
    }

    /// What a mode shows: the assembled reply, the formatted body, or the body as received.
    static func displayed(mode: ViewMode, assembledText: String?, formatted: String, raw: String?) -> String {
        switch mode {
        case .text: return assembledText ?? ""
        case .pretty: return formatted
        case .raw: return raw ?? ""
        }
    }

    /// A short name for the body's media type: "JSON", "HTML", "XML", "Text"; nil when unknown.
    static func contentTypeLabel(_ contentType: String?, isJSON: Bool) -> String? {
        // Empty pieces are kept, so "; charset=utf-8" has an empty media type rather than "charset=utf-8".
        let mediaType = contentType?.split(separator: ";", omittingEmptySubsequences: false).first
        guard let type = mediaType?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else {
            return isJSON ? "JSON" : nil
        }
        if type.contains("json") { return "JSON" }
        if type.contains("html") { return "HTML" }
        if type.contains("xml") { return "XML" }
        if type == "text/plain" { return "Text" }
        if type.hasPrefix("text/") { return type.dropFirst(5).uppercased() }
        return type
    }

    /// The saved file's extension: the assembled reply is text; otherwise from the media type's short name.
    static func fileExtension(mode: ViewMode, label: String?) -> String {
        switch mode == .text ? "Text" : label {
        case "JSON": return "json"
        case "HTML": return "html"
        case "XML": return "xml"
        default: return "txt"
        }
    }
}

/// A small borderless icon button for the response toolbars; `isOn` tints it with the accent.
struct ResponseIconButton: View {
    let systemImage: String
    let help: String
    var isOn = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.appAccent : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Theme.selection : (isHovering ? Theme.chip : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    ResponseBodyView(
        responseBody: """
            {"id": 1, "name": "John Doe", "email": "john@example.com", "nested": {"key": "value", "ok": true, "n": 12.5}}
            """,
        contentType: "application/json"
    )
    .frame(width: 600, height: 400)
}
