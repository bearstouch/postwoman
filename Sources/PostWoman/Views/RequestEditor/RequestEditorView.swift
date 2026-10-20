import SwiftUI
import SwiftData

struct RequestEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var request: APIRequest

    @State private var selectedTab: RequestTab = .params
    @State private var response: HTTPResponse?
    @State private var isLoading: Bool = false
    @State private var showCodeGenerator: Bool = false
    @State private var isRenaming: Bool = false

    private let httpClient = HTTPClient()

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                requestHeader
                    .padding()

                Divider()

                URLBarView(
                    url: $request.url,
                    method: $request.method,
                    isLoading: isLoading,
                    onSend: sendRequest
                )
                .padding(.horizontal)
                .padding(.vertical, 12)

                Divider()

                RequestTabView(selectedTab: $selectedTab, request: request)

                Divider()

                tabContent
            }
            .frame(minHeight: 300)

            ResponseViewerView(response: response, isLoading: isLoading)
                .frame(minHeight: 200)
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
            CodeGeneratorView(request: request)
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
    }

    private var requestHeader: some View {
        HStack {
            if isRenaming {
                TextField("Request Name", text: $request.name)
                    .textFieldStyle(.roundedBorder)
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

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .params:
            ParamsTabView(params: $request.queryParams)
        case .headers:
            HeadersTabView(headers: $request.headers)
        case .body:
            BodyTabView(bodyType: $request.bodyType, bodyContent: $request.bodyContent)
        case .auth:
            AuthTabView(request: request)
        }
    }

    private func sendRequest() {
        guard !request.url.isEmpty else { return }

        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                response = try await httpClient.execute(request: request)
                saveToHistory()
            } catch {
                response = HTTPResponse.error(error)
            }
        }
    }

    private func saveRequest() {
        request.updatedAt = Date()
        try? modelContext.save()
    }

    private func duplicateRequest() {
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

        modelContext.insert(duplicate)
    }

    private func saveToHistory() {
        let history = RequestHistory(
            url: request.url,
            method: request.method,
            requestHeaders: request.headers,
            requestBody: request.bodyContent.isEmpty ? nil : request.bodyContent
        )
        history.statusCode = response?.statusCode
        history.responseHeaders = response?.headers
        history.responseBody = response?.body
        history.responseTime = response?.responseTime
        history.responseSize = response?.body?.data(using: .utf8)?.count
        history.wasSuccessful = response?.isSuccess ?? false
        history.savedRequestID = request.id

        modelContext.insert(history)
    }
}
