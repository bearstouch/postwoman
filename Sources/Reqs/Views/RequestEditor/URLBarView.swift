import SwiftUI

struct URLBarView: View {
    @Binding var url: String
    @Binding var method: HTTPMethod
    let isLoading: Bool
    /// What the collection's environment fills in; the bar shows the resolved URL under the field when it uses variables.
    var resolver: VariableResolver?
    let onSend: () -> Void
    /// Stops the request in flight; while it runs, Send becomes Stop.
    var onStop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar
            if let resolver, Self.showsResolvedURL(url, resolver: resolver) {
                resolvedURL(resolver)
            }
        }
    }

    /// Whether the resolved URL line shows: only when the URL uses `{{variables}}` and there is an environment to fill them.
    static func showsResolvedURL(_ url: String, resolver: VariableResolver?) -> Bool {
        guard let resolver else { return false }
        return !resolver.tokens(in: url).isEmpty
    }

    /// The URL with each variable's value in the color of where it comes from; the tooltip lists them.
    private func resolvedURL(_ resolver: VariableResolver) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)
            Text(VariableDescription.resolvedText(url, resolver: resolver))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.leading, 112)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resolved URL")
        // After combining, so VoiceOver reads the help once rather than once per child.
        .help(VariableDescription.help(for: resolver.tokens(in: url), resolver: resolver))
    }

    private var action: URLBarAction { URLBarAction.current(url: url, isLoading: isLoading, canStop: onStop != nil) }

    private var bar: some View {
        HStack(spacing: 12) {
            Picker("Method", selection: $method) {
                ForEach(HTTPMethod.allCases) { method in
                    Text(method.rawValue)
                        .tag(method)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .tint(method.color)

            TextField("Enter request URL", text: $url)
                .textFieldStyle(.themed)
                .font(.system(.body, design: .monospaced))
                .onSubmit(onSend)

            switch action {
            case .stop:
                Button(action: { onStop?() }) {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                        Text("Stop")
                    }
                    .frame(width: 50)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the request (⌘.)")
            case .sending, .send:
                Button(action: onSend) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 50)
                    } else {
                        Text("Send")
                            .frame(width: 50)
                    }
                }
                .buttonStyle(.borderedProminent)
                .shadow(color: url.isEmpty ? .clear : Theme.accentGlow, radius: 10)
                .disabled(!action.isEnabled)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

/// What the URL bar's trailing button does: Send (enabled once there is a URL), a disabled Send while a request without
/// a way to stop runs, or Stop.
enum URLBarAction: Equatable {
    case send(isEnabled: Bool)
    case sending
    case stop

    static func current(url: String, isLoading: Bool, canStop: Bool) -> URLBarAction {
        if isLoading { return canStop ? .stop : .sending }
        return .send(isEnabled: !url.isEmpty)
    }

    /// Whether the button can be pressed.
    var isEnabled: Bool {
        switch self {
        case .send(let isEnabled): isEnabled
        case .sending: false
        case .stop: true
        }
    }
}

#Preview {
    @Previewable @State var url = "https://api.example.com/users"
    @Previewable @State var method: HTTPMethod = .get

    URLBarView(
        url: $url,
        method: $method,
        isLoading: false,
        onSend: {}
    )
    .padding()
}
