import Foundation

/// A request URL as the user typed it, made into one a parser accepts without re-encoding what is already encoded.
///
/// `URLComponents(string:)` percent-encodes a URL with a space or a `{`, but then encodes every `%` again, so `?q=%2F b`
/// went out as `q=%252F%20b`. Encoding those characters first keeps `%2F` as written. The app, generated cURL and
/// generated Swift all start from this, so they send the same URL.
enum RequestURL {
    /// `url` with every character a URL can't hold after its host percent-encoded (spaces, `{ } [ ] " < > \ ^ |`, non-ASCII),
    /// existing `%XX` escapes kept, and a `%` that starts no escape written as `%25`. The scheme and host are left as written,
    /// so `[::1]` and international host names are untouched. A URL without `://` is returned unchanged.
    static func encoded(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        let rest = url[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let scalars = Array(url[authorityEnd...].unicodeScalars)
        var result = String(url[..<authorityEnd])
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%" {
                let isEscape = index + 2 < scalars.count && isHexDigit(scalars[index + 1]) && isHexDigit(scalars[index + 2])
                result += isEscape ? "%" : "%25"
            } else if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(scalar).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            }
            index += 1
        }
        return result
    }

    /// What a path, query or fragment may hold as written (RFC 3986 unreserved and sub-delimiters, plus `: @ / ? #`).
    /// Brackets are left out: they are only valid around an IPv6 host, and curl reads them as a glob elsewhere.
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?#")

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isASCIIHexDigit }
}
