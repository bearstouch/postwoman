import AppKit
import SwiftUI

struct BodyTabView: View {
    @Binding var bodyType: ContentType
    @Binding var bodyContent: String
    /// The request's method; a HEAD request's body is kept but not sent, and the tab says so.
    var method: HTTPMethod = .get

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Request Body")
                    .font(.headline)

                Spacer()

                if BodyEditing.canPrettify(bodyType) {
                    Button(action: prettify) {
                        Image(systemName: "text.alignleft")
                    }
                    .buttonStyle(.borderless)
                    .help("Prettify \(bodyType.rawValue)")
                    .accessibilityLabel("Prettify \(bodyType.rawValue)")
                    .disabled(!BodyEditing.hasContent(bodyContent))
                }

                Picker("Body Type", selection: $bodyType) {
                    ForEach(ContentType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            .padding()
            .background(Theme.bar)

            HairlineDivider()

            if let notice = BodyEditing.notice(method: method, bodyType: bodyType) {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bar)
                HairlineDivider()
            }

            switch BodyEditing.Editor(bodyType) {
            case .none:
                VStack {
                    Spacer()
                    Text("This request does not have a body")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .form:
                FormDataEditorView(bodyContent: $bodyContent)
            case .code:
                CodeTextEditor(
                    text: $bodyContent, font: ThemeStore.shared.codeFont, highlightsJSON: bodyType == .json,
                    themeRevision: ThemeStore.shared.revision
                )
                .background(Theme.field)
            }
        }
    }

    private func prettify() {
        guard let formatted = BodyEditing.prettified(bodyContent, as: bodyType) else {
            NSSound.beep()
            return
        }
        if formatted != bodyContent {
            bodyContent = formatted
        }
    }
}

struct FormDataEditorView: View {
    @Binding var bodyContent: String
    @State private var formPairs: [KeyValuePair] = []

    var body: some View {
        ScrollView {
            KeyValueEditorView(
                pairs: $formPairs,
                keyPlaceholder: "Field name",
                valuePlaceholder: "Value"
            )
        }
        .onAppear {
            parseFormData()
        }
        .onChange(of: formPairs) { _, newValue in
            serializeFormData(newValue)
        }
    }

    private func parseFormData() {
        guard !bodyContent.isEmpty else { return }
        formPairs = FormBody.pairs(from: bodyContent)
    }

    private func serializeFormData(_ pairs: [KeyValuePair]) {
        bodyContent = FormBody.body(from: pairs)
    }
}

/// The body tab's decisions: which editor a body type gets, and what Prettify makes of the text.
enum BodyEditing {
    /// The editor for a body type: none, form fields, or a text editor.
    enum Editor: Equatable {
        case none, form, code

        init(_ type: ContentType) {
            switch type {
            case .none: self = .none
            case .formData, .urlEncoded: self = .form
            case .json, .xml, .text: self = .code
            }
        }
    }

    /// The note above the editor when the method doesn't send a body (HEAD) and a body type is chosen, or nil.
    static func notice(method: HTTPMethod, bodyType: ContentType) -> String? {
        guard !method.sendsBody, bodyType != .none else { return nil }
        return "\(method.rawValue) requests are sent without a body. It is kept for when you choose another method."
    }

    /// Whether the body type has a Prettify button (JSON and XML).
    static func canPrettify(_ type: ContentType) -> Bool { type == .json || type == .xml }

    /// Whether there is anything to prettify: text other than whitespace.
    static func hasContent(_ content: String) -> Bool { !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// `content` indented, or nil when it doesn't parse as `type` (or `type` can't be prettified), so the text stays as it is.
    static func prettified(_ content: String, as type: ContentType) -> String? {
        switch type {
        case .json: JSONFormatter.prettify(content)
        case .xml: (try? XMLDocument(xmlString: content, options: []))?.xmlString(options: .nodePrettyPrint)
        default: nil
        }
    }
}

/// A form body (`a=1&b=2`) as editable fields and back.
enum FormBody {
    /// The fields of `body`, percent-decoded; a field without `=` has an empty value.
    static func pairs(from body: String) -> [KeyValuePair] {
        body.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { return nil }
            let value = parts.count > 1 ? String(parts[1]) : ""
            return KeyValuePair(
                key: String(key).removingPercentEncoding ?? String(key),
                value: value.removingPercentEncoding ?? value
            )
        }
    }

    /// What a form name or value keeps unencoded: query characters other than the separators `&` and `=`, and `+` (a space).
    private static let fieldAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))

    /// The enabled, named fields, percent-encoded and joined with `&`.
    static func body(from pairs: [KeyValuePair]) -> String {
        pairs
            .filter { $0.isEnabled && !$0.key.isEmpty }
            .map { pair in
                let key = pair.key.addingPercentEncoding(withAllowedCharacters: fieldAllowed) ?? pair.key
                let value = pair.value.addingPercentEncoding(withAllowedCharacters: fieldAllowed) ?? pair.value
                return "\(key)=\(value)"
            }
            .joined(separator: "&")
    }
}

#Preview {
    @Previewable @State var bodyType: ContentType = .json
    @Previewable @State var bodyContent = """
        {
            "name": "John Doe",
            "email": "john@example.com"
        }
        """

    BodyTabView(bodyType: $bodyType, bodyContent: $bodyContent)
        .frame(width: 600, height: 400)
}
