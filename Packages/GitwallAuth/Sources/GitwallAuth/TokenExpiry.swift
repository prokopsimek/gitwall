import Foundation

/// Reads token expiry dates from provider responses so Settings can warn before a PAT stops working.
public enum TokenExpiry {
    /// GitHub sends `GitHub-Authentication-Token-Expiration: 2026-10-01 12:30:00 UTC` for expiring tokens.
    public static func gitHubExpiration(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "GitHub-Authentication-Token-Expiration") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    /// GitLab `GET /api/v4/personal_access_tokens/self` returns `expires_at` as a date or null.
    public static func gitLabExpiration(fromSelfResponse data: Data) -> Date? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = json["expires_at"] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
