import SwiftUI

enum RequestTab: String, CaseIterable, Identifiable {
    case params = "Params"
    case headers = "Headers"
    case body = "Body"
    case auth = "Auth"

    var id: String { rawValue }
}

struct RequestTabView: View {
    @Binding var selectedTab: RequestTab
    let request: APIRequest

    var paramsCount: Int {
        request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }.count
    }

    var headersCount: Int {
        request.headers.filter { $0.isEnabled && !$0.key.isEmpty }.count
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RequestTab.allCases) { tab in
                TabButton(
                    title: tab.rawValue,
                    isSelected: selectedTab == tab,
                    badge: badgeCount(for: tab)
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

    private func badgeCount(for tab: RequestTab) -> Int? {
        switch tab {
        case .params: return paramsCount > 0 ? paramsCount : nil
        case .headers: return headersCount > 0 ? headersCount : nil
        case .body: return request.bodyContent.isEmpty ? nil : 1
        case .auth: return request.authenticationType != .none ? 1 : nil
        }
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
                        .background(isSelected ? Color.postWomanPink : Theme.chip)
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
