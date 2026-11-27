import SwiftUI
import SwiftData

struct RequestEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var request: APIRequest

    @State private var selectedTab: RequestTab = .params
    @State private var response: HTTPResponse?
    @State private var isLoading: Bool = false
    /// The send in flight; cancelling it stops the request (a stream keeps what arrived).
    @State private var sendTask: Task<Void, Never>?
    @State private var showCodeGenerator: Bool = false
    @State private var isRenaming: Bool = false
    /// Variables the last send used that the collection's environments don't define.
    @State private var missingVariables: [String] = []
    /// The environment the last send resolved with.
    @State private var sentEnvironmentName: String?

    private let httpClient = HTTPClient()

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    requestHeader
                        .padding()

                    HairlineDivider()

                    URLBarView(
                        url: $request.url,
                        method: $request.method,
                        isLoading: isLoading,
                        resolver: resolver,
                        onSend: sendRequest,
                        onStop: stopRequest
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .background(Theme.bar)

                HairlineDivider()

                RequestTabView(selectedTab: $selectedTab, request: request)

                HairlineDivider()

                tabContent
            }
            .frame(minHeight: 300)
            .background(Theme.canvas)

            VStack(spacing: 0) {
                if MissingVariablesNotice.isShown(missing: missingVariables, isLoading: isLoading) {
                    missingVariablesNotice
                    HairlineDivider()
                }
                // Once a stream's headers arrive, its response shows while it grows.
                ResponseViewerView(response: response, isLoading: isLoading && !isStreaming)
            }
            .frame(minHeight: 200)
            .themedSplitDividers()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { showCodeGenerator = true }) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .help("Generate Code")

                Button(action: saveRequest) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save Request")
            }
        }
        .sheet(isPresented: $showCodeGenerator) {
            CodeGeneratorView(request: request, resolver: resolver, environmentLabel: request.folder.map { "\($0.name) · \($0.activeEnvironmentName)" })
        }
        .onReceive(NotificationCenter.default.publisher(for: .sendRequest)) { _ in
            sendRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveRequest)) { _ in
            saveRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .generateCode)) { _ in
            showCodeGenerator = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .duplicateRequest)) { _ in
            duplicateRequest()
        }
        .onDisappear {
            // A stream can run forever; don't keep one open for a request nobody is looking at.
            if isStreaming { stopRequest() }
        }
    }

    private var requestHeader: some View {
        HStack {
            if isRenaming {
                TextField("Request Name", text: $request.name)
                    .textFieldStyle(.themed)
                    .frame(maxWidth: 300)
                    .onSubmit {
                        isRenaming = false
                    }
            } else {
                Text(request.name)
                    .font(.headline)
                    .onTapGesture(count: 2) {
                        isRenaming = true
                    }
            }

            Spacer()

            if let folder = request.folder {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption)
                    Text(folder.name)
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
    }

    /// What `{{variables}}` resolve to: the collection's Default environment and its selected one.
    private var resolver: VariableResolver? { request.folder?.variableResolver }

    /// Says which variables the request was sent with as written, because no environment defines them.
    private var missingVariablesNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(missingVariablesText)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if let folder = request.folder {
                Button("Manage Environments…") {
                    NotificationCenter.default.post(name: .manageEnvironments, object: nil, userInfo: ["folderID": folder.id])
                }
                .buttonStyle(.link)
            }
            Button {
                missingVariables = []
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.12))
    }

    private var missingVariablesText: String {
        MissingVariablesNotice.text(missing: missingVariables, defaultEnvironmentName: request.folder?.defaultEnvironmentName, sentEnvironmentName: sentEnvironmentName)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .params:
            ParamsTabView(params: $request.queryParams, resolver: resolver)
        case .headers:
            HeadersTabView(headers: $request.headers, resolver: resolver)
        case .body:
            BodyTabView(bodyType: $request.bodyType, bodyContent: $request.bodyContent)
        case .auth:
            AuthTabView(request: request)
        }
    }

    /// Whether a streamed response is arriving.
    private var isStreaming: Bool { isLoading && response?.stream?.isLive == true }

    private func stopRequest() {
        sendTask?.cancel()
    }

    private func sendRequest() {
        guard Self.canSend(url: request.url, isSending: sendTask != nil) else { return }

        // Resolve now, with the environment in use when Send was pressed.
        let resolver = self.resolver ?? .empty
        let template = RequestSnapshot(request)
        let sent = template.resolved(with: resolver)
        let environmentName = request.folder?.activeEnvironmentName
        missingVariables = template.missingVariables(with: resolver)
        sentEnvironmentName = environmentName

        response = nil
        isLoading = true
        sendTask = Task {
            defer {
                isLoading = false
                sendTask = nil
            }

            // History keeps what was sent, with secret variables left as {{name}}.
            let history = RequestHistory(request: request, sent: template.resolved(with: resolver, redactSecrets: true), environmentName: environmentName)
            do {
                let result = try await httpClient.execute(request: sent) { partial in
                    response = partial
                }
                response = result
                history.record(result)
            } catch {
                response = HTTPResponse.error(error)
                history.record(error)
            }
            modelContext.insert(history)
            HistoryRetention.trim(modelContext)
        }
    }

    private func saveRequest() {
        request.updatedAt = Date()
        try? modelContext.save()
    }

    private func duplicateRequest() {
        modelContext.insert(Self.duplicate(of: request))
    }

    /// Whether Send (button, ⌘↩ or the menu) starts a request: there is a URL and none is in flight.
    static func canSend(url: String, isSending: Bool) -> Bool { !url.isEmpty && !isSending }

    /// A copy of `request` named "… (Copy)", in the same collection, with its params, headers, body and auth. Not inserted.
    static func duplicate(of request: APIRequest) -> APIRequest {
        let duplicate = APIRequest(
            name: "\(request.name) (Copy)",
            url: request.url,
            method: request.method,
            folder: request.folder
        )
        duplicate.headers = request.headers
        duplicate.queryParams = request.queryParams
        duplicate.bodyType = request.bodyType
        duplicate.bodyContent = request.bodyContent
        duplicate.authenticationType = request.authenticationType
        duplicate.authBearerToken = request.authBearerToken
        duplicate.authBasicUsername = request.authBasicUsername
        duplicate.authBasicPassword = request.authBasicPassword
        duplicate.authOAuthConfig = request.authOAuthConfig
        return duplicate
    }
}

/// The notice after a send that used `{{variables}}` no environment defines.
enum MissingVariablesNotice {
    /// Shown once the send is done, when it had undefined variables.
    static func isShown(missing: [String], isLoading: Bool) -> Bool { !missing.isEmpty && !isLoading }

    /// "2 variables were sent as written, because neither Staging nor Default defines it: {{a}}, {{b}}".
    /// `defaultEnvironmentName` is nil when the request has no collection.
    static func text(missing: [String], defaultEnvironmentName: String?, sentEnvironmentName: String?) -> String {
        let names = missing.map { "{{\($0)}}" }.joined(separator: ", ")
        let place =
            defaultEnvironmentName.map { "neither \(sentEnvironmentName ?? "the environment") nor \($0) defines it" } ?? "this request has no collection"
        let count = missing.count == 1 ? "1 variable was" : "\(missing.count) variables were"
        return "\(count) sent as written, because \(place): \(names)"
    }
}
