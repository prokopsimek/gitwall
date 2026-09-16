import Foundation

/// Comparing user logins across providers and APIs. GitHub GraphQL returns `renovate` where REST returns
/// `renovate[bot]`, so the suffix is dropped on both sides before comparing.
enum LoginMatch {
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ login: String) -> String {
        var value = login.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix("[bot]") { value.removeLast(5) }
        return value
    }
}
