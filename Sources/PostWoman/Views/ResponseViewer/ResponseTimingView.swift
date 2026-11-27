import SwiftUI

/// Where the request's time went: a waterfall of DNS, connect, TLS, send, wait and download.
struct ResponseTimingView: View {
    let totalTime: Double
    let timing: ResponseTiming?
    /// A streamed response: adds when its first byte, first token and last event arrived.
    var stream: StreamInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary

                if let stream {
                    streamSummary(stream)
                }

                if let timing, !timing.phases.isEmpty {
                    waterfall(timing)
                } else {
                    Text("A detailed breakdown isn't available for this response.")
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.field)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.format(timing?.total ?? totalTime))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                Text("total")
                    .foregroundColor(.secondary)
            }

            if let timing {
                HStack(spacing: 6) {
                    if let networkProtocol = timing.networkProtocol { chip(networkProtocol) }
                    if let tlsVersion = timing.tlsVersion { chip(tlsVersion) }
                    chip(timing.isReusedConnection ? "Reused connection" : "New connection")
                    if timing.redirectCount > 0 { chip(timing.redirectCount == 1 ? "1 redirect" : "\(timing.redirectCount) redirects") }
                    if let remoteAddress = timing.remoteAddress { chip(remoteAddress, monospaced: true) }
                }
            }
        }
    }

    private func waterfall(_ timing: ResponseTiming) -> some View {
        let total = max(timing.total, timing.phases.map { $0.start + $0.duration }.max() ?? 0, 1)
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            ForEach(timing.phases) { phase in
                GridRow {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Self.color(for: phase.kind))
                            .frame(width: 7, height: 7)
                        Text(phase.kind.rawValue)
                    }
                    .frame(width: 150, alignment: .leading)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.chip)
                            Capsule()
                                .fill(Self.color(for: phase.kind))
                                .frame(width: max(3, geometry.size.width * phase.duration / total))
                                .offset(x: min(geometry.size.width - 3, geometry.size.width * phase.start / total))
                        }
                    }
                    .frame(height: 8)

                    Text(Self.format(phase.duration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }

    private func streamSummary(_ stream: StreamInfo) -> some View {
        let rows: [(String, String)] = [
            ("Stream", stream.kind.displayName),
            ("Events", "\(stream.events.count)"),
            ("First byte", stream.firstByteTime.map(Self.format) ?? "–"),
            stream.text != nil ? ("First token", stream.firstTextTime.map(Self.format) ?? "–") : nil,
            ("Last event", stream.events.last.map { Self.format($0.time) } ?? "–")
        ].compactMap { $0 }
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label)
                        .frame(width: 150, alignment: .leading)
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func chip(_ title: String, monospaced: Bool = false) -> some View {
        Text(title)
            .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
    }

    static func color(for kind: ResponseTiming.Phase.Kind) -> Color {
        switch kind {
        case .dns: return Theme.phaseDNS
        case .connect: return Theme.phaseConnect
        case .tls: return Theme.phaseTLS
        case .request: return Theme.phaseRequest
        case .waiting: return Theme.phaseWaiting
        case .download: return Theme.phaseDownload
        }
    }

    /// "0.4 ms" below 10 ms, whole milliseconds below a second, then seconds.
    static func format(_ milliseconds: Double) -> String {
        // The unit is chosen from the rounded value, so 9.96 reads "10 ms", not "10.0 ms", and 999.6 "1.00 s", not "1000 ms".
        let tenths = String(format: "%.1f", milliseconds)
        if let value = Double(tenths), value < 10 { return tenths + " ms" }
        let whole = milliseconds.rounded()
        if whole < 1000 { return "\(Int(whole)) ms" }
        return String(format: "%.2f s", milliseconds / 1000)
    }
}
