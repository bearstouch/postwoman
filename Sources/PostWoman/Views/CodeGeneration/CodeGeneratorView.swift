import SwiftUI

struct CodeGeneratorView: View {
    let request: APIRequest
    /// The collection's environment, for filling in `{{variables}}`.
    var resolver: VariableResolver?
    /// "Collection · Environment", shown on the switch.
    var environmentLabel: String?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedLanguage: CodeLanguage = .curl
    @State private var generatedCode: String = ""
    @State private var resolvesVariables = true

    enum CodeLanguage: String, CaseIterable, Identifiable {
        case curl = "cURL"
        case swift = "Swift"
        case python = "Python"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .curl: return "terminal"
            case .swift: return "swift"
            case .python: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()

            HairlineDivider()

            languagePicker
                .padding()

            if let environmentLabel, resolver != nil {
                HairlineDivider()
                variablesSwitch(environmentLabel)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
            }

            HairlineDivider()

            codeView
        }
        .frame(width: 700, height: 500)
        .onAppear {
            generateCode()
        }
        .onChange(of: selectedLanguage) { _, _ in
            generateCode()
        }
        .onChange(of: resolvesVariables) { _, _ in
            generateCode()
        }
    }

    private func variablesSwitch(_ label: String) -> some View {
        HStack(spacing: 10) {
            Toggle("Resolve variables with \(label)", isOn: $resolvesVariables)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Label("Secrets stay as {{name}}", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Generate Code")
                    .font(.headline)
                Text("Export this request as code in various languages")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.escape)
        }
    }

    private var languagePicker: some View {
        HStack(spacing: 12) {
            ForEach(CodeLanguage.allCases) { language in
                Button {
                    selectedLanguage = language
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: language.icon)
                        Text(language.rawValue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(selectedLanguage == language ? Color.appAccent : Theme.chip)
                    .foregroundColor(selectedLanguage == language ? .white : .primary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    private var codeView: some View {
        VStack(spacing: 0) {
            // Terminal Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(Color.yellow.opacity(0.8))
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 10, height: 10)

                Spacer()

                Text(selectedLanguage.rawValue.lowercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.terminalBar)

            ScrollView([.horizontal, .vertical]) {
                Text(generatedCode)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .lineSpacing(4)
                    .foregroundColor(Theme.terminalText)  // Trellis phosphor green
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .background(Theme.terminal)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .padding()
    }

    private func generateCode() {
        var source = RequestSnapshot(request)
        if resolvesVariables, let resolver { source = source.resolved(with: resolver, redactSecrets: true) }
        switch selectedLanguage {
        case .curl:
            generatedCode = CURLGenerator().generate(from: source)
        case .swift:
            generatedCode = SwiftGenerator().generate(from: source)
        case .python:
            generatedCode = PythonGenerator().generate(from: source)
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(generatedCode, forType: .string)
    }
}

#Preview {
    CodeGeneratorView(
        request: {
            let req = APIRequest(name: "Test Request", url: "https://api.example.com/users")
            req.method = .post
            req.headers = [
                KeyValuePair(key: "Content-Type", value: "application/json"),
                KeyValuePair(key: "Accept", value: "application/json")
            ]
            req.bodyType = .json
            req.bodyContent = """
                {
                    "name": "John Doe",
                    "email": "john@example.com"
                }
                """
            return req
        }()
    )
}
