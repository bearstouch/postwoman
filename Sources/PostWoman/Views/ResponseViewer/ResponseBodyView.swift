import SwiftUI
import UniformTypeIdentifiers

struct ResponseBodyView: View {
    let responseBody: String?
    let contentType: String?
    var emptyMessage = "No response body"

    @State private var viewMode: ViewMode = .pretty
    @State private var formattedBody: String = ""
    @State private var isJSON = false
    @State private var findRequest = 0
    @AppStorage("responseWrapsLines") private var wrapsLines = true

    enum ViewMode: String, CaseIterable {
        case pretty = "Pretty"
        case raw = "Raw"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HairlineDivider()

            if let bodyContent = responseBody, !bodyContent.isEmpty {
                ResponseTextView(
                    text: viewMode == .pretty ? formattedBody : bodyContent,
                    highlightsJSON: isJSON,
                    wrapsLines: wrapsLines,
                    findRequest: findRequest,
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
        .onAppear(perform: formatBody)
        .onChange(of: responseBody) { _, _ in formatBody() }
        .onChange(of: contentType) { _, _ in formatBody() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("View mode", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
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
            .disabled(responseBody?.isEmpty ?? true)
            ResponseIconButton(systemImage: "square.and.arrow.down", help: "Save body to a file") {
                saveToFile()
            }
            .disabled(responseBody?.isEmpty ?? true)
            ResponseIconButton(systemImage: "doc.on.doc", help: "Copy body") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayedBody, forType: .string)
            }
            .disabled(responseBody?.isEmpty ?? true)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var displayedBody: String {
        viewMode == .pretty ? formattedBody : (responseBody ?? "")
    }

    /// A short name for the body's media type: "JSON", "HTML", "XML", "Text"; nil when unknown.
    private var contentTypeLabel: String? {
        guard let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else {
            return isJSON ? "JSON" : nil
        }
        if type.contains("json") { return "JSON" }
        if type.contains("html") { return "HTML" }
        if type.contains("xml") { return "XML" }
        if type == "text/plain" { return "Text" }
        if type.hasPrefix("text/") { return type.dropFirst(5).uppercased() }
        return type
    }

    private func formatBody() {
        guard let body = responseBody else {
            formattedBody = ""
            isJSON = false
            return
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeJSON = contentType?.contains("json") == true || trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if looksLikeJSON, let pretty = JSONFormatter.prettify(body) {
            formattedBody = pretty
            isJSON = true
        } else {
            formattedBody = body
            isJSON = false
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        let fileExtension: String
        switch contentTypeLabel {
        case "JSON": fileExtension = "json"
        case "HTML": fileExtension = "html"
        case "XML": fileExtension = "xml"
        default: fileExtension = "txt"
        }
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

/// A small borderless icon button for the response toolbars; `isOn` tints it pink.
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
