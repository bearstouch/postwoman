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

        /// Events shows only for a streamed response.
        static func available(for response: HTTPResponse) -> [ResponseTab] {
            allCases.filter { $0 != .events || response.stream != nil }
        }

        /// The tab on screen: the chosen one, or Body when this response has no such tab.
        static func shown(_ selected: ResponseTab, for response: HTTPResponse) -> ResponseTab {
            available(for: response).contains(selected) ? selected : .body
        }

        /// The number in the tab's badge; nil for tabs without one.
        func count(in response: HTTPResponse) -> Int? {
            switch self {
            case .events: return response.stream?.events.count
            case .headers: return response.headers.count
            case .cookies: return response.cookies.count
            case .body, .timing: return nil
            }
        }

        /// What VoiceOver reads for the icon-only tab: its name, and its count when it has one.
        func accessibilityLabel(count: Int?) -> String {
            count.map { "\(rawValue), \($0)" } ?? rawValue
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

    private func tabs(for response: HTTPResponse) -> [ResponseTab] {
        ResponseTab.available(for: response)
    }

    private func shownTab(for response: HTTPResponse) -> ResponseTab {
        ResponseTab.shown(selectedTab, for: response)
    }

    private func count(for tab: ResponseTab, in response: HTTPResponse) -> Int? {
        tab.count(in: response)
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
        .accessibilityLabel(tab.accessibilityLabel(count: count))
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
                Text(ResponseSummary.statusTitle(response))
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
                Text(ResponseSummary.formatBytes(ResponseSummary.bodySize(response)))
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
}

/// The words of the response summary and its stream badge, kept apart from the views so they can be tested.
enum ResponseSummary {
    /// "200 OK", or "Error" when the request failed before a status arrived.
    static func statusTitle(_ response: HTTPResponse) -> String {
        response.statusCode == 0 ? "Error" : "\(response.statusCode) \(response.statusText)"
    }

    /// The body's size as received, else the UTF-8 size of its text.
    static func bodySize(_ response: HTTPResponse) -> Int {
        response.bodySize ?? response.body?.utf8.count ?? 0
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

    /// The badge's words: "Streaming · 3 events", "Stream", "Stopped" or "Interrupted".
    static func streamTitle(_ stream: StreamInfo) -> String {
        switch stream.end {
        case .streaming: return stream.events.count == 1 ? "Streaming · 1 event" : "Streaming · \(stream.events.count) events"
        case .completed: return "Stream"
        case .stopped: return "Stopped"
        case .failed: return "Interrupted"
        }
    }

    /// The badge's icon; nil while streaming, which shows a pulsing dot instead.
    static func streamSymbol(_ stream: StreamInfo) -> String? {
        switch stream.end {
        case .streaming: return nil
        case .completed: return "dot.radiowaves.left.and.right"
        case .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// The badge's tooltip: the stream's kind and how it ended.
    static func streamHelp(_ stream: StreamInfo) -> String {
        let kind = stream.kind.displayName
        switch stream.end {
        case .streaming: return "\(kind), still arriving"
        case .completed: return "\(kind): \(stream.events.count) events"
        case .stopped: return "\(kind), stopped before the server ended it"
        case .failed(let message): return "\(kind), interrupted: \(message)"
        }
    }
}

/// Says whether a stream is still arriving (a pulsing dot and its event count), was stopped, or failed.
private struct StreamBadge: View {
    let stream: StreamInfo

    @State private var pulses = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol = ResponseSummary.streamSymbol(stream) {
                Image(systemName: symbol)
            } else {
                Circle()
                    .fill(Color.appAccent)
                    .frame(width: 6, height: 6)
                    .opacity(pulses ? 0.25 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulses)
                    .onAppear { pulses = true }
            }
            Text(ResponseSummary.streamTitle(stream))
        }
        .foregroundStyle(color)
        .help(ResponseSummary.streamHelp(stream))
    }

    private var color: Color {
        switch stream.end {
        case .streaming: return Color.appAccent
        case .completed, .stopped: return .secondary
        case .failed: return Theme.warning
        }
    }
}
