import Foundation

/// Parses `GitHub-Authentication-Token-Expiration: 2026-10-01 12:30:00 UTC`, which GitHub adds to every
/// response made with a token that has an expiry date.
enum TokenExpiryHeader {
    static func date(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "GitHub-Authentication-Token-Expiration") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
