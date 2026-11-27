import SwiftUI

enum RequestTab: String, CaseIterable, Identifiable {
    case params = "Params"
    case headers = "Headers"
    case body = "Body"
    case auth = "Auth"

    var id: String { rawValue }

    /// The count on the tab: active params or headers, 1 for a body or an auth type, nil (no badge) when there is none.
    func badge(for request: APIRequest) -> Int? {
        switch self {
        case .params: return request.queryParams.activeCount > 0 ? request.queryParams.activeCount : nil
        case .headers: return request.headers.activeCount > 0 ? request.headers.activeCount : nil
        case .body: return request.bodyContent.isEmpty ? nil : 1
        case .auth: return request.authenticationType != .none ? 1 : nil
        }
    }
}

extension [KeyValuePair] {
    /// The pairs that are sent: enabled, with a name.
    var activeCount: Int { filter { $0.isEnabled && !$0.key.isEmpty }.count }
}

struct RequestTabView: View {
    @Binding var selectedTab: RequestTab
    let request: APIRequest

    var paramsCount: Int { request.queryParams.activeCount }

    var headersCount: Int { request.headers.activeCount }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RequestTab.allCases) { tab in
                TabButton(
                    title: tab.rawValue,
                    isSelected: selectedTab == tab,
                    badge: tab.badge(for: request)
                ) {
                    selectedTab = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.bar)
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)

                if let badge = badge {
                    Text("\(badge)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.appAccent : Theme.chip)
                        .foregroundColor(isSelected ? .white : .primary)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.selection : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
