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
                VStack(spacing: 0) {
                    requestHeader
                        .padding()

                    HairlineDivider()

                    URLBarView(
                        url: $request.url,
                        method: $request.method,
                        isLoading: isLoading,
                        onSend: sendRequest
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

            ResponseViewerView(response: response, isLoading: isLoading)
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

            let history = RequestHistory(request: request)
            do {
                let result = try await httpClient.execute(request: request)
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
}
