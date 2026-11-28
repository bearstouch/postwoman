import AppKit
import SwiftUI

struct BodyTabView: View {
    @Binding var bodyType: ContentType
    @Binding var bodyContent: String
    /// A File body's name and size (`APIRequest.bodyFileName`, `bodyFileSize`; the bytes are never read to show them),
    /// and how to attach or remove the file (`APIRequest.attachFile`).
    @Binding var bodyFileName: String?
    @Binding var bodyFileSize: Int?
    var attachFile: (Data?, String?) -> Void = { _, _ in }
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
            case .file:
                FileBodyEditorView(fileName: bodyFileName, fileSize: bodyFileSize, attachFile: attachFile)
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

/// A File body: the chosen file's name, size and type, a button to choose (or drop) another, and Remove.
struct FileBodyEditorView: View {
    let fileName: String?
    let fileSize: Int?
    let attachFile: (Data?, String?) -> Void
    @State private var isChoosing = false
    @State private var isReading = false
    @State private var isDropTargeted = false
    @State private var failure: String?

    var body: some View {
        let state = FileBodyEditing.State(size: fileSize, name: fileName)
        VStack(spacing: 12) {
            Image(systemName: state.symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(state.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Button(state.chooseTitle) { isChoosing = true }
                    .disabled(isReading)
                if state.canRemove {
                    Button("Remove", role: .destructive) {
                        attachFile(nil, nil)
                        failure = nil
                    }
                    .help("Remove the file from this request")
                    .disabled(isReading)
                }
            }
            if isReading {
                ProgressView("Reading the file…")
                    .controlSize(.small)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.failure)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.field)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.appAccent : Theme.hairline, style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4]))
                .padding(12)
        )
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): attach(url)
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isReading, let url = urls.first(where: \.isFileURL) else { return false }
            attach(url)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    /// Reads the file off the main thread (up to 25 MB, maybe on a slow volume), then attaches it. A failure keeps the
    /// file the request had.
    private func attach(_ url: URL) {
        isReading = true
        Task {
            let result = await Task.detached { () -> Result<(name: String, data: Data), FileBody.Failure> in
                do throws(FileBody.Failure) { return .success(try FileBody.read(url)) } catch { return .failure(error) }
            }.value
            isReading = false
            switch result {
            case .success(let file):
                attachFile(file.data, file.name)
                failure = nil
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }
}

/// The File editor's decisions: what it shows for the file a request has, has lost, or doesn't have.
enum FileBodyEditing {
    enum State: Equatable {
        /// No file chosen.
        case empty
        /// A file is attached: its name, size and the Content-Type it is sent with by default.
        case attached(name: String, size: Int, mimeType: String)
        /// Only the name is left (restored from History, or imported from another app): sending fails until it is chosen again.
        case missing(name: String)

        init(size: Int?, name: String?) {
            if let size {
                self = .attached(name: name ?? "Unnamed file", size: size, mimeType: FileBody.mimeType(forFileName: name))
            } else if let name, !name.isEmpty {
                self = .missing(name: name)
            } else {
                self = .empty
            }
        }

        var title: String {
            switch self {
            case .empty: "No file chosen"
            case .attached(let name, _, _): name
            case .missing(let name): "\(name) isn't attached"
            }
        }

        var detail: String {
            switch self {
            case .empty: "Choose a file, or drop one here. Its bytes are sent as the request body."
            case .attached(_, let size, let mimeType): "\(FileBody.formattedSize(size)) · sent as \(mimeType) unless a Content-Type header is set"
            case .missing: "Reqs has only the file's name (History and other apps' exports keep no file). Choose the file to send it."
            }
        }

        var symbol: String {
            switch self {
            case .empty: "doc.badge.plus"
            case .attached: "doc.fill"
            case .missing: "questionmark.folder"
            }
        }

        var chooseTitle: String { self == .empty ? "Choose File…" : "Choose Another File…" }
        var canRemove: Bool { self != .empty }
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
            formPairs = FormBody.pairs(from: bodyContent)
        }
        .onChange(of: formPairs) { _, newValue in
            // Only an edit is written back: showing the fields must not respell (or, for a body of another type chosen by
            // mistake, replace) what is stored.
            if let body = FormBody.edited(newValue, from: bodyContent) { bodyContent = body }
        }
        .onChange(of: bodyContent) { _, newValue in
            // Changed from outside (an agent's request_update): show it, instead of overwriting it on the next edit.
            if FormBody.edited(formPairs, from: newValue) != nil { formPairs = FormBody.pairs(from: newValue) }
        }
    }
}

/// The body tab's decisions: which editor a body type gets, and what Prettify makes of the text.
enum BodyEditing {
    /// The editor for a body type: none, form fields, a file, or a text editor.
    enum Editor: Equatable {
        case none, form, file, code

        init(_ type: ContentType) {
            switch type {
            case .none: self = .none
            case .formData, .urlEncoded: self = .form
            case .file: self = .file
            case .json, .xml, .text: self = .code
            }
        }
    }

    /// The note above the editor when the method doesn't send a body (GET, HEAD) and a body type is chosen, or nil.
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
    /// The fields of `body`, decoded (`+` is a space, then percent-encoding); a field without `=` has an empty value.
    static func pairs(from body: String) -> [KeyValuePair] {
        func decoded(_ text: Substring) -> String {
            let spaced = text.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        return body.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { return nil }
            return KeyValuePair(key: decoded(key), value: parts.count > 1 ? decoded(parts[1]) : "")
        }
    }

    /// The body to store for the editor's `pairs`, or nil when they say what `body` already says (however it is spelled),
    /// so only an edit rewrites it.
    static func edited(_ pairs: [KeyValuePair], from body: String) -> String? {
        let new = Self.body(from: pairs)
        return new == Self.body(from: Self.pairs(from: body)) ? nil : new
    }

    /// What a form name or value keeps unencoded: query characters other than the separators `&` and `=`, and `+` (a space);
    /// and braces, so a `{{variable}}` typed in a field is still one when the request is resolved.
    private static let fieldAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+")).union(CharacterSet(charactersIn: "{}"))

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

    BodyTabView(bodyType: $bodyType, bodyContent: $bodyContent, bodyFileName: .constant(nil), bodyFileSize: .constant(nil))
        .frame(width: 600, height: 400)
}
