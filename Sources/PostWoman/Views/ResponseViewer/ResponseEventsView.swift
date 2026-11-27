import SwiftUI

/// The events of a streamed response, as they arrived: number, time since the request started, SSE event name
/// and data on one line. Selecting one shows its data in full (pretty-printed when it is JSON) below.
struct ResponseEventsView: View {
    let events: [StreamEvent]
    /// Still arriving: the list keeps the newest event in view until one is selected.
    var isLive = false

    @State private var selection: StreamEvent.ID?
    @State private var searchText = ""

    private var filteredEvents: [StreamEvent] {
        Self.filter(events, by: searchText)
    }

    /// The events whose data or name contains `text` (ignoring case); all of them when `text` is empty.
    static func filter(_ events: [StreamEvent], by text: String) -> [StreamEvent] {
        guard !text.isEmpty else { return events }
        return events.filter { $0.data.localizedCaseInsensitiveContains(text) || ($0.event?.localizedCaseInsensitiveContains(text) ?? false) }
    }

    /// What shows instead of the list: nil when there are events to list.
    static func placeholder(events: [StreamEvent], filtered: [StreamEvent], isLive: Bool, searchText: String) -> String? {
        if events.isEmpty { return isLive ? "Waiting for the first event…" : "No events" }
        if filtered.isEmpty { return "No events match \u{201C}\(searchText)\u{201D}" }
        return nil
    }

    static func countText(_ count: Int) -> String {
        count == 1 ? "1 event" : "\(count) events"
    }

    /// The arrival time as an offset from the request's start: "+182 ms".
    static func timeText(_ event: StreamEvent) -> String {
        "+" + ResponseTimingView.format(event.time)
    }

    /// The start of an event's data on one line: newlines shown as ⏎, at most 400 characters.
    static func preview(_ data: String) -> String {
        String(data.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(400))
    }

    /// An event's data in full, pretty-printed when it is JSON.
    static func detailText(_ event: StreamEvent) -> (text: String, isJSON: Bool) {
        JSONFormatter.prettify(event.data).map { ($0, true) } ?? (event.data, false)
    }

    private var selectedEvent: StreamEvent? {
        selection.flatMap { id in events.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HairlineDivider()

            if let message = Self.placeholder(events: events, filtered: filteredEvents, isLive: isLive, searchText: searchText) {
                placeholder(message)
            } else {
                VSplitView {
                    list
                        .frame(minHeight: 80)
                    if let selectedEvent {
                        detail(selectedEvent)
                            .frame(minHeight: 80)
                    }
                }
                .themedSplitDividers()
            }
        }
        .background(Theme.field)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter events", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 240, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))

            Spacer()

            Text(Self.countText(events.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredEvents) { event in
                        EventRowView(event: event, isSelected: selection == event.id)
                            .id(event.id)
                            .onTapGesture { selection = selection == event.id ? nil : event.id }
                        Rectangle()
                            .fill(Theme.hairline.opacity(0.6))
                            .frame(height: 1)
                            .padding(.leading, 12)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: events.count) { _, _ in
                guard isLive, selection == nil, searchText.isEmpty, let last = events.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func detail(_ event: StreamEvent) -> some View {
        let shown = Self.detailText(event)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Event \(event.index + 1)")
                    .font(.callout.weight(.semibold))
                if let name = event.event { chip(name) }
                if let eventID = event.eventID { chip("id \(eventID)") }
                Text(Self.timeText(event))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                ResponseIconButton(systemImage: "doc.on.doc", help: "Copy data") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.text, forType: .string)
                }
                ResponseIconButton(systemImage: "xmark", help: "Close") {
                    selection = nil
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.bar)
            HairlineDivider()
            ResponseTextView(
                text: shown.text, highlightsJSON: shown.isJSON, wrapsLines: true, font: ThemeStore.shared.codeFont,
                themeRevision: ThemeStore.shared.revision)
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One event on one line: number, arrival time, event name and the start of its data.
private struct EventRowView: View {
    let event: StreamEvent
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(event.index + 1)")
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(ResponseEventsView.timeText(event))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            if let name = event.event {
                Text(name)
                    .foregroundStyle(Color.appAccent)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize()
            }
            Text(ResponseEventsView.preview(event.data))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.selection : (isHovering ? Theme.chip : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

#Preview {
    ResponseEventsView(events: [
        StreamEvent(index: 0, time: 182, event: "message_start", data: #"{"type":"message_start"}"#),
        StreamEvent(index: 1, time: 240, event: "content_block_delta", data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#),
        StreamEvent(index: 2, time: 310, data: "[DONE]")
    ])
    .frame(width: 600, height: 400)
}
