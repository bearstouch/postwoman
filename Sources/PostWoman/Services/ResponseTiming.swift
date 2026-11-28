import Foundation
import Security

/// Where the time of a request went, taken from `URLSessionTaskMetrics`.
///
/// Times are milliseconds from the start of the task. With redirects, the phases describe the last
/// transaction, so the time spent on earlier hops shows as the offset of the first phase.
struct ResponseTiming: Equatable, Sendable, Codable {
    /// One step of the request: DNS lookup, connect, TLS, sending, waiting or downloading.
    struct Phase: Equatable, Sendable, Identifiable, Codable {
        enum Kind: String, CaseIterable, Sendable, Codable {
            case dns = "DNS lookup"
            case connect = "TCP connect"
            case tls = "TLS handshake"
            case request = "Request sent"
            case waiting = "Waiting (TTFB)"
            case download = "Content download"
        }

        let kind: Kind
        /// Milliseconds from the start of the task to the start of this phase.
        let start: Double
        let duration: Double

        var id: Kind { kind }
    }

    /// The timestamps of one transaction, as `URLSessionTaskTransactionMetrics` reports them.
    struct Marks: Sendable {
        var domainLookupStart: Date?
        var domainLookupEnd: Date?
        var connectStart: Date?
        var secureConnectionStart: Date?
        var secureConnectionEnd: Date?
        var connectEnd: Date?
        var requestStart: Date?
        var requestEnd: Date?
        var responseStart: Date?
        var responseEnd: Date?
    }

    /// Milliseconds from the start of the task to its end.
    let total: Double
    let phases: [Phase]
    /// "HTTP/2", "HTTP/1.1" and so on, when known.
    var networkProtocol: String?
    var isReusedConnection: Bool = false
    var remoteAddress: String?
    var tlsVersion: String?
    var redirectCount: Int = 0

    init(
        taskStart: Date, total: Double, marks: Marks, networkProtocol: String? = nil, isReusedConnection: Bool = false, remoteAddress: String? = nil,
        tlsVersion: String? = nil, redirectCount: Int = 0
    ) {
        func phase(_ kind: Phase.Kind, _ from: Date?, _ to: Date?) -> Phase? {
            guard let from, let to, to >= from else { return nil }
            return Phase(kind: kind, start: from.timeIntervalSince(taskStart) * 1000, duration: to.timeIntervalSince(from) * 1000)
        }

        self.total = total
        self.phases = [
            phase(.dns, marks.domainLookupStart, marks.domainLookupEnd),
            phase(.connect, marks.connectStart, marks.secureConnectionStart ?? marks.connectEnd),
            phase(.tls, marks.secureConnectionStart, marks.secureConnectionEnd),
            phase(.request, marks.requestStart, marks.requestEnd),
            phase(.waiting, marks.requestEnd, marks.responseStart),
            phase(.download, marks.responseStart, marks.responseEnd)
        ].compactMap { $0 }
        self.networkProtocol = networkProtocol
        self.isReusedConnection = isReusedConnection
        self.remoteAddress = remoteAddress
        self.tlsVersion = tlsVersion
        self.redirectCount = redirectCount
    }

    init?(metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return nil }
        let interval = metrics.taskInterval
        let marks = Marks(
            domainLookupStart: transaction.domainLookupStartDate, domainLookupEnd: transaction.domainLookupEndDate,
            connectStart: transaction.connectStartDate, secureConnectionStart: transaction.secureConnectionStartDate,
            secureConnectionEnd: transaction.secureConnectionEndDate, connectEnd: transaction.connectEndDate,
            requestStart: transaction.requestStartDate, requestEnd: transaction.requestEndDate,
            responseStart: transaction.responseStartDate, responseEnd: transaction.responseEndDate)
        let address = transaction.remoteAddress.map { address in
            transaction.remotePort.map { "\(address):\($0)" } ?? address
        }
        self.init(
            taskStart: interval.start, total: interval.duration * 1000, marks: marks,
            networkProtocol: transaction.networkProtocolName.map(Self.protocolDisplayName),
            isReusedConnection: transaction.isReusedConnection, remoteAddress: address,
            tlsVersion: transaction.negotiatedTLSProtocolVersion.flatMap(Self.tlsDisplayName),
            redirectCount: max(0, metrics.transactionMetrics.count - 1))
    }

    /// "h2" → "HTTP/2", "http/1.1" → "HTTP/1.1"; anything else as reported.
    static func protocolDisplayName(_ name: String) -> String {
        switch name.lowercased() {
        case "h2": return "HTTP/2"
        case "h3": return "HTTP/3"
        case "http/1.1": return "HTTP/1.1"
        case "http/1.0": return "HTTP/1.0"
        default: return name.uppercased()
        }
    }

    private static func tlsDisplayName(_ version: tls_protocol_version_t) -> String? {
        switch version {
        case .TLSv10: return "TLS 1.0"
        case .TLSv11: return "TLS 1.1"
        case .TLSv12: return "TLS 1.2"
        case .TLSv13: return "TLS 1.3"
        default: return nil
        }
    }
}

/// A cookie the response set with `Set-Cookie`.
struct ResponseCookie: Equatable, Sendable, Identifiable {
    var id: String { "\(domain)\(path)\(name)" }
    let name: String
    let value: String
    let domain: String
    let path: String
    /// nil for a session cookie.
    let expires: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let sameSite: String?

    /// The cookies set by a response's headers, as Foundation parses them for `url`.
    static func parse(headerFields: [String: String], url: URL) -> [ResponseCookie] {
        HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url).map { cookie in
            ResponseCookie(
                name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expires: cookie.expiresDate,
                isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue)
        }
    }
}
