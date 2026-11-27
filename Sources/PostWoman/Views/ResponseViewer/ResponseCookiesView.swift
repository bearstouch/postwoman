import SwiftUI

/// The cookies a response set, one row each with its attributes.
struct ResponseCookiesView: View {
    let cookies: [ResponseCookie]

    var body: some View {
        if cookies.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("No cookies")
                    .foregroundColor(.secondary)
                Text("This response didn't set any cookies.")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.field)
        } else {
            List(cookies) { cookie in
                CookieRowView(cookie: cookie)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.field)
        }
    }
}

private struct CookieRowView: View {
    let cookie: ResponseCookie

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(cookie.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.postWomanPink)
                Text(cookie.value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cookie.value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Copy value")
            }

            HStack(spacing: 6) {
                Text(cookie.domain + cookie.path)
                Text("·")
                Text(cookie.expires.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Session")
                if cookie.isSecure { flag("Secure") }
                if cookie.isHTTPOnly { flag("HttpOnly") }
                if let sameSite = cookie.sameSite { flag("SameSite=\(sameSite)") }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func flag(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.chip)
            .cornerRadius(4)
    }
}
