import Foundation
import GitwallCore

/// Local, instant search used by the main window: every whitespace-separated word must match
/// the title, repository, `#number` or author login (case-insensitive).
public enum ItemSearch {
    /// Whether `query` narrows the list at all; a blank one keeps every item.
    public static func isActive(_ query: String) -> Bool {
        !words(of: query).isEmpty
    }

    public static func filter(_ items: [WorkItem], query: String) -> [WorkItem] {
        let words = words(of: query)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = [
                item.title.lowercased(),
                item.repoFullName.lowercased(),
                "#\(item.number)",
                item.author.login.lowercased(),
            ]
            return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
        }
    }

    private static func words(of query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
