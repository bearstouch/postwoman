import SwiftUI

struct ResponseViewerView: View {
    let response: HTTPResponse?
    let isLoading: Bool

    @State private var selectedTab: ResponseTab = .body

    enum ResponseTab: String, CaseIterable {
        case body = "Body"
        case events = "Events"
        case headers = "Headers"
        case cookies = "Cookies"
        case timing = "Timing"

        /// The tab's icon; its name is the tooltip.
        var systemImage: String {
            switch self {
            case .body: return "doc.plaintext"
            case .events: return "dot.radiowaves.left.and.right"
            case .headers: return "list.bullet.rectangle"
            case .cookies: return "circle.hexagongrid"
            case .timing: return "stopwatch"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                loadingView
            } else if let response = response {
                responseContent(response)
            } else {
                emptyResponseView
            }
        }
        .background(Theme.canvas)
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

    private func responseContent(_ response: HTTPResponse) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs(for: response), id: \.self) { tab in
                    tabButton(tab, count: count(for: tab, in: response))
                }
                Spacer(minLength: 12)
                ResponseSummaryView(response: response)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(Theme.bar)

            HairlineDivider()

            switch shownTab(for: response) {
            case .body:
                ResponseBodyView(
                    responseBody: response.body, contentType: response.contentType, assembledText: response.stream?.text,
                    followsEnd: response.stream?.isLive == true)
            case .events:
                ResponseEventsView(events: response.stream?.events ?? [], isLive: response.stream?.isLive == true)
            case .headers:
                ResponseHeadersView(headers: response.headers)
            case .cookies:
                ResponseCookiesView(cookies: response.cookies)
            case .timing:
                ResponseTimingView(totalTime: response.responseTime, timing: response.timing, stream: response.stream)
            }
        }
    }

    /// Events shows only for a streamed response.
    private func tabs(for response: HTTPResponse) -> [ResponseTab] {
        ResponseTab.allCases.filter { $0 != .events || response.stream != nil }
    }

    private func shownTab(for response: HTTPResponse) -> ResponseTab {
        tabs(for: response).contains(selectedTab) ? selectedTab : .body
    }

    private func count(for tab: ResponseTab, in response: HTTPResponse) -> Int? {
        switch tab {
        case .events: return response.stream?.events.count
        case .headers: return response.headers.count
        case .cookies: return response.cookies.count
        case .body, .timing: return nil
        }
    }

    private func tabButton(_ tab: ResponseTab, count: Int?) -> some View {
        let isSelected = response.map(shownTab(for:)) == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appAccent : Color.secondary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.chip))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Color.appAccent : Color.clear)
                    .frame(height: 2)
                    .shadow(color: isSelected ? Theme.accentGlow : .clear, radius: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
        .accessibilityLabel(count.map { "\(tab.rawValue), \($0)" } ?? tab.rawValue)
    }
}

/// The status pill, total time and body size shown at the right of the response tab bar.
private struct ResponseSummaryView: View {
    let response: HTTPResponse

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(response.statusCode == 0 ? "Error" : "\(response.statusCode) \(response.statusText)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(statusColor.opacity(0.14)))

            if let stream = response.stream {
                StreamBadge(stream: stream)
            }

            if response.statusCode != 0 {
                Text(ResponseTimingView.format(response.responseTime))
                    .help("Total time")
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1, height: 12)
                Text(Self.formatBytes(response.bodySize ?? response.body?.utf8.count ?? 0))
                    .help("Body size")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private var statusColor: Color {
        Theme.status(response.statusCode)
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}

/// Says whether a stream is still arriving (a pulsing dot and its event count), was stopped, or failed.
private struct StreamBadge: View {
    let stream: StreamInfo

    @State private var pulses = false

    var body: some View {
        HStack(spacing: 5) {
            switch stream.end {
            case .streaming:
                Circle()
                    .fill(Color.appAccent)
                    .frame(width: 6, height: 6)
                    .opacity(pulses ? 0.25 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulses)
                    .onAppear { pulses = true }
                Text(stream.events.count == 1 ? "Streaming · 1 event" : "Streaming · \(stream.events.count) events")
            case .completed:
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("Stream")
            case .stopped:
                Image(systemName: "stop.circle")
                Text("Stopped")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                Text("Interrupted")
            }
        }
        .foregroundStyle(color)
        .help(help)
    }

    private var color: Color {
        switch stream.end {
        case .streaming: return Color.appAccent
        case .completed, .stopped: return .secondary
        case .failed: return Theme.warning
        }
    }

    private var help: String {
        let kind = stream.kind.displayName
        switch stream.end {
        case .streaming: return "\(kind), still arriving"
        case .completed: return "\(kind): \(stream.events.count) events"
        case .stopped: return "\(kind), stopped before the server ended it"
        case .failed(let message): return "\(kind), interrupted: \(message)"
        }
    }
}
