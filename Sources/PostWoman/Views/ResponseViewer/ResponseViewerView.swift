import SwiftUI

struct ResponseViewerView: View {
    let response: HTTPResponse?
    let isLoading: Bool

    @State private var selectedTab: ResponseTab = .body

    enum ResponseTab: String, CaseIterable {
        case body = "Body"
        case headers = "Headers"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let response = response {
                ResponseStatusView(response: response)
                Divider()
            }

            if isLoading {
                loadingView
            } else if let response = response {
                responseContent(response)
            } else {
                emptyResponseView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Sending request...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyResponseView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Response")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Send a request to see the response here")
                .font(.body)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func responseContent(_ response: HTTPResponse) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ResponseTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .fontWeight(selectedTab == tab ? .semibold : .regular)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTab == tab ? Color.postWomanPink.opacity(0.15) : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            switch selectedTab {
            case .body:
                ResponseBodyView(responseBody: response.body, contentType: response.contentType)
            case .headers:
                ResponseHeadersView(headers: response.headers)
            }
        }
    }
}
